import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:typed_data';
import 'package:shared_services/shared_services.dart';
import 'package:scout_mobile/src/core/services/network_service.dart';
import '../../data/observation_local_db.dart';
import 'add_observation_page.dart';
import 'observation_details_page.dart';

class ObservationPage extends StatefulWidget {
  const ObservationPage({super.key});

  @override
  State<ObservationPage> createState() => _ObservationPageState();
}

class _ObservationPageState extends State<ObservationPage> {
  List<Map<String, dynamic>> _localObservations = [];
  List<Map<String, dynamic>> _remoteObservations = [];
  bool _isLoading = true;
  String? _error;
  DateTime? _lastBackPress;

  // Sync state
  final Set<String> _syncingIds = {};
  bool _isBulkSyncing = false;
  int _bulkSyncCompleted = 0;
  int _bulkSyncTotal = 0;

  // Filter state
  DateTime? _filterStartDate;
  DateTime? _filterEndDate;

  late final StreamSubscription<bool> _networkSub;

  @override
  void initState() {
    super.initState();
    _fetchObservations();
    ObservationLocalDb.instance.updatePendingCount();

    _networkSub = NetworkService.instance.onConnectivityChanged.listen((isOnline) {
      if (!mounted) return;
      _fetchObservations();
    });
  }

  @override
  void dispose() {
    _networkSub.cancel();
    super.dispose();
  }

  Future<void> _fetchObservations() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      // Always fetch local observations
      final cached = await ObservationLocalDb.instance.getAllLocal();
      final localList = cached.map((e) {
        return {
          'observation_id': e.observationId,
          'user_id': e.userId,
          'coordinates': 'POINT(${e.longitude} ${e.latitude})',
          'timestamp': e.observationTimestamp.toIso8601String(),
          'sync_status': e.syncStatus,
          'image_path': e.imagePath,
          'final_severity': 'healthy',
          'capture_method': e.source.toUpperCase(),
          'evaluation_method': 'MANUAL',
          'is_local': true,
        };
      }).toList();

      List<Map<String, dynamic>> remoteList = [];

      // Fetch remote observations if online and logged in
      final isOnline = NetworkService.instance.isOnline;
      final user = Supabase.instance.client.auth.currentUser;
      if (isOnline && user != null) {
        try {
          final data = await Supabase.instance.client
              .from('observations')
              .select()
              .eq('user_id', user.id)
              .order('observation_timestamp', ascending: false);

          remoteList = (data as List<dynamic>).map((e) {
            final map = e as Map<String, dynamic>;
            return {
              ...map,
              'timestamp': map['observation_timestamp'] ?? map['upload_timestamp'] ?? DateTime.now().toIso8601String(),
              'final_severity': map['confidence_score'] != null ? 'high' : 'unknown',
              'is_local': false,
            };
          }).toList();
        } catch (e) {
          debugPrint('Remote fetch error: $e');
        }
      }

      if (mounted) {
        setState(() {
          _localObservations = localList;
          _remoteObservations = remoteList;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _syncSingleObservation(String observationId) async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null || !NetworkService.instance.isOnline) {
      _showToast('Sign in and connect to internet to sync.');
      return;
    }

    if (_syncingIds.contains(observationId)) return;

    setState(() {
      _syncingIds.add(observationId);
    });

    try {
      final obs = await ObservationLocalDb.instance.getById(observationId);
      if (obs == null) throw Exception('Observation not found in local cache.');

      String? remoteImageUrl;

      // 1. Upload image
      if (obs.imagePath != null && obs.imagePath!.isNotEmpty) {
        final file = File(obs.imagePath!);
        if (await file.exists()) {
          final fileName = '${user.id}/${obs.observationId}.jpg';
          try {
            await Supabase.instance.client.storage
                .from('observations')
                .upload(
                  fileName,
                  file,
                  fileOptions: const FileOptions(cacheControl: '3600'),
                ).timeout(const Duration(seconds: 30));
          } on StorageException catch (se) {
            final isDuplicate = (se.statusCode == '400' || se.statusCode == '409') && se.message.toLowerCase().contains('exists');
            if (!isDuplicate && se.statusCode != '200' && se.message != 'API error') {
              throw Exception('Storage Upload Failed: ${se.message} (${se.statusCode})');
            }
          } on TimeoutException catch (_) {
            throw Exception('Connection too slow. Storage upload timed out.');
          }

          remoteImageUrl = Supabase.instance.client.storage
              .from('observations')
              .getPublicUrl(fileName);
        }
      }

      // 2. Insert to Postgres
      try {
        await Supabase.instance.client.from('observations').insert({
          'observation_id': obs.observationId,
          'user_id': user.id,
          'coordinates': 'POINT(${obs.longitude} ${obs.latitude})',
          'image_url': remoteImageUrl,
          'observation_timestamp': obs.observationTimestamp.toUtc().toIso8601String(),
          'upload_timestamp': DateTime.now().toUtc().toIso8601String(),
          'source': obs.source.toUpperCase(),
          'sync_status': 'UPLOADED',
        }).select().timeout(const Duration(seconds: 15));
      } on PostgrestException catch (pe) {
        if (pe.code != '23505') {
          throw Exception('Database Insert Failed: ${pe.message} (Code: ${pe.code})');
        }
      } on TimeoutException catch (_) {
        throw Exception('Connection too slow. Database insert timed out.');
      }

      // 3. Delete from local cache
      await ObservationLocalDb.instance.deleteObservation(obs.observationId);

      // 4. Clean up local image file
      if (obs.imagePath != null && obs.imagePath!.isNotEmpty) {
        try {
          final file = File(obs.imagePath!);
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }

      if (mounted) {
        _showToast('Observation synced successfully!', isError: false);
        await _fetchObservations();
      }
    } catch (e) {
      await ObservationLocalDb.instance.markFailed(observationId);
      _showToast('Sync failed: $e');
      if (mounted) await _fetchObservations();
    } finally {
      if (mounted) {
        setState(() {
          _syncingIds.remove(observationId);
        });
      }
    }
  }

  Future<void> _syncAllObservations() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null || !NetworkService.instance.isOnline) {
      _showToast('Sign in and connect to internet to sync.');
      return;
    }

    final pendingIds = _localObservations
        .where((o) => o['sync_status'] != 'UPLOADED')
        .map((o) => o['observation_id'] as String)
        .toList();

    if (pendingIds.isEmpty) return;

    setState(() {
      _isBulkSyncing = true;
      _bulkSyncCompleted = 0;
      _bulkSyncTotal = pendingIds.length;
    });

    for (final id in pendingIds) {
      await _syncSingleObservation(id);
      if (mounted) {
        setState(() {
          _bulkSyncCompleted++;
        });
      }
    }

    if (mounted) {
      setState(() {
        _isBulkSyncing = false;
      });
      _showToast('All observations synced!', isError: false);
    }
  }

  // Date filter logic
  List<Map<String, dynamic>> _applyDateFilter(List<Map<String, dynamic>> observations) {
    if (_filterStartDate == null && _filterEndDate == null) return observations;
    return observations.where((obs) {
      final ts = obs['timestamp'];
      if (ts == null) return true;
      final date = DateTime.tryParse(ts);
      if (date == null) return true;
      if (_filterStartDate != null && date.isBefore(_filterStartDate!)) return false;
      if (_filterEndDate != null && date.isAfter(_filterEndDate!.add(const Duration(days: 1)))) return false;
      return true;
    }).toList();
  }

  void _showDateFilterSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(Icons.filter_list_rounded, color: Colors.green[700]),
                      const SizedBox(width: 8),
                      const Text(
                        'Filter by Date',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  const Divider(height: 24),
                  ListTile(
                    leading: Icon(Icons.calendar_today, color: Colors.green[700]),
                    title: Text(
                      _filterStartDate != null
                          ? 'From: ${_filterStartDate!.toLocal().toString().substring(0, 10)}'
                          : 'From: Any',
                    ),
                    onTap: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: _filterStartDate ?? DateTime.now(),
                        firstDate: DateTime(2020),
                        lastDate: DateTime.now(),
                      );
                      if (picked != null) {
                        setModalState(() {});
                        setState(() => _filterStartDate = picked);
                      }
                    },
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  ListTile(
                    leading: Icon(Icons.event, color: Colors.green[700]),
                    title: Text(
                      _filterEndDate != null
                          ? 'To: ${_filterEndDate!.toLocal().toString().substring(0, 10)}'
                          : 'To: Any',
                    ),
                    onTap: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: _filterEndDate ?? DateTime.now(),
                        firstDate: DateTime(2020),
                        lastDate: DateTime.now(),
                      );
                      if (picked != null) {
                        setModalState(() {});
                        setState(() => _filterEndDate = picked);
                      }
                    },
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: () {
                      setState(() {
                        _filterStartDate = null;
                        _filterEndDate = null;
                      });
                      Navigator.pop(context);
                    },
                    icon: const Icon(Icons.clear),
                    label: const Text('Clear Filters'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.grey[700],
                      side: BorderSide(color: Colors.grey[300]!),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  const SizedBox(height: 8),
                  FilledButton(
                    onPressed: () => Navigator.pop(context),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.green[700],
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('Apply', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Map<String, double>? _parseCoordinates(dynamic coords) {
    if (coords == null) return null;
    if (coords is Map) {
      final map = coords.cast<String, dynamic>();
      final list = map['coordinates'];
      if (list is List && list.length >= 2) {
        return {
          'lng': (list[0] as num).toDouble(),
          'lat': (list[1] as num).toDouble(),
        };
      }
    } else if (coords is String) {
      final trimmed = coords.trim();

      // Check if it is a hex string (WKB/EWKB format)
      final hexRegex = RegExp(r'^(0x)?[0-9a-fA-F]+$');
      if (hexRegex.hasMatch(trimmed)) {
        return _parseEWKB(trimmed);
      }

      final match = RegExp(r'POINT\s*\(\s*([-\d.]+)\s+([-\d.]+)\s*\)', caseSensitive: false).firstMatch(trimmed);
      if (match != null) {
        return {
          'lng': double.tryParse(match.group(1) ?? '') ?? 0.0,
          'lat': double.tryParse(match.group(2) ?? '') ?? 0.0,
        };
      }
    }
    return null;
  }

  Map<String, double>? _parseEWKB(String hex) {
    try {
      String cleanHex = hex.startsWith('0x') ? hex.substring(2) : hex;
      if (cleanHex.length < 42) return null;

      final byteOrder = cleanHex.substring(0, 2);
      final isLittleEndian = byteOrder == '01';

      final typeHex = cleanHex.substring(2, 10);
      final hasSrid = typeHex.toLowerCase() == '01000020' || typeHex.toLowerCase() == '20000001';

      final int startX = hasSrid ? 18 : 10;
      final int startY = hasSrid ? 34 : 26;

      final double lng = _hexToDouble(cleanHex.substring(startX, startX + 16), isLittleEndian);
      final double lat = _hexToDouble(cleanHex.substring(startY, startY + 16), isLittleEndian);

      return {'lng': lng, 'lat': lat};
    } catch (_) {
      return null;
    }
  }

  double _hexToDouble(String hex, bool isLittleEndian) {
    final bytes = Uint8List(8);
    for (int i = 0; i < 8; i++) {
      final idx = isLittleEndian ? (i * 2) : ((7 - i) * 2);
      bytes[i] = int.parse(hex.substring(idx, idx + 2), radix: 16);
    }
    return ByteData.sublistView(bytes).getFloat64(0, Endian.little);
  }

  @override
  Widget build(BuildContext context) {
    final hasActiveFilter = _filterStartDate != null || _filterEndDate != null;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        final now = DateTime.now();
        if (_lastBackPress != null && now.difference(_lastBackPress!) < const Duration(seconds: 2)) {
          SystemNavigator.pop();
        } else {
          _lastBackPress = now;
          ScaffoldMessenger.of(context).clearSnackBars();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('Press back again to exit'),
              duration: const Duration(seconds: 2),
              backgroundColor: Colors.grey[800],
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          );
        }
      },
      child: Scaffold(
        backgroundColor: Colors.grey[50],
        appBar: AppBar(
          automaticallyImplyLeading: false,
          title: const Text(
            'My Observations',
            style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
          ),
          backgroundColor: Colors.green[700],
          elevation: 0,
          actions: [
            IconButton(
              icon: Icon(
                hasActiveFilter ? Icons.filter_list : Icons.filter_list_outlined,
                color: hasActiveFilter ? Colors.amber[300] : Colors.white,
              ),
              onPressed: _showDateFilterSheet,
              tooltip: 'Filter by date',
            ),
          ],
        ),
        body: Stack(
          children: [
            RefreshIndicator(
              onRefresh: _fetchObservations,
              color: Colors.green[700],
              child: _buildBody(),
            ),
            Positioned(
              bottom: 16,
              right: 16,
              child: FloatingActionButton(
                backgroundColor: Colors.green[700],
                onPressed: () async {
                  final success = await Navigator.push<bool>(
                    context,
                    MaterialPageRoute(builder: (context) => const AddObservationPage()),
                  );
                  if (success == true) {
                    _fetchObservations();
                  }
                },
                child: const Icon(Icons.add, color: Colors.white),
              ),
            ),
          ],
        ),
        bottomNavigationBar: Container(
          decoration: BoxDecoration(
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 10,
                offset: const Offset(0, -2),
              ),
            ],
          ),
          child: BottomNavigationBar(
            currentIndex: 0,
            onTap: (index) {
              if (index == 0) {
                // already on observations
              } else if (index == 1) {
                Navigator.of(context).pushReplacementNamed('/map');
              } else if (index == 2) {
                Navigator.of(context).pushReplacementNamed('/profile');
              }
            },
            type: BottomNavigationBarType.fixed,
            backgroundColor: Colors.white,
            selectedItemColor: Colors.green[700],
            unselectedItemColor: Colors.grey[500],
            selectedFontSize: 12.0,
            unselectedFontSize: 12.0,
            selectedLabelStyle: const TextStyle(fontWeight: FontWeight.bold),
            unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w500),
            elevation: 0,
            items: const [
              BottomNavigationBarItem(
                icon: Icon(Icons.assignment_outlined),
                activeIcon: Icon(Icons.assignment),
                label: 'Observations',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.map_outlined),
                activeIcon: Icon(Icons.map),
                label: 'Map',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.person_outline),
                activeIcon: Icon(Icons.person),
                label: 'Profile',
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.green),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline_rounded, color: Colors.red, size: 64),
              const SizedBox(height: 16),
              Text(
                'Failed to load observations',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.grey[800]),
              ),
              const SizedBox(height: 8),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey[600]),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: _fetchObservations,
                icon: const Icon(Icons.refresh),
                label: const Text('Try Again'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green[700],
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final filteredLocal = _applyDateFilter(_localObservations);
    final filteredRemote = _applyDateFilter(_remoteObservations);
    final isOnline = NetworkService.instance.isOnline;
    final isLoggedIn = Supabase.instance.client.auth.currentUser != null;
    final pendingLocal = filteredLocal.where((o) => o['sync_status'] != 'UPLOADED').toList();

    if (filteredLocal.isEmpty && filteredRemote.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(height: MediaQuery.of(context).size.height * 0.25),
          Center(
            child: Column(
              children: [
                Icon(Icons.assignment_outlined, size: 80, color: Colors.grey[300]),
                const SizedBox(height: 16),
                Text(
                  'No Observations Yet',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.grey[700]),
                ),
                const SizedBox(height: 8),
                Text(
                  'Your collected gall rust observations will appear here.',
                  style: TextStyle(color: Colors.grey[500]),
                ),
              ],
            ),
          ),
        ],
      );
    }

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
      children: [
        // Summary Stats Header
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 16.0),
          decoration: BoxDecoration(
            color: Colors.green[50],
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildStatItem('Local', filteredLocal.length.toString(), Icons.phone_android, Colors.amber[800]!),
              _buildStatItem('Synced', filteredRemote.length.toString(), Icons.cloud_done, Colors.blue[700]!),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // Sync All Card
        if (pendingLocal.isNotEmpty && isOnline && isLoggedIn)
          Card(
            elevation: 2,
            shadowColor: Colors.black.withValues(alpha: 0.04),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            color: Colors.white,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_isBulkSyncing) ...[
                    Row(
                      children: [
                        const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(color: Colors.green, strokeWidth: 2),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          'Syncing $_bulkSyncCompleted / $_bulkSyncTotal...',
                          style: TextStyle(fontWeight: FontWeight.w600, color: Colors.green[800]),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    LinearProgressIndicator(
                      value: _bulkSyncTotal > 0 ? _bulkSyncCompleted / _bulkSyncTotal : 0,
                      backgroundColor: Colors.green[100],
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.green[700]!),
                      borderRadius: BorderRadius.circular(8),
                      minHeight: 6,
                    ),
                  ] else
                    FilledButton.icon(
                      onPressed: _syncAllObservations,
                      icon: const Icon(Icons.cloud_upload_rounded),
                      label: Text(
                        'Sync All (${pendingLocal.length})',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.green[700],
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                ],
              ),
            ),
          ),

        if (pendingLocal.isNotEmpty && (!isOnline || !isLoggedIn))
          Card(
            elevation: 2,
            shadowColor: Colors.black.withValues(alpha: 0.04),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            color: Colors.grey[100],
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(
                    !isOnline ? Icons.cloud_off_rounded : Icons.lock_outline,
                    color: Colors.grey[500],
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      !isOnline
                          ? 'Connect to internet to sync observations.'
                          : 'Sign in to sync observations.',
                      style: TextStyle(color: Colors.grey[600], fontWeight: FontWeight.w500),
                    ),
                  ),
                ],
              ),
            ),
          ),

        const SizedBox(height: 16),

        // Local Observations Section
        if (filteredLocal.isNotEmpty) ...[
          _buildSectionHeader('📱 Local Observations', filteredLocal.length),
          const SizedBox(height: 8),
          ...filteredLocal.map((obs) => _buildObservationCard(obs, isLocal: true)),
          const SizedBox(height: 16),
        ],

        // Synced Observations Section
        if (filteredRemote.isNotEmpty) ...[
          _buildSectionHeader('☁️ Synced Observations', filteredRemote.length),
          const SizedBox(height: 8),
          ...filteredRemote.map((obs) => _buildObservationCard(obs, isLocal: false)),
        ],

        // Bottom padding for FAB
        const SizedBox(height: 80),
      ],
    );
  }

  Widget _buildSectionHeader(String title, int count) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Text(
        '$title ($count)',
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.bold,
          color: Colors.grey[700],
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _buildObservationCard(Map<String, dynamic> obs, {required bool isLocal}) {
    final observationId = obs['observation_id']?.toString() ?? '';
    final isSyncing = _syncingIds.contains(observationId);
    final dateStr = obs['timestamp'] != null
        ? DateTime.tryParse(obs['timestamp'])?.toLocal().toString().substring(0, 16) ?? obs['timestamp']
        : 'N/A';
    final coords = _parseCoordinates(obs['coordinates']);
    final latStr = coords != null ? coords['lat']!.toStringAsFixed(6) : 'N/A';
    final lngStr = coords != null ? coords['lng']!.toStringAsFixed(6) : 'N/A';
    final captureMethod = obs['capture_method']?.toString() ?? 'UPLOAD';
    final evaluationMethod = obs['evaluation_method']?.toString() ?? 'CNN';
    final syncStatus = obs['sync_status']?.toString();

    final imageUrl = obs['image_url']?.toString();
    final localImagePath = obs['image_path']?.toString();

    final borderColor = isLocal ? Colors.amber[700]! : Colors.blue[600]!;

    return Card(
      elevation: 2.0,
      shadowColor: Colors.black.withValues(alpha: 0.04),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16.0),
      ),
      margin: const EdgeInsets.only(bottom: 12.0),
      color: Colors.white,
      child: InkWell(
        borderRadius: BorderRadius.circular(16.0),
        onTap: () async {
          final result = await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => ObservationDetailsPage(
                obs: obs,
                isCached: isLocal,
              ),
            ),
          );
          if (result == 'UPLOAD' && isLocal) {
            _syncSingleObservation(observationId);
          } else if (result == 'DELETE' && isLocal) {
            await ObservationLocalDb.instance.deleteObservation(observationId);
            _fetchObservations();
          } else if (result == 'DELETED_SYSTEM' || result == 'VERIFICATION_REQUESTED') {
            _fetchObservations();
          }
        },
        child: IntrinsicHeight(
          child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Color indicator border
            Container(
              width: 5,
              decoration: BoxDecoration(
                color: borderColor,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(16),
                  bottomLeft: Radius.circular(16),
                ),
              ),
            ),
            // Image thumbnail
            ClipRRect(
              child: SizedBox(
                width: 95,
                child: localImagePath != null && localImagePath.isNotEmpty
                    ? Image.file(
                        File(localImagePath),
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) => Container(
                          color: Colors.green[50],
                          child: Icon(Icons.image_not_supported_outlined, color: Colors.green[200]),
                        ),
                      )
                    : (imageUrl != null && imageUrl.isNotEmpty
                        ? Image.network(
                            imageUrl,
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) => Container(
                              color: Colors.green[50],
                              child: Icon(Icons.image_not_supported_outlined, color: Colors.green[200]),
                            ),
                          )
                        : Container(
                            color: Colors.green[50],
                            child: Icon(Icons.park_outlined, color: Colors.green[200], size: 36),
                          )),
              ),
            ),
            // Details
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(14.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: isLocal ? Colors.amber[50] : Colors.blue[50],
                            borderRadius: BorderRadius.circular(100),
                          ),
                          child: Text(
                            isLocal ? (syncStatus ?? 'PENDING').toUpperCase() : 'SYNCED',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: isLocal ? Colors.amber[800] : Colors.blue[700],
                            ),
                          ),
                        ),
                        Text(
                          dateStr,
                          style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Icon(Icons.location_on_outlined, size: 14, color: Colors.green[700]),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            'Lat: $latStr, Lng: $lngStr',
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Colors.black87),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Icon(Icons.camera_alt_outlined, size: 14, color: Colors.grey[600]),
                        const SizedBox(width: 4),
                        Text(
                          'Method: $captureMethod ($evaluationMethod)',
                          style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            // Sync button (local only)
            if (isLocal && NetworkService.instance.isOnline && Supabase.instance.client.auth.currentUser != null)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Center(
                  child: isSyncing
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(color: Colors.green, strokeWidth: 2),
                        )
                      : IconButton(
                          icon: Icon(Icons.cloud_upload_rounded, color: Colors.green[700]),
                          onPressed: () => _syncSingleObservation(observationId),
                          tooltip: 'Upload this observation',
                        ),
                ),
              ),
          ],
        ),
      ),
      ),
    );
  }

  void _showToast(String message, {bool isError = true}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red[800] : Colors.green[800],
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  Widget _buildStatItem(String label, String value, IconData icon, Color color) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8.0),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: color, size: 20),
        ),
        const SizedBox(width: 10),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              value,
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: color),
            ),
            Text(
              label,
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
          ],
        ),
      ],
    );
  }
}
