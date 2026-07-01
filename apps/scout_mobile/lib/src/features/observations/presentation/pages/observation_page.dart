import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:typed_data';
import 'package:shared_services/shared_services.dart';
import 'package:scout_mobile/src/core/services/network_service.dart';
import '../../data/observation_local_db.dart';
import 'add_observation_page.dart';

class ObservationPage extends StatefulWidget {
  const ObservationPage({super.key});

  @override
  State<ObservationPage> createState() => _ObservationPageState();
}

class _ObservationPageState extends State<ObservationPage> {
  List<Map<String, dynamic>> _observations = [];
  bool _isLoading = true;
  String? _error;
  bool _isSyncing = false;
  late final StreamSubscription<bool> _networkSub;
  DateTime? _lastBackPress;

  @override
  void initState() {
    super.initState();
    _fetchObservations();
    
    // Automatically trigger sync if online immediately on page load
    if (NetworkService.instance.isOnline) {
      _syncPendingObservations();
    }

    // Set up auto-sync listener when internet connection is restored
    _networkSub = NetworkService.instance.onConnectivityChanged.listen((isOnline) {
      if (!mounted) return;
      if (isOnline) {
        _syncPendingObservations();
      } else {
        _fetchObservations();
      }
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

    final isOnline = NetworkService.instance.isOnline;
    final user = Supabase.instance.client.auth.currentUser;

    if (!isOnline || user == null) {
      // Offline mode: load from SQLite cache
      try {
        final cached = await ObservationLocalDb.instance.getAllLocal();
        if (mounted) {
          setState(() {
            _observations = cached.map((e) {
              return {
                'observation_id': e.observationId,
                'user_id': e.userId,
                'coordinates': 'POINT(${e.longitude} ${e.latitude})',
                'timestamp': e.observationTimestamp.toIso8601String(),
                'sync_status': e.syncStatus,
                'image_path': e.imagePath,
                'final_severity': 'healthy', // Default placeholder severity when offline
                'capture_method': e.source.toUpperCase(),
                'evaluation_method': 'MANUAL',
              };
            }).toList();
            _isLoading = false;
          });
        }
      } catch (e) {
        if (mounted) {
          setState(() {
            _error = 'Local DB Error: ${e.toString()}';
            _isLoading = false;
          });
        }
      }
      return;
    }

    // Online mode: load from Supabase remote database
    try {
      final data = await Supabase.instance.client
          .from('observations')
          .select()
          .eq('user_id', user.id)
          .order('observation_timestamp', ascending: false);

      final List<Map<String, dynamic>> remoteList = (data as List<dynamic>).map((e) {
        final map = e as Map<String, dynamic>;
        return {
          ...map,
          'timestamp': map['observation_timestamp'] ?? map['upload_timestamp'] ?? DateTime.now().toIso8601String(),
          'final_severity': map['confidence_score'] != null ? 'high' : 'unknown',
        };
      }).toList();

      // Retrieve local unsynced observations to overlay them in the list representation
      final localCached = await ObservationLocalDb.instance.getPending();
      final List<Map<String, dynamic>> pendingList = localCached.map((e) {
        return {
          'observation_id': e.observationId,
          'user_id': e.userId ?? user.id,
          'coordinates': 'POINT(${e.longitude} ${e.latitude})',
          'timestamp': e.observationTimestamp.toIso8601String(),
          'sync_status': e.syncStatus,
          'image_path': e.imagePath,
          'final_severity': 'healthy',
          'capture_method': e.source.toUpperCase(),
          'evaluation_method': 'MANUAL',
        };
      }).toList();

      if (mounted) {
        setState(() {
          // Combine pending local and remote observations (local first so they appear at the top)
          _observations = [...pendingList, ...remoteList];
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

  Future<void> _syncPendingObservations() async {
    if (_isSyncing) return;
    final isOnline = NetworkService.instance.isOnline;
    final user = Supabase.instance.client.auth.currentUser;
    if (!isOnline || user == null) return;

    if (!mounted) return;
    setState(() {
      _isSyncing = true;
    });

    try {
      final pending = await ObservationLocalDb.instance.getPending();
      if (pending.isEmpty) {
        if (mounted) {
          setState(() {
            _isSyncing = false;
          });
        }
        return;
      }

      _showToast('Syncing ${pending.length} pending observation(s)...', isError: false);

      for (var obs in pending) {
        try {
          String? remoteImageUrl;
          
          // 1. Upload local photo to storage bucket if it exists
          if (obs.imagePath != null && obs.imagePath!.isNotEmpty) {
            final file = File(obs.imagePath!);
            if (await file.exists()) {
              final fileName = '${user.id}/${obs.observationId}.jpg';
              // Upload to Supabase 'observations' storage bucket using standard file upload
              try {
                await Supabase.instance.client.storage
                    .from('observations')
                    .upload(
                      fileName, 
                      file, 
                      fileOptions: const FileOptions(cacheControl: '3600')
                    );
              } on StorageException catch (se) {
                // Supabase storage client has a known bug throwing 'API error' with 200 OK on success
                // Also ignore 400/409 'The resource already exists' in case this is a retry and the image is already there.
                final isDuplicate = (se.statusCode == 400 || se.statusCode == 409) && se.message.toLowerCase().contains('exists');
                if (!isDuplicate && se.statusCode != 200 && se.message != 'API error') {
                  throw Exception('Storage Upload Failed: ${se.message} (${se.statusCode})');
                }
              }

              // Obtain public URL
              remoteImageUrl = Supabase.instance.client.storage
                  .from('observations')
                  .getPublicUrl(fileName);
            }
          }

          // 2. Insert to Postgres db (Idempotency: Catch 23505 duplicate code or overwrite)
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
            }).select();
          } on PostgrestException catch (pe) {
            // Unique violation (409 / 23505 conflict) means already uploaded
            if (pe.code == '23505') {
              // Ignore duplicate
            } else {
              throw Exception('Database Insert Failed: ${pe.message} (Code: ${pe.code})');
            }
          }

          await ObservationLocalDb.instance.markUploaded(obs.observationId);
        } catch (e) {
          debugPrint('Sync failed for ${obs.observationId}: $e');
          await ObservationLocalDb.instance.markFailed(obs.observationId);
          throw Exception('Item ${obs.observationId} failed: $e');
        }
      }

      _showToast('Observations synchronized successfully!', isError: false);
      _fetchObservations();
    } catch (e) {
      _showToast('Synchronization error: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isSyncing = false;
        });
      }
    }
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

  Color _getSeverityColor(String? severity) {
    switch (severity?.toLowerCase()) {
      case 'healthy':
        return Colors.green;
      case 'low':
        return Colors.blue;
      case 'moderate':
        return Colors.orange;
      case 'high':
        return Colors.deepOrange;
      case 'severe':
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
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
            // StreamBuilder for real-time unsynced observations count
            StreamBuilder<int>(
              stream: ObservationLocalDb.instance.pendingCountStream,
              initialData: 0,
              builder: (context, snapshot) {
                final pendingCount = snapshot.data ?? 0;
                return Stack(
                  alignment: Alignment.center,
                  children: [
                    IconButton(
                      icon: Icon(
                        pendingCount > 0 ? Icons.cloud_upload_rounded : Icons.refresh,
                        color: Colors.white,
                      ),
                      onPressed: pendingCount > 0 ? _syncPendingObservations : _fetchObservations,
                    ),
                    if (pendingCount > 0)
                      Positioned(
                        right: 4,
                        top: 4,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: const BoxDecoration(
                            color: Colors.red,
                            shape: BoxShape.circle,
                          ),
                          constraints: const BoxConstraints(
                            minWidth: 16,
                            minHeight: 16,
                          ),
                          child: Text(
                            '$pendingCount',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                  ],
                );
              },
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

    if (_observations.isEmpty) {
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
                  style: TextStyle(color: Colors.grey[50]),
                ),
              ],
            ),
          ),
        ],
      );
    }

    // Quick Stats Header
    final severeCount = _observations.where((o) => o['final_severity']?.toString().toLowerCase() == 'severe').length;
    final totalCount = _observations.length;

    return Column(
      children: [
        // Premium Summary Header Card
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 16.0),
          color: Colors.green[50],
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildStatItem('Total', totalCount.toString(), Icons.analytics_outlined, Colors.green[800]!),
              _buildStatItem('Severe', severeCount.toString(), Icons.warning_amber_rounded, Colors.red[800]!),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
            itemCount: _observations.length,
            itemBuilder: (context, index) {
              final obs = _observations[index];
              final severity = obs['final_severity']?.toString() ?? 'unknown';
              final severityColor = _getSeverityColor(severity);
              final dateStr = obs['timestamp'] != null
                  ? DateTime.tryParse(obs['timestamp'])?.toLocal().toString().substring(0, 16) ?? obs['timestamp']
                  : 'N/A';
              final coords = _parseCoordinates(obs['coordinates']);
              final latStr = coords != null ? coords['lat']!.toStringAsFixed(6) : 'N/A';
              final lngStr = coords != null ? coords['lng']!.toStringAsFixed(6) : 'N/A';
              final captureMethod = obs['capture_method']?.toString() ?? 'UPLOAD';
              final evaluationMethod = obs['evaluation_method']?.toString() ?? 'CNN';
              
              final imageUrl = obs['image_url']?.toString();
              final localImagePath = obs['image_path']?.toString();

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
                  onTap: () {
                    _showToast('Viewing observation detail - placeholder!', isError: false);
                  },
                  child: IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Image Thumbnail / Placeholder (supports offline files & online urls)
                        ClipRRect(
                          borderRadius: const BorderRadius.only(
                            topLeft: Radius.circular(16.0),
                            bottomLeft: Radius.circular(16.0),
                          ),
                          child: SizedBox(
                            width: 100,
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
                            padding: const EdgeInsets.all(16.0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 10.0, vertical: 4.0),
                                      decoration: BoxDecoration(
                                        color: severityColor.withValues(alpha: 0.1),
                                        borderRadius: BorderRadius.circular(100.0),
                                      ),
                                      child: Text(
                                        severity.toUpperCase(),
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                          color: severityColor,
                                        ),
                                      ),
                                    ),
                                    Text(
                                      dateStr,
                                      style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8.0),
                                Row(
                                  children: [
                                    Icon(Icons.location_on_outlined, size: 14, color: Colors.green[700]),
                                    const SizedBox(width: 4.0),
                                    Expanded(
                                      child: Text(
                                        'Lat: $latStr, Lng: $lngStr',
                                        style: const TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w500,
                                          color: Colors.black87,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6.0),
                                Row(
                                  children: [
                                    Icon(Icons.camera_alt_outlined, size: 14, color: Colors.grey[600]),
                                    const SizedBox(width: 4.0),
                                    Text(
                                      'Method: $captureMethod ($evaluationMethod)',
                                      style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6.0),
                                if (obs['sync_status'] != null)
                                  Row(
                                    children: [
                                      Icon(
                                        obs['sync_status'] == 'UPLOADED'
                                            ? Icons.cloud_done_outlined
                                            : Icons.cloud_upload_outlined,
                                        size: 14,
                                        color: obs['sync_status'] == 'UPLOADED' ? Colors.blue[600] : Colors.amber[800],
                                      ),
                                      const SizedBox(width: 4.0),
                                      Text(
                                        'Sync: ${obs['sync_status']}',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: obs['sync_status'] == 'UPLOADED' ? Colors.blue[600] : Colors.amber[800],
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
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
