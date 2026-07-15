import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_services/shared_services.dart';
import 'package:scout_mobile/src/core/services/network_service.dart';
import 'package:intl/intl.dart';
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
  final Map<String, double> _syncProgress = {};
  final Map<String, String> _syncStatusText = {};
  bool _isBulkSyncing = false;
  int _bulkSyncCompleted = 0;
  int _bulkSyncTotal = 0;

  // Filter state
  DateTime? _filterStartDate;
  DateTime? _filterEndDate;
  String _filterVerificationState = 'All'; // All, Verified, Unverified
  String _filterVerificationStatus = 'All'; // All, Pending, Approved, Rejected
  String _filterVisibility = 'All'; // All, Public, Private
  String _filterStorage = 'All'; // All, Local Only, Synced Only
  String _filterProvince = 'All';
  bool _filterAnonymousOnly = false;

  late final StreamSubscription<bool> _networkSub;

  @override
  void initState() {
    super.initState();
    _fetchObservations();
    ObservationLocalDb.instance.updatePendingCount();
    ProvinceLookup.load().then((_) {
      if (mounted) setState(() {});
    });

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
          'source': e.source.toUpperCase(),
          'evaluation_method': 'MANUAL',
          'is_public': e.isPublic,
          'is_anonymous': e.isAnonymous,
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
              .select('*, verifier:users!observations_verifier_id_fkey(user_name)')
              .eq('user_id', user.id)
              .or('is_deleted.eq.false,is_deleted.is.null')
              .order('observation_timestamp', ascending: false)
              .timeout(const Duration(seconds: 60));

          remoteList = (data as List<dynamic>).map((e) {
            final map = e as Map<String, dynamic>;
            return {
              ...map,
              'timestamp': map['observation_timestamp'] ?? map['upload_timestamp'] ?? DateTime.now().toIso8601String(),
              'final_severity': map['confidence_score'] != null ? 'high' : 'unknown',
              'is_local': false,
            };
          }).toList();
        } on TimeoutException catch (e) {
          debugPrint('Remote fetch timed out, falling back to offline mode: $e');
          NetworkService.instance.forceOffline();
        } catch (e) {
          debugPrint('Remote fetch error: $e');
        }
      }

      if (mounted) {
        setState(() {
          _localObservations = localList;
          _remoteObservations = remoteList;
          _isLoading = false;
          if (!isOnline) {
            _filterStorage = 'All';
            _filterVerificationState = 'All';
            _filterVerificationStatus = 'All';
            _filterVisibility = 'All';
          }
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

  Future<bool> _syncSingleObservation(String observationId, {bool isBulk = false, bool skipConfirmation = false}) async {
    if (!isBulk && !skipConfirmation && mounted) {
      final confirmed = await _showObservationConfirmation(
        title: 'Sync this observation?',
        message: 'This will upload the observation to the system.',
        confirmLabel: 'Sync',
      );
      if (!confirmed) return false;
    }

    final user = Supabase.instance.client.auth.currentUser;
    if (user == null || !NetworkService.instance.isOnline) {
      if (!isBulk) _showToast('Sign in and connect to internet to sync.');
      return false;
    }

    if (_syncingIds.contains(observationId)) return false;

    setState(() {
      _syncingIds.add(observationId);
      _syncProgress[observationId] = 0.0;
      _syncStatusText[observationId] = 'Starting...';
    });

    Timer? progressTimer;
    progressTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        final current = _syncProgress[observationId] ?? 0.0;
        if (current < 0.85) {
          _syncProgress[observationId] = current + 0.015; // Slow ramp up to 85%
        }
      });
    });

    try {
      final obs = await ObservationLocalDb.instance.getById(observationId);
      if (obs == null) throw Exception('Observation not found in local cache.');

      String? remoteImageUrl;

      // 1. Upload image
      if (mounted) setState(() { _syncStatusText[observationId] = 'Uploading Image...'; });
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
      if (mounted) {
        setState(() {
          _syncProgress[observationId] = 0.90;
          _syncStatusText[observationId] = 'Saving Data...';
        });
      }
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
          'is_public': obs.isPublic,
          'is_anonymous': obs.isAnonymous,
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
        setState(() {
          _syncProgress[observationId] = 1.0;
          _syncStatusText[observationId] = 'Done!';
        });
        await Future.delayed(const Duration(milliseconds: 400)); // Show 100% briefly
        if (!isBulk) {
          await _fetchObservations();
        }
      }
      return true;
    } catch (e) {
      await ObservationLocalDb.instance.markFailed(observationId);
      if (!isBulk) {
        _showToast('Sync failed: $e');
        if (mounted) await _fetchObservations();
      }
      return false;
    } finally {
      progressTimer.cancel();
      if (mounted && !isBulk) {
        setState(() {
          _syncingIds.remove(observationId);
          _syncProgress.remove(observationId);
          _syncStatusText.remove(observationId);
        });
      }
    }
  }

  Future<void> _syncAllObservations() async {
    final confirmed = await _showObservationConfirmation(
      title: 'Sync all pending observations?',
      message: 'This will upload all pending observations to the system.',
      confirmLabel: 'Sync All',
    );
    if (!confirmed) return;

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

    int successCount = 0;
    for (final id in pendingIds) {
      final success = await _syncSingleObservation(id, isBulk: true);
      if (success) successCount++;
      if (mounted) {
        setState(() {
          _bulkSyncCompleted++;
        });
      }
    }

    if (mounted) {
      setState(() {
        _isBulkSyncing = false;
        _syncingIds.clear();
        _syncProgress.clear();
        _syncStatusText.clear();
      });
      if (successCount == 1) {
        _showToast('Observation synced successfully!', isError: false);
      } else if (successCount > 1) {
        _showToast('$successCount observations synced successfully!', isError: false);
      }
      await _fetchObservations();
    }
  }

  Map<String, double>? _parseCoordinates(dynamic coordsData) {
    if (coordsData == null) return null;
    if (coordsData is Map) {
      return {'lat': (coordsData['lat'] as num).toDouble(), 'lng': (coordsData['lng'] as num).toDouble()};
    }
    if (coordsData is String) {
      final trimmed = coordsData.trim();
      final hexRegex = RegExp(r'^(0x)?[0-9a-fA-F]+$');
      if (hexRegex.hasMatch(trimmed)) {
        return _parseEWKB(trimmed);
      }
      final match = RegExp(r'POINT\s*\(\s*([-\d.]+)\s+([-\d.]+)\s*\)', caseSensitive: false).firstMatch(trimmed);
      if (match != null) {
        return {'lat': double.parse(match.group(2)!), 'lng': double.parse(match.group(1)!)};
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

  // Filter logic
  List<Map<String, dynamic>> _applyFilters(List<Map<String, dynamic>> observations, {required bool isLocal}) {
    if (_filterStorage == 'Local Only' && !isLocal) return [];
    if (_filterStorage == 'Synced Only' && isLocal) return [];

    return observations.where((obs) {
      // Date filter
      final ts = obs['timestamp'];
      if (ts != null) {
        final date = DateTime.tryParse(ts);
        if (date != null) {
          if (_filterStartDate != null && date.isBefore(_filterStartDate!)) return false;
          if (_filterEndDate != null && date.isAfter(_filterEndDate!.add(const Duration(days: 1)))) return false;
        }
      }

      // Verification filter
      final verificationResult = obs['verification_result']?.toString();
      final underVerification = obs['under_verification'] == true;
      final isVerified = underVerification || verificationResult != null;

      if (_filterVerificationState != 'All') {
        if (_filterVerificationState == 'Unverified' && isVerified) return false;
        if (_filterVerificationState == 'Verified' && !isVerified) return false;
      }

      if (_filterVerificationState != 'Unverified' && _filterVerificationStatus != 'All') {
        if (_filterVerificationStatus == 'Pending' && !underVerification) return false;
        if (_filterVerificationStatus == 'Approved' && verificationResult != 'APPROVED') return false;
        if (_filterVerificationStatus == 'Rejected' && verificationResult != 'REJECTED') return false;
      }

      // Visibility filter
      if (_filterVisibility != 'All') {
        final isPublic = obs['is_public'] == true;
        if (_filterVisibility == 'Public' && !isPublic) return false;
        if (_filterVisibility == 'Private' && isPublic) return false;
      }

      // Anonymity filter
      if (_filterAnonymousOnly) {
        final isAnonymous = obs['is_public'] == true && obs['is_anonymous'] == true;
        if (!isAnonymous) return false;
      }

      // Province filter
      if (_filterProvince != 'All') {
        final coords = _parseCoordinates(obs['coordinates']);
        final double? lat = obs['latitude'] != null ? double.tryParse(obs['latitude'].toString()) : coords?['lat'];
        final double? lng = obs['longitude'] != null ? double.tryParse(obs['longitude'].toString()) : coords?['lng'];
        if (lat == null || lng == null || ProvinceLookup.provinceForPoint(lat, lng) != _filterProvince) return false;
      }

      return true;
    }).toList();
  }

  void _showFilterSheet() {
    final isOnline = NetworkService.instance.isOnline;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: EdgeInsets.fromLTRB(24, 24, 24, MediaQuery.of(context).viewInsets.bottom + 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(Icons.filter_list_rounded, color: Colors.green[700]),
                      const SizedBox(width: 8),
                      const Text(
                        'Filter Observations',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  const Divider(height: 24),
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (isOnline) ...[
                          // Storage Filter
                          InputDecorator(
                            decoration: InputDecoration(
                              labelText: 'Storage State',
                              prefixIcon: Icon(Icons.storage, color: Colors.green[700]),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                            ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<String>(
                                value: _filterStorage,
                                isExpanded: true,
                                items: ['All', 'Local Only', 'Synced Only'].map((String value) {
                                  return DropdownMenuItem<String>(
                                    value: value,
                                    child: Text(value),
                                  );
                                }).toList(),
                                onChanged: (val) {
                                  if (val != null) {
                                    setModalState(() {
                                      _filterStorage = val;
                                      if (val == 'Local Only') {
                                        _filterVerificationState = 'All';
                                        _filterVerificationStatus = 'All';
                                        _filterVisibility = 'All';
                                      }
                                    });
                                    setState(() {
                                      _filterStorage = val;
                                      if (val == 'Local Only') {
                                        _filterVerificationState = 'All';
                                        _filterVerificationStatus = 'All';
                                        _filterVisibility = 'All';
                                      }
                                    });
                                  }
                                },
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          // Verification State Filter
                          InputDecorator(
                            decoration: InputDecoration(
                              labelText: 'Verification State',
                              prefixIcon: Icon(Icons.verified_outlined, color: _filterStorage == 'Local Only' ? Colors.grey : Colors.green[700]),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                            ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<String>(
                                value: _filterVerificationState,
                                isExpanded: true,
                                items: ['All', 'Verified', 'Unverified'].map((String value) {
                                  return DropdownMenuItem<String>(
                                    value: value,
                                    child: Text(value),
                                  );
                                }).toList(),
                                onChanged: _filterStorage == 'Local Only' ? null : (val) {
                                  if (val != null) {
                                    setModalState(() {
                                      _filterVerificationState = val;
                                      if (val == 'Unverified') _filterVerificationStatus = 'All';
                                    });
                                    setState(() {
                                      _filterVerificationState = val;
                                      if (val == 'Unverified') _filterVerificationStatus = 'All';
                                    });
                                  }
                                },
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          // Verification Status Filter
                          InputDecorator(
                            decoration: InputDecoration(
                              labelText: 'Verification Status',
                              prefixIcon: Icon(Icons.fact_check_outlined, color: (_filterStorage == 'Local Only' || _filterVerificationState == 'Unverified') ? Colors.grey : Colors.green[700]),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                            ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<String>(
                                value: _filterVerificationStatus,
                                isExpanded: true,
                                items: ['All', 'Pending', 'Approved', 'Rejected'].map((String value) {
                                  return DropdownMenuItem<String>(
                                    value: value,
                                    child: Text(value),
                                  );
                                }).toList(),
                                onChanged: (_filterStorage == 'Local Only' || _filterVerificationState == 'Unverified') ? null : (val) {
                                  if (val != null) {
                                    setModalState(() {
                                      _filterVerificationStatus = val;
                                      if (val == 'Rejected') _filterVisibility = 'All';
                                    });
                                    setState(() {
                                      _filterVerificationStatus = val;
                                      if (val == 'Rejected') _filterVisibility = 'All';
                                    });
                                  }
                                },
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          ],
                          // Visibility Filter (available offline too, since owners can toggle
                          // visibility on their own observations without a connection)
                          InputDecorator(
                            decoration: InputDecoration(
                              labelText: 'Visibility',
                              prefixIcon: Icon(Icons.public, color: (isOnline && _filterVerificationStatus == 'Rejected') ? Colors.grey : Colors.green[700]),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                            ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<String>(
                                value: _filterVisibility,
                                isExpanded: true,
                                items: ['All', 'Public', 'Private'].map((String value) {
                                  return DropdownMenuItem<String>(
                                    value: value,
                                    child: Text(value),
                                  );
                                }).toList(),
                                onChanged: (isOnline && _filterVerificationStatus == 'Rejected') ? null : (val) {
                                  if (val != null) {
                                    setModalState(() => _filterVisibility = val);
                                    setState(() => _filterVisibility = val);
                                  }
                                },
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          // Date Filters
                          ListTile(
                            leading: Icon(Icons.calendar_today, color: Colors.green[700]),
                            title: Text(
                              _filterStartDate != null
                                  ? 'From: ${_filterStartDate!.toLocal().toString().substring(0, 10)}'
                                  : 'From: Any Date',
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
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: Colors.grey[300]!)),
                          ),
                          const SizedBox(height: 8),
                          ListTile(
                            leading: Icon(Icons.event, color: Colors.green[700]),
                            title: Text(
                              _filterEndDate != null
                                  ? 'To: ${_filterEndDate!.toLocal().toString().substring(0, 10)}'
                                  : 'To: Any Date',
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
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: Colors.grey[300]!)),
                          ),
                          const SizedBox(height: 16),
                          // Province Filter
                          InputDecorator(
                            decoration: InputDecoration(
                              labelText: 'Province',
                              prefixIcon: Icon(Icons.map_outlined, color: Colors.green[700]),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                            ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<String>(
                                value: _filterProvince,
                                isExpanded: true,
                                items: ProvinceLookup.buildDropdownItems(),
                                selectedItemBuilder: (context) {
                                  return ProvinceLookup.buildDropdownItems().map((item) {
                                    if (item.value?.startsWith('HEADER_') == true) return const SizedBox.shrink();
                                    return Align(
                                      alignment: Alignment.centerLeft,
                                      child: Text(item.value == 'All' ? 'All Provinces' : item.value!, style: const TextStyle(fontSize: 14)),
                                    );
                                  }).toList();
                                },
                                onChanged: (val) {
                                  if (val != null && !val.startsWith('HEADER_')) {
                                    setModalState(() => _filterProvince = val);
                                    setState(() => _filterProvince = val);
                                  }
                                },
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          // Anonymity Filter
                          Container(
                            decoration: BoxDecoration(
                              color: Colors.grey.shade100,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.grey.shade300),
                            ),
                            child: SwitchListTile(
                              title: const Text('Anonymous Only', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                              subtitle: const Text('Show only observations submitted anonymously', style: TextStyle(fontSize: 11)),
                              value: _filterAnonymousOnly,
                              activeTrackColor: Colors.green.shade200,
                              activeThumbColor: Colors.green.shade700,
                              onChanged: (val) {
                                setModalState(() => _filterAnonymousOnly = val);
                                setState(() => _filterAnonymousOnly = val);
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () {
                            setModalState(() {
                              _filterStartDate = null;
                              _filterEndDate = null;
                              _filterVerificationState = 'All';
                              _filterVerificationStatus = 'All';
                              _filterVisibility = 'All';
                              _filterStorage = 'All';
                              _filterProvince = 'All';
                              _filterAnonymousOnly = false;
                            });
                            setState(() {
                              _filterStartDate = null;
                              _filterEndDate = null;
                              _filterVerificationState = 'All';
                              _filterVerificationStatus = 'All';
                              _filterVisibility = 'All';
                              _filterStorage = 'All';
                              _filterProvince = 'All';
                              _filterAnonymousOnly = false;
                            });
                          },
                          icon: const Icon(Icons.clear),
                          label: const Text('Clear'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.grey[700],
                            side: BorderSide(color: Colors.grey[300]!),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          onPressed: () => Navigator.pop(context),
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.green[700],
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          child: const Text('Apply', style: TextStyle(fontWeight: FontWeight.bold)),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }



  @override
  Widget build(BuildContext context) {
    final hasActiveFilter = _filterStartDate != null || _filterEndDate != null || _filterVerificationState != 'All' || _filterVerificationStatus != 'All' || _filterVisibility != 'All' || _filterStorage != 'All' || _filterProvince != 'All' || _filterAnonymousOnly;

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
              onPressed: _showFilterSheet,
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
                  final result = await Navigator.push<dynamic>(
                    context,
                    MaterialPageRoute(builder: (context) => const AddObservationPage()),
                  );
                  if (result is String) {
                    await _fetchObservations();
                    _syncSingleObservation(result);
                  } else if (result == true) {
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

    final filteredLocal = _applyFilters(_localObservations, isLocal: true);
    final filteredRemote = _applyFilters(_remoteObservations, isLocal: false);
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
    final rawTimestamp = obs['timestamp'];
    final rawDate = rawTimestamp != null ? DateTime.tryParse(rawTimestamp.toString()) : null;
    final dateStr = rawDate != null ? DateFormat.yMMMd().add_jm().format(rawDate.toLocal()) : 'Unknown Date';
    final imageUrl = obs['image_url']?.toString();
    final localImagePath = obs['image_path']?.toString();

    final verificationResult = obs['verification_result']?.toString();
    final underVerification = obs['under_verification'] == true;
    final isPublic = obs['is_public'] == true;
    final remarks = obs['remarks']?.toString();

    String verifyText = 'UNVERIFIED';
    Color verifyBg = Colors.grey[100]!;
    Color verifyTextCol = Colors.grey[700]!;
    Color borderColor = isLocal ? Colors.amber[700]! : Colors.blue[600]!;

    if (verificationResult == 'APPROVED') {
      verifyText = 'APPROVED';
      verifyBg = Colors.green[50]!;
      verifyTextCol = Colors.green[800]!;
      if (!isLocal) borderColor = Colors.green[600]!;
    } else if (verificationResult == 'REJECTED') {
      verifyText = 'REJECTED';
      verifyBg = Colors.red[50]!;
      verifyTextCol = Colors.red[800]!;
      if (!isLocal) borderColor = Colors.red[600]!;
    } else if (underVerification) {
      verifyText = 'PENDING';
      verifyBg = Colors.purple[50]!;
      verifyTextCol = Colors.purple[800]!;
      if (!isLocal) borderColor = Colors.purple[600]!;
    }

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
            _syncSingleObservation(observationId, skipConfirmation: true);
          } else if (result == 'DELETE' && isLocal) {
            await ObservationLocalDb.instance.deleteObservation(observationId);
            _fetchObservations();
          } else if (result == 'DELETED_SYSTEM' || result == 'VERIFICATION_REQUESTED') {
            _fetchObservations();
          } else if (result == 'MODIFIED') {
            setState(() {});
          }
        },
        child: Column(
          children: [
            IntrinsicHeight(
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
                SizedBox(
                  width: 95,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Positioned.fill(
                        child: ClipRRect(
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
                    ],
                  ),
                ),
                // Details
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(14.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          dateStr,
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black87),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
    
                            // Verification Badge
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: verifyBg,
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: verifyTextCol.withValues(alpha: 0.3)),
                              ),
                              child: Text(
                                verifyText,
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w800,
                                  color: verifyTextCol,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ),
                            // Privacy Badge
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: isPublic ? Colors.teal[50] : Colors.grey[100],
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: isPublic ? Colors.teal[200]! : Colors.grey[300]!),
                              ),
                              child: Text(
                                isPublic ? 'PUBLIC' : 'PRIVATE',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w800,
                                  color: isPublic ? Colors.teal[700] : Colors.grey[600],
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (remarks != null && remarks.trim().isNotEmpty) ...[
                          const SizedBox(height: 10),
                          Text(
                            '💬 "${remarks.trim()}"',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, color: Colors.grey[600], fontStyle: FontStyle.italic),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
            ),
            if (_syncingIds.contains(observationId))
              ClipRRect(
                borderRadius: const BorderRadius.only(bottomLeft: Radius.circular(16), bottomRight: Radius.circular(16)),
                child: Container(
                  color: Colors.green[50],
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _syncStatusText[observationId] ?? 'Syncing...',
                              style: TextStyle(fontSize: 10, color: Colors.green[800], fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 6),
                            LinearProgressIndicator(
                              value: (_syncProgress[observationId] ?? 0.0).clamp(0.0, 1.0),
                              backgroundColor: Colors.green[100],
                              valueColor: AlwaysStoppedAnimation<Color>(Colors.green[700]!),
                              minHeight: 6,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 16),
                      SizedBox(
                        width: 35,
                        child: Text(
                          '${(((_syncProgress[observationId] ?? 0.0).clamp(0.0, 1.0)) * 100).toInt()}%',
                          style: TextStyle(fontSize: 12, color: Colors.green[800], fontWeight: FontWeight.bold),
                          textAlign: TextAlign.right,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
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

  // Helper function to show confirmation dialog
  Future<bool> _showObservationConfirmation({
    required String title,
    required String message,
    required String confirmLabel,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(confirmLabel),
            ),
          ],
        );
      },
    );
    return result ?? false;
  }
}
