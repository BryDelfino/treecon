// ignore_for_file: avoid_dynamic_calls

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_services/shared_services.dart';
import 'package:scout_mobile/src/core/services/network_service.dart';
import 'package:intl/intl.dart';
import 'package:scout_mobile/src/features/observations/data/observation_local_db.dart';
import 'package:scout_mobile/src/features/map/presentation/pages/map_page.dart';
import '../widgets/full_screen_image_viewer.dart';

class ObservationDetailsPage extends StatefulWidget {
  final Map<String, dynamic> obs;
  final bool isCached;
  final bool showViewOnMapButton;

  const ObservationDetailsPage({
    super.key,
    required this.obs,
    this.isCached = false,
    this.showViewOnMapButton = false,
  });

  @override
  State<ObservationDetailsPage> createState() => _ObservationDetailsPageState();
}

class _ObservationDetailsPageState extends State<ObservationDetailsPage> {
  bool _isLoading = false;
  bool _wasModified = false;
  RealtimeChannel? _subscription;
  bool _isOnline = true;
  StreamSubscription<bool>? _networkSub;
  String _province = 'Loading...';
  bool _isLoadingProvince = true;
  late bool _isPublic;
  late bool _isAnonymous;

  @override
  void initState() {
    super.initState();
    _isPublic = widget.obs['is_public'] == true;
    _isAnonymous = widget.obs['is_anonymous'] == true;
    _isOnline = NetworkService.instance.isOnline;
    _networkSub = NetworkService.instance.onConnectivityChanged.listen((isOnline) {
      if (mounted) {
        setState(() => _isOnline = isOnline);
        if (!isOnline && !widget.isCached) {
          _showToast('Connection lost. Returning to observations list.');
          Navigator.pop(context, _wasModified ? 'REFRESH' : null);
        }
      }
    });

    if (!widget.isCached) {
      _syncLatestState();
      _setupRealtime();
    }
    _loadProvince();
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

  Future<void> _loadProvince() async {
    final coords = _parseCoordinates(widget.obs['coordinates']);
    final double? lat = widget.obs['latitude'] != null ? double.tryParse(widget.obs['latitude'].toString()) : coords?['lat'];
    final double? lng = widget.obs['longitude'] != null ? double.tryParse(widget.obs['longitude'].toString()) : coords?['lng'];

    if (lat == null || lng == null) {
      if (mounted) setState(() { _province = 'Unknown'; _isLoadingProvince = false; });
      return;
    }

    await ProvinceLookup.load();
    if (mounted) {
      setState(() {
        _province = ProvinceLookup.provinceForPoint(lat, lng);
        _isLoadingProvince = false;
      });
    }
  }

  void _setupRealtime() {
    final observationId = widget.obs['observation_id'];
    _subscription = Supabase.instance.client
        .channel('public:observations:detail:$observationId')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'observations',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'observation_id',
            value: observationId,
          ),
          callback: (payload) async {
            if (mounted) {
              await _syncLatestState();
              setState(() {
                _wasModified = true;
              });
            }
          },
        )
        .subscribe();
  }

  @override
  void dispose() {
    _networkSub?.cancel();
    if (_subscription != null) {
      Supabase.instance.client.removeChannel(_subscription!);
    }
    super.dispose();
  }

  void _showToast(String msg, {bool isError = true}) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(
              isError ? Icons.error_outline_rounded : Icons.check_circle_outline_rounded,
              color: Colors.white,
              size: 20,
            ),
            const SizedBox(width: 12.0),
            Expanded(
              child: Text(
                msg,
                style: const TextStyle(fontWeight: FontWeight.w500, color: Colors.white),
              ),
            ),
            const SizedBox(width: 8.0),
            IconButton(
              icon: const Icon(Icons.close_rounded, color: Colors.white70, size: 18),
              onPressed: () => messenger.hideCurrentSnackBar(),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              splashRadius: 16.0,
            ),
          ],
        ),
        backgroundColor: isError ? Colors.red[800] : Colors.green[800],
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12.0)),
        margin: const EdgeInsets.all(16.0),
      ),
    );
  }

  Future<bool> _syncLatestState() async {
    if (widget.isCached) return true;
    try {
      final id = widget.obs['observation_id'];
      final latest = await Supabase.instance.client
          .from('observations')
          .select('is_public, is_anonymous, under_verification, verification_result, remarks, verification_timestamp, verifier:users!observations_verifier_id_fkey(user_name)')
          .eq('observation_id', id)
          .maybeSingle();
      if (latest != null && mounted) {
        final isRejected = latest['verification_result']?.toString().toUpperCase() == 'REJECTED';
        setState(() {
          final latestIsPublic = latest['is_public'] == true;
          _isPublic = isRejected ? false : latestIsPublic;
          _isAnonymous = latest['is_anonymous'] == true;
          widget.obs['is_public'] = _isPublic;
          widget.obs['is_anonymous'] = _isAnonymous;
          widget.obs['under_verification'] = latest['under_verification'];
          widget.obs['verification_result'] = latest['verification_result'];
          widget.obs['remarks'] = latest['remarks'];
          widget.obs['verification_timestamp'] = latest['verification_timestamp'];
          if (latest['verifier'] != null) {
            widget.obs['verifier'] = latest['verifier'];
          }
        });
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<void> _handleDelete() async {
    final confirmed = await _showObservationConfirmation(
      title: 'Delete this observation?',
      message: 'This action cannot be undone.',
      confirmLabel: 'Delete',
    );
    if (!confirmed) return;
    if (!mounted) return;

    if (widget.isCached) {
      Navigator.pop(context, 'DELETE');
    } else {
      setState(() => _isLoading = true);
      try {
        final id = widget.obs['observation_id'];
        await Supabase.instance.client
            .from('observations')
            .update({'is_deleted': true})
            .eq('observation_id', id);
        if (mounted) {
          _showToast('Observation deleted successfully.', isError: false);
          Navigator.pop(context, 'DELETED_SYSTEM');
        }
      } catch (e) {
        _showToast('Failed to delete: $e');
      } finally {
        if (mounted) setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _handleUpload() async {
    final confirmed = await _showObservationConfirmation(
      title: 'Sync this observation?',
      message: 'This will upload the observation to the system.',
      confirmLabel: 'Sync',
    );
    if (!confirmed) return;
    if (!mounted) return;

    Navigator.pop(context, 'UPLOAD');
  }

  Future<void> _handleRequestVerification() async {
    setState(() => _isLoading = true);
    await _syncLatestState();
    if (!mounted) return;
    setState(() => _isLoading = false);

    if (widget.obs['under_verification'] == true || widget.obs['verification_result'] == 'APPROVED' || widget.obs['verification_result'] == 'REJECTED') {
      _showToast('Observation is already under verification or verified.');
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Verification Terms'),
        content: const Text(
            'By proceeding, your observation will be queued for expert verification. It must be set to public during this process.\n\n'
            'Please ensure that the uploaded image is clear and the observation subject is distinctly visible to assist our experts.\n\n'
            'While pending, you can withdraw your request, set it back to private, or delete it at any time.\n\n'
            'However, if an expert REJECTS this observation, it can never be made public again, and you will have to eventually delete it. Do you wish to proceed?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Proceed', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _isLoading = true);
    try {
      final id = widget.obs['observation_id'];
      await Supabase.instance.client
          .from('observations')
          .update({
            'is_public': true,
            'under_verification': true,
            'verification_result': 'PENDING'
          })
          .eq('observation_id', id);
          
      if (mounted) {
        _showToast('Verification requested successfully.', isError: false);
        setState(() {
          widget.obs['is_public'] = true;
          _isPublic = true;
          widget.obs['under_verification'] = true;
          widget.obs['verification_result'] = 'PENDING';
        });
        _wasModified = true;
      }
    } catch (e) {
      _showToast('Failed to request verification: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _handleCancelVerification() async {
    setState(() => _isLoading = true);
    await _syncLatestState();
    if (!mounted) return;
    setState(() => _isLoading = false);

    if (widget.obs['under_verification'] != true) {
      _showToast('Observation is no longer pending verification.');
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel Request?'),
        content: const Text('Are you sure you want to cancel your request for expert verification?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('No', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Yes, Cancel', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _isLoading = true);
    try {
      final id = widget.obs['observation_id'];
      await Supabase.instance.client
          .from('observations')
          .update({
            'under_verification': false,
            'verification_result': null,
          })
          .eq('observation_id', id);
          
      if (mounted) {
        _showToast('Verification request cancelled.', isError: false);
        setState(() {
          widget.obs['under_verification'] = false;
          widget.obs['verification_result'] = null;
        });
        _wasModified = true;
      }
    } catch (e) {
      _showToast('Failed to cancel request: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _updatePrivacySettings(bool newPublic, bool newAnon) async {
    final underVerification = widget.obs['under_verification'] == true;
    final id = widget.obs['observation_id'];

    if (!_canManageObservationPrivacy(
      isOwner: widget.obs['user_id'] == Supabase.instance.client.auth.currentUser?.id,
      verificationResult: widget.obs['verification_result']?.toString(),
    )) {
      _showToast('Rejected observations cannot change their visibility settings.');
      setState(() {
        _isPublic = false;
        _isAnonymous = widget.obs['is_anonymous'] == true;
      });
      return;
    }

    if (widget.isCached) {
      setState(() {
        _isPublic = newPublic;
        _isAnonymous = newAnon;
        widget.obs['is_public'] = newPublic;
        widget.obs['is_anonymous'] = newAnon;
      });
      await ObservationLocalDb.instance.updateObservationSettings(id, newPublic, newAnon);
      return;
    }

    final wasPublic = widget.obs['is_public'] == true;
    if (newPublic == false && wasPublic && underVerification) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Warning'),
          content: const Text('Setting this observation to private will also remove it from the expert verification queue. Do you want to proceed?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Proceed', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      );
      if (confirm != true) {
        // Revert switch visually
        setState(() {
          _isPublic = widget.obs['is_public'] == true;
        });
        return;
      }
    }

    setState(() => _isLoading = true);
    try {
      final updates = <String, dynamic>{
        'is_public': newPublic,
        'is_anonymous': newAnon,
      };
      
      if (newPublic == false && wasPublic && underVerification) {
        updates['under_verification'] = false;
        updates['verification_result'] = null;
      }

      await Supabase.instance.client
          .from('observations')
          .update(updates)
          .eq('observation_id', id);
          
      if (mounted) {
        setState(() {
          _isPublic = newPublic;
          _isAnonymous = newAnon;
          widget.obs['is_public'] = newPublic;
          widget.obs['is_anonymous'] = newAnon;
          if (updates.containsKey('under_verification')) {
            widget.obs['under_verification'] = false;
            widget.obs['verification_result'] = null;
          }
        });
        _wasModified = true;
      }
    } catch (e) {
      _showToast('Failed to update privacy settings: $e');
      if (mounted) {
        setState(() {
          _isPublic = widget.obs['is_public'] == true;
          _isAnonymous = widget.obs['is_anonymous'] == true;
        });
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rawDateStr = widget.obs['observation_timestamp'] ?? widget.obs['timestamp'];
    final rawDate = rawDateStr != null ? DateTime.tryParse(rawDateStr.toString()) : null;
    final dateStr = rawDate != null ? DateFormat.yMMMd().add_jm().format(rawDate.toLocal()) : 'Unknown Date';
    
    final rawUploadStr = widget.obs['upload_timestamp'];
    final rawUpload = rawUploadStr != null ? DateTime.tryParse(rawUploadStr.toString()) : null;
    final uploadStr = rawUpload != null ? DateFormat.yMMMd().add_jm().format(rawUpload.toLocal()) : 'Not Uploaded Yet';
        
    final coords = _parseCoordinates(widget.obs['coordinates']);
    final double? lat = widget.obs['latitude'] != null ? double.tryParse(widget.obs['latitude'].toString()) : coords?['lat'];
    final double? lng = widget.obs['longitude'] != null ? double.tryParse(widget.obs['longitude'].toString()) : coords?['lng'];
    final latStr = lat != null ? lat.toStringAsFixed(6) : 'N/A';
    final lngStr = lng != null ? lng.toStringAsFixed(6) : 'N/A';

    final isVerified = widget.obs['verification_result'] == 'APPROVED' || widget.obs['verification_result'] == 'REJECTED';
    final rawVerificationResult = widget.obs['verification_result']?.toString() ?? 'NONE';
    final verificationResult = rawVerificationResult == 'APPROVED' ? 'Verified' : (rawVerificationResult == 'REJECTED' ? 'Rejected' : rawVerificationResult);
    final underVerification = widget.obs['under_verification'] == true;
    
    final imageUrl = widget.obs['image_url']?.toString();
    final localImagePath = widget.obs['image_path']?.toString();
    final isOwner = widget.obs['user_id'] == Supabase.instance.client.auth.currentUser?.id;
    final canManagePrivacy = _canManageObservationPrivacy(
      isOwner: isOwner,
      verificationResult: rawVerificationResult,
    );

    Color verifyColor = Colors.orange;
    
    if (isVerified) {
      if (rawVerificationResult == 'APPROVED') {
        verifyColor = Colors.blue;
      } else if (rawVerificationResult == 'REJECTED') {
        verifyColor = Colors.red;
      } else {
        verifyColor = Colors.blue;
      }
    } else if (underVerification) {
      verifyColor = Colors.purple;
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        Navigator.pop(context, _wasModified ? 'MODIFIED' : null);
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Observation Details', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          backgroundColor: Colors.white,
          foregroundColor: Colors.green[800],
          elevation: 1,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.pop(context, _wasModified ? 'MODIFIED' : null),
          ),
        ),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.all(16.0),
            children: [
              // Image
              GestureDetector(
                onTap: (localImagePath != null && localImagePath.isNotEmpty && File(localImagePath).existsSync()) ||
                        (imageUrl != null && imageUrl.isNotEmpty)
                    ? () => FullScreenImageViewer.show(context, imageUrl: imageUrl, localImagePath: localImagePath)
                    : null,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: localImagePath != null && localImagePath.isNotEmpty && File(localImagePath).existsSync()
                      ? Image.file(
                          File(localImagePath),
                          height: 250,
                          width: double.infinity,
                          fit: BoxFit.cover,
                        )
                      : (imageUrl != null && imageUrl.isNotEmpty
                          ? Image.network(
                              imageUrl,
                              height: 250,
                              width: double.infinity,
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stackTrace) => Container(
                                height: 250,
                                color: Colors.green[50],
                                child: Icon(Icons.broken_image, color: Colors.green[200], size: 64),
                              ),
                            )
                          : Container(
                              height: 250,
                              color: Colors.green[50],
                              child: Icon(Icons.park_outlined, color: Colors.green[200], size: 64),
                            )),
                ),
              ),
              const SizedBox(height: 24),
              
              // Metadata
              _buildMetaRow(Icons.calendar_today, 'Observation Timestamp', dateStr),
              if (!widget.isCached)
                _buildMetaRow(Icons.cloud_upload, 'Upload Timestamp', uploadStr),
              _buildMetaRow(Icons.location_on, 'Location', _isLoadingProvince ? 'Loading...' : _province),
              if (isOwner || widget.isCached)
                _buildMetaRow(Icons.explore, 'Coordinates (Lat/Lng)', '$latStr, $lngStr'),
              if (isVerified) ...[
                const SizedBox(height: 16),
                const Text('Expert Verification', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.black87)),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: verifyColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: verifyColor.withValues(alpha: 0.3)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildMetaRow(Icons.gavel, 'Result', verificationResult),
                      _buildMetaRow(Icons.person, 'Verified By', widget.obs['verifier'] != null ? widget.obs['verifier']['user_name'] : 'Unknown'),
                      Builder(
                        builder: (context) {
                          final rawVerificationStr = widget.obs['verification_timestamp'];
                          final rawVerification = rawVerificationStr != null ? DateTime.tryParse(rawVerificationStr.toString()) : null;
                          final verificationStr = rawVerification != null ? DateFormat.yMMMd().add_jm().format(rawVerification.toLocal()) : 'Unknown Date';
                          return _buildMetaRow(Icons.access_time, 'Verification Timestamp', verificationStr);
                        }
                      ),
                      if (widget.obs['remarks'] != null && widget.obs['remarks'].toString().isNotEmpty) ...[
                        const Divider(height: 24),
                        const Text('Expert Remarks', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black87)),
                        const SizedBox(height: 4),
                        Text(widget.obs['remarks'].toString(), style: const TextStyle(color: Colors.black87)),
                      ],
                    ],
                  ),
                ),
              ],
              if (canManagePrivacy) ...[
                const SizedBox(height: 16),
                const Text('Privacy Settings', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.black87)),
                const SizedBox(height: 8),
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey[200]!),
                  ),
                  child: Column(
                    children: [
                      SwitchListTile(
                        title: const Text('Public Observation', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                        subtitle: const Text('Allow others to view this', style: TextStyle(fontSize: 12)),
                        value: _isPublic,
                        activeTrackColor: Colors.green[700],
                        onChanged: (val) {
                          setState(() => _isPublic = val);
                          _updatePrivacySettings(val, _isAnonymous);
                        },
                      ),
                      const Divider(height: 1),
                      SwitchListTile(
                        title: const Text('Submit Anonymously', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                        subtitle: const Text('Hide your username', style: TextStyle(fontSize: 12)),
                        value: _isAnonymous,
                        activeTrackColor: Colors.green[700],
                        onChanged: (val) {
                          setState(() => _isAnonymous = val);
                          _updatePrivacySettings(_isPublic, val);
                        },
                      ),
                    ],
                  ),
                ),
              ],



              const SizedBox(height: 32),

              // Action Buttons
              if (widget.showViewOnMapButton) ...[
                OutlinedButton.icon(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => MapPage(highlightObservation: widget.obs),
                      ),
                    );
                  },
                  icon: const Icon(Icons.map_outlined),
                  label: const Text('View on Map'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.green[700],
                    side: BorderSide(color: Colors.green[700]!),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              if (widget.isCached)
                ElevatedButton.icon(
                  onPressed: _isOnline ? _handleUpload : null,
                  icon: const Icon(Icons.cloud_upload),
                  label: Text(_isOnline ? 'Upload to System' : 'Offline (Cannot Upload)'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green[700],
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: Colors.grey[400],
                    disabledForegroundColor: Colors.white70,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
                
              if (!widget.isCached && !isVerified && !underVerification && isOwner) ...[
                ElevatedButton.icon(
                  onPressed: _handleRequestVerification,
                  icon: const Icon(Icons.fact_check),
                  label: const Text('Request Expert Verification'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green[700],
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ],
              
              if (!widget.isCached && underVerification && isOwner) ...[
                OutlinedButton.icon(
                  onPressed: _handleCancelVerification,
                  icon: const Icon(Icons.cancel_schedule_send),
                  label: const Text('Cancel Verification Request'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.orange,
                    side: const BorderSide(color: Colors.orange),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ],

              const SizedBox(height: 12),
              
              if (isOwner)
                OutlinedButton.icon(
                  onPressed: _handleDelete,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Delete Observation'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red,
                    side: const BorderSide(color: Colors.red),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
            ],
          ),
          if (_isLoading)
            Container(
              color: Colors.black.withValues(alpha: 0.3),
              child: const Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    ));
  }

  Widget _buildMetaRow(IconData icon, String label, String value, {Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: color ?? Colors.grey[600]),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: TextStyle(fontSize: 12, color: Colors.grey[600], fontWeight: FontWeight.bold)),
                const SizedBox(height: 2),
                Text(value, style: TextStyle(fontSize: 15, color: color ?? Colors.black87)),
              ],
            ),
          ),
        ],
      ),
    );
  }
  // Helper function to check if user can manage observation privacy
  bool _canManageObservationPrivacy({
    required bool isOwner,
    required String? verificationResult,
  }) {
    if (!isOwner) return false;
    if (verificationResult?.toString().toUpperCase() == 'REJECTED') return false;
    return true;
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
  }}
