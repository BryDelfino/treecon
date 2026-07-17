// ignore_for_file: avoid_dynamic_calls
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_services/shared_services.dart';
import 'dart:typed_data';
import 'package:intl/intl.dart';
import '../widgets/full_screen_image_viewer.dart';
import '../../../map/presentation/pages/map.dart';

class ObservationDetailsPage extends StatefulWidget {
  final Map<String, dynamic> obs;
  final bool isVerifyMode;
  final bool showViewOnMapButton;
  /// The viewing user's role (e.g. 'EXPERT'), if already known by the caller.
  /// Passed down instead of fetched here so expert-only fields render
  /// immediately with the rest of the page instead of popping in late.
  final String? currentUserRole;
  /// When set, "View on Map" pops back to the dashboard shell and calls
  /// this to switch to the Spatial Map tab with the observation highlighted,
  /// instead of pushing a full-screen route that hides the sidebar.
  final void Function(Map<String, dynamic> obs)? onViewOnMap;

  const ObservationDetailsPage({
    super.key,
    required this.obs,
    required this.isVerifyMode,
    this.showViewOnMapButton = true,
    this.currentUserRole,
    this.onViewOnMap,
  });

  @override
  State<ObservationDetailsPage> createState() => _ObservationDetailsPageState();
}

class _ObservationDetailsPageState extends State<ObservationDetailsPage> {
  String? _selectedResult;
  final TextEditingController _remarksController = TextEditingController();
  final _verificationFormKey = GlobalKey<FormState>();
  bool _isSubmitting = false;
  bool _isLoading = false;
  bool _wasModified = false;
  late bool _isPublic;
  late bool _isAnonymous;

  String? _province;
  bool _isLoadingProvince = true;

  RealtimeChannel? _subscription;

  @override
  void initState() {
    super.initState();
    _isPublic = widget.obs['is_public'] == true;
    _isAnonymous = widget.obs['is_anonymous'] == true;
    _fetchProvince();
    _setupRealtime();
  }

  void _setupRealtime() {
    final observationId = widget.obs['observation_id'] ?? widget.obs['id'];
    _subscription = Supabase.instance.client
        .channel('public:observations:commander_detail:$observationId')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'observations',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'observation_id',
            value: observationId,
          ),
          callback: (payload) {
            if (mounted && !_isSubmitting) {
              final newRow = payload.newRecord;
              if (widget.isVerifyMode && (newRow['under_verification'] != true || newRow['is_public'] != true || newRow['is_deleted'] == true)) {
                _showToast(_describeQueueExitReason(newRow), isError: true);
                Navigator.pop(context, true); // Pop out and signal the list to refresh
              } else {
                setState(() {
                  widget.obs['is_anonymous'] = newRow['is_anonymous'];
                  widget.obs['is_public'] = newRow['is_public'];
                  widget.obs['under_verification'] = newRow['under_verification'];
                  widget.obs['verification_result'] = newRow['verification_result'];
                  _isPublic = newRow['is_public'] == true;
                  _isAnonymous = newRow['is_anonymous'] == true;
                });
              }
            }
          },
        )
        .subscribe();
  }

  /// Explains why an observation is no longer eligible for verification,
  /// distinguishing "someone else already verified it" from the user
  /// withdrawing/deleting/privating it themselves.
  String _describeQueueExitReason(Map<String, dynamic> row) {
    final result = row['verification_result']?.toString();
    if (result == 'APPROVED' || result == 'REJECTED') {
      return 'This observation has already been verified by another expert.';
    }
    if (row['is_deleted'] == true) {
      return 'The user has deleted this observation.';
    }
    if (row['is_public'] != true) {
      return 'The user has made this observation private.';
    }
    return 'The user has withdrawn this observation from the verification queue.';
  }

  Future<void> _fetchProvince() async {
    final coords = _parseCoordinates(widget.obs['coordinates']);
    final double? lat = widget.obs['latitude'] != null ? double.tryParse(widget.obs['latitude'].toString()) : coords?['lat'];
    final double? lng = widget.obs['longitude'] != null ? double.tryParse(widget.obs['longitude'].toString()) : coords?['lng'];

    if (lat == null || lng == null) {
      if (mounted) {
        setState(() {
          _province = 'Unknown';
          _isLoadingProvince = false;
        });
      }
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

  void _showToast(String message, {bool isError = true}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    
    final screenWidth = MediaQuery.of(context).size.width;
    final leftMargin = screenWidth > 400 ? screenWidth - 360.0 : 16.0;

    ScaffoldMessenger.of(context).showSnackBar(
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
                message,
                style: const TextStyle(fontWeight: FontWeight.w500, color: Colors.white),
              ),
            ),
            const SizedBox(width: 8.0),
            IconButton(
              icon: const Icon(Icons.close_rounded, color: Colors.white70, size: 18),
              onPressed: () {
                ScaffoldMessenger.of(context).hideCurrentSnackBar();
              },
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              splashRadius: 16.0,
            ),
          ],
        ),
        backgroundColor: isError ? Colors.red[800] : Colors.green[800],
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10.0),
        ),
        margin: EdgeInsets.only(
          bottom: 24,
          right: 16,
          left: leftMargin,
        ),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  bool _canManageObservationPrivacy({
    required bool isOwner,
    required String? verificationResult,
  }) {
    if (!isOwner) return false;
    if (verificationResult?.toString().toUpperCase() == 'REJECTED') return false;
    return true;
  }

  Future<bool> _showObservationConfirmation({
    required String title,
    required String message,
    required String confirmLabel,
    bool isDestructive = false,
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
              style: isDestructive ? FilledButton.styleFrom(backgroundColor: Colors.red) : null,
              child: Text(confirmLabel),
            ),
          ],
        );
      },
    );
    return result ?? false;
  }

  Future<void> _updatePrivacySettings(bool newPublic, bool newAnon) async {
    final obs = widget.obs;
    final underVerification = obs['under_verification'] == true;
    final id = obs['observation_id'] ?? obs['id'];
    final isOwner = obs['user_id'] == Supabase.instance.client.auth.currentUser?.id;

    if (!_canManageObservationPrivacy(
      isOwner: isOwner,
      verificationResult: obs['verification_result']?.toString(),
    )) {
      _showToast('Rejected observations cannot change their visibility settings.');
      setState(() {
        _isPublic = false;
        _isAnonymous = obs['is_anonymous'] == true;
      });
      return;
    }

    final wasPublic = obs['is_public'] == true;
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
        setState(() {
          _isPublic = obs['is_public'] == true;
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
          obs['is_public'] = newPublic;
          obs['is_anonymous'] = newAnon;
          if (updates.containsKey('under_verification')) {
            obs['under_verification'] = false;
            obs['verification_result'] = null;
          }
        });
        _wasModified = true;
      }
    } catch (e) {
      _showToast('Failed to update privacy settings: $e');
      if (mounted) {
        setState(() {
          _isPublic = obs['is_public'] == true;
          _isAnonymous = obs['is_anonymous'] == true;
        });
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _handleRequestVerification() async {
    final obs = widget.obs;
    if (obs['under_verification'] == true || obs['verification_result'] == 'APPROVED' || obs['verification_result'] == 'REJECTED') {
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
      final id = obs['observation_id'] ?? obs['id'];
      await Supabase.instance.client
          .from('observations')
          .update({
            'is_public': true,
            'under_verification': true,
            'verification_result': 'PENDING',
          })
          .eq('observation_id', id);

      if (mounted) {
        _showToast('Verification requested successfully.', isError: false);
        setState(() {
          obs['is_public'] = true;
          _isPublic = true;
          obs['under_verification'] = true;
          obs['verification_result'] = 'PENDING';
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
    final obs = widget.obs;
    if (obs['under_verification'] != true) {
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
      final id = obs['observation_id'] ?? obs['id'];
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
          obs['under_verification'] = false;
          obs['verification_result'] = null;
        });
        _wasModified = true;
      }
    } catch (e) {
      _showToast('Failed to cancel request: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _handleDelete() async {
    final confirmed = await _showObservationConfirmation(
      title: 'Delete this observation?',
      message: 'This action cannot be undone.',
      confirmLabel: 'Delete',
      isDestructive: true,
    );
    if (!confirmed) return;
    if (!mounted) return;

    setState(() => _isLoading = true);
    try {
      final id = widget.obs['observation_id'] ?? widget.obs['id'];
      await Supabase.instance.client
          .from('observations')
          .update({'is_deleted': true, 'deleted_at': DateTime.now().toUtc().toIso8601String()})
          .eq('observation_id', id);
      if (mounted) {
        _showToast('Observation deleted successfully.', isError: false);
        Navigator.pop(context, true);
      }
    } catch (e) {
      _showToast('Failed to delete: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _submitVerification() async {
    if (!(_verificationFormKey.currentState?.validate() ?? false)) {
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.orange),
            SizedBox(width: 8),
            Text('Confirm Verification'),
          ],
        ),
        content: const Text(
          'This verification decision is absolute and irreversible. Do you wish to proceed?',
          style: TextStyle(fontSize: 16),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red[700]),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() {
      _isSubmitting = true;
    });

    bool success = false;
    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      final observationId = widget.obs['observation_id'] ?? widget.obs['id'];
      
      final Map<String, dynamic> updatePayload = {
        'verifier_id': user.id,
        'verification_timestamp': DateTime.now().toUtc().toIso8601String(),
        'verification_result': _selectedResult,
        'under_verification': false,
        'remarks': _remarksController.text.trim(),
      };
      if (_selectedResult == 'REJECTED') {
        updatePayload['is_public'] = false;
      }
      
      final updateResponse = await Supabase.instance.client
          .from('observations')
          .update(updatePayload)
          .eq('observation_id', observationId)
          .eq('under_verification', true)
          .eq('is_public', true)
          .select();

      if (updateResponse.isEmpty) {
        String reason = 'The user likely cancelled the request or set the observation to private.';
        try {
          final current = await Supabase.instance.client
              .from('observations')
              .select('verification_result, is_public, is_deleted')
              .eq('observation_id', observationId)
              .maybeSingle();
          if (current != null) reason = _describeQueueExitReason(current);
        } catch (_) {}
        _showToast('Action failed: $reason', isError: true);
        success = true; // Still counts as navigating away successfully
        if (mounted) {
           Navigator.pop(context, true); // Remove from list
        }
        return;
      }

      _showToast('Observation verified successfully.', isError: false);
      success = true;
      if (mounted) {
        Navigator.pop(context, true); // Go back to the list and signal success
      }
    } catch (e) {
      _showToast('Failed to verify: $e');
    } finally {
      if (mounted && !success) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  @override
  void dispose() {
    if (_subscription != null) {
      Supabase.instance.client.removeChannel(_subscription!);
    }
    _remarksController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final obs = widget.obs;
    final imageUrl = obs['image_url']?.toString();
    final coords = _parseCoordinates(obs['coordinates']);
    final double? lat = obs['latitude'] != null ? double.tryParse(obs['latitude'].toString()) : coords?['lat'];
    final double? lng = obs['longitude'] != null ? double.tryParse(obs['longitude'].toString()) : coords?['lng'];
    final latStr = lat != null ? lat.toStringAsFixed(6) : 'N/A';
    final lngStr = lng != null ? lng.toStringAsFixed(6) : 'N/A';
    final isVerified = obs['verification_result'] == 'APPROVED' || obs['verification_result'] == 'REJECTED';
    final isPendingVerification = obs['under_verification'] == true;
    
    final isOwner = obs['user_id'] == Supabase.instance.client.auth.currentUser?.id;

    final rawTimestamp = obs['observation_timestamp'] ?? obs['upload_timestamp'];
    final rawDate = rawTimestamp != null ? DateTime.tryParse(rawTimestamp.toString()) : null;
    final dateStr = rawDate != null ? DateFormat.yMMMd().add_jm().format(rawDate.toLocal()) : 'N/A';
    final rawUploadStr = obs['upload_timestamp'];
    final rawUpload = rawUploadStr != null ? DateTime.tryParse(rawUploadStr.toString()) : null;
    final uploadStr = rawUpload != null ? DateFormat.yMMMd().add_jm().format(rawUpload.toLocal()) : 'Not Uploaded Yet';
    final rawVerificationResult = obs['verification_result']?.toString() ?? 'NONE';
    final verificationResult = rawVerificationResult == 'APPROVED' ? 'Verified' : (rawVerificationResult == 'REJECTED' ? 'Rejected' : rawVerificationResult);
    final verifierName = obs['verifier'] != null && obs['verifier'] is Map 
        ? (obs['verifier'] as Map)['user_name']?.toString() ?? 'Unknown'
        : 'Unknown';
    final rawVerificationStr = obs['verification_timestamp'];
    final rawVerification = rawVerificationStr != null ? DateTime.tryParse(rawVerificationStr.toString()) : null;
    final verificationStr = rawVerification != null ? DateFormat.yMMMd().add_jm().format(rawVerification.toLocal()) : 'Unknown Date';
    Color verifyColor = isVerified ? (rawVerificationResult == 'APPROVED' ? Colors.blue : Colors.red) : Colors.orange;
    final canManagePrivacy = _canManageObservationPrivacy(
      isOwner: isOwner,
      verificationResult: rawVerificationResult,
    );

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        Navigator.pop(context, _wasModified ? true : null);
      },
      child: Scaffold(
      backgroundColor: Colors.grey[50],
      appBar: AppBar(
        title: widget.isVerifyMode
            ? const Text('Verify Observation', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black87))
            : null,
        backgroundColor: Colors.white,
        elevation: 1,
        iconTheme: const IconThemeData(color: Colors.black87),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context, _wasModified ? true : null),
        ),
      ),
      body: Stack(
        children: [
        Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1000),
          child: ListView(
            padding: const EdgeInsets.all(24.0),
            children: [
              // Status Banner
              if (isVerified)
                Container(
                  padding: const EdgeInsets.all(12),
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: Colors.blue[50],
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.blue[200]!),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.verified, color: Colors.blue),
                      SizedBox(width: 8),
                      Text('This observation has been verified.', style: TextStyle(color: Colors.blue, fontWeight: FontWeight.bold)),
                    ],
                  ),
                )
              else if (obs['verification_result'] == 'REJECTED')
                Container(
                  padding: const EdgeInsets.all(12),
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: Colors.red[50],
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.red[200]!),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.cancel, color: Colors.red),
                      SizedBox(width: 8),
                      Text('This observation verification was rejected.', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),

              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Left Side: Image
                  Expanded(
                    flex: 4,
                    child: Card(
                      elevation: 2,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: imageUrl != null && imageUrl.isNotEmpty
                            ? MouseRegion(
                                cursor: SystemMouseCursors.click,
                                child: GestureDetector(
                                  onTap: () => FullScreenImageViewer.show(context, imageUrl),
                                  child: Image.network(
                                    imageUrl,
                                    fit: BoxFit.cover,
                                    errorBuilder: (context, error, stackTrace) => Container(
                                      height: 300,
                                      color: Colors.grey[200],
                                      child: const Center(child: Icon(Icons.broken_image, color: Colors.grey, size: 64)),
                                    ),
                                  ),
                                ),
                              )
                            : Container(
                                height: 300,
                                color: Colors.grey[200],
                                child: const Center(child: Icon(Icons.park_outlined, color: Colors.grey, size: 64)),
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 24),
                  
                  // Right Side: Details & Verification
                  Expanded(
                    flex: 5,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Metadata Card
                        Card(
                          elevation: 2,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          child: Padding(
                            padding: const EdgeInsets.all(20.0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('Observation Details', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                                const Divider(height: 24),
                                if (widget.isVerifyMode) ...[
                                  _buildDetailRow(Icons.person_outline, 'Owner', obs['users'] != null && obs['users'] is Map
                                      ? (obs['users'] as Map)['user_name']?.toString() ?? 'Unknown'
                                      : 'Unknown'),
                                  const SizedBox(height: 12),
                                ],
                                _buildDetailRow(Icons.calendar_today, 'Observation Timestamp', dateStr),
                                const SizedBox(height: 12),
                                _buildDetailRow(Icons.cloud_upload, 'Upload Timestamp', uploadStr),
                                const SizedBox(height: 12),
                                _buildDetailRow(Icons.location_on, 'Location', _isLoadingProvince ? 'Loading...' : _province ?? 'Unknown'),
                                if (widget.currentUserRole == 'EXPERT' && !widget.isVerifyMode) ...[
                                  const SizedBox(height: 12),
                                  _buildDetailRow(Icons.devices_outlined, 'Source', obs['source']?.toString().toUpperCase() ?? 'UNKNOWN'),
                                ],
                                if (isOwner) ...[
                                  const SizedBox(height: 12),
                                  _buildDetailRow(Icons.explore, 'Coordinates (Lat/Lng)', '$latStr, $lngStr'),
                                ],
                                if ((isOwner || widget.isVerifyMode) && obs['remarks'] != null && obs['remarks'].toString().isNotEmpty) ...[
                                  const SizedBox(height: 12),
                                  _buildDetailRow(Icons.notes, 'Current Remarks', obs['remarks']),
                                ],
                              ],
                            ),
                          ),
                        ),

                        const SizedBox(height: 24),

                        if (canManagePrivacy && !widget.isVerifyMode) ...[
                          Card(
                            elevation: 2,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                            child: Padding(
                              padding: const EdgeInsets.all(20.0),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text('Privacy Settings', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                                  const Divider(height: 24),
                                  CheckboxListTile(
                                    controlAffinity: ListTileControlAffinity.trailing,
                                    contentPadding: EdgeInsets.zero,
                                    title: const Text('Public Observation', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                                    subtitle: const Text('Allow others to view this', style: TextStyle(fontSize: 12)),
                                    value: _isPublic,
                                    activeColor: Colors.green[700],
                                    onChanged: (val) {
                                      final newVal = val ?? false;
                                      setState(() => _isPublic = newVal);
                                      _updatePrivacySettings(newVal, _isAnonymous);
                                    },
                                  ),
                                  const Divider(height: 1),
                                  CheckboxListTile(
                                    controlAffinity: ListTileControlAffinity.trailing,
                                    contentPadding: EdgeInsets.zero,
                                    title: const Text('Submit Anonymously', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                                    subtitle: const Text('Hide your username', style: TextStyle(fontSize: 12)),
                                    value: _isAnonymous,
                                    activeColor: Colors.green[700],
                                    onChanged: (val) {
                                      final newVal = val ?? false;
                                      setState(() => _isAnonymous = newVal);
                                      _updatePrivacySettings(_isPublic, newVal);
                                    },
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 24),
                        ],

                        if (widget.showViewOnMapButton && rawVerificationResult != 'REJECTED') ...[
                          OutlinedButton.icon(
                            onPressed: () {
                              final onViewOnMap = widget.onViewOnMap;
                              if (onViewOnMap != null) {
                                // Pop back to the dashboard shell so the sidebar
                                // stays visible, then switch to the Map tab.
                                Navigator.of(context).popUntil((route) => route.isFirst);
                                onViewOnMap(obs);
                              } else {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (context) => MapPage(highlightObservation: obs),
                                  ),
                                );
                              }
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

                        if (isVerified) ...[
                          Card(
                            elevation: 2,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                            child: Padding(
                              padding: const EdgeInsets.all(20.0),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Icon(Icons.gavel, color: verifyColor),
                                      const SizedBox(width: 8),
                                      const Text('Expert Verification', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                                    ],
                                  ),
                                  const Divider(height: 24),
                                  _buildDetailRow(Icons.gavel, 'Result', verificationResult),
                                  const SizedBox(height: 12),
                                  _buildDetailRow(Icons.person, 'Verified By', verifierName),
                                  const SizedBox(height: 12),
                                  _buildDetailRow(Icons.access_time, 'Verification Timestamp', verificationStr),
                                  if (obs['remarks'] != null && obs['remarks'].toString().isNotEmpty) ...[
                                    const SizedBox(height: 12),
                                    _buildDetailRow(Icons.notes, 'Expert Remarks', obs['remarks']),
                                  ],
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 24),
                        ],

                        // Verification Panel (Only if Verify Mode AND Pending)
                        if (widget.isVerifyMode && isPendingVerification)
                          Card(
                            elevation: 4,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                              side: BorderSide(color: Colors.green[600]!, width: 2),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(20.0),
                              child: Form(
                                key: _verificationFormKey,
                                child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Row(
                                    children: [
                                      Icon(Icons.gavel, color: Colors.green[700]),
                                      const SizedBox(width: 8),
                                      const Text('Expert Verification', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                                    ],
                                  ),
                                  const Divider(height: 24),
                                  const Text('Result', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                                  const SizedBox(height: 8),
                                  DropdownButtonFormField<String>(
                                    decoration: InputDecoration(
                                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                    ),
                                    hint: const Text('Select Result'),
                                    initialValue: _selectedResult,
                                    items: const [
                                      DropdownMenuItem(value: 'APPROVED', child: Text('Approve', style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold))),
                                      DropdownMenuItem(value: 'REJECTED', child: Text('Reject', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold))),
                                    ],
                                    onChanged: (val) {
                                      setState(() {
                                        _selectedResult = val;
                                      });
                                    },
                                    validator: (val) => val == null ? 'Please select a verification result.' : null,
                                  ),
                                  const SizedBox(height: 16),
                                  const Text('Remarks (Optional)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                                  const SizedBox(height: 8),
                                  TextField(
                                    controller: _remarksController,
                                    maxLines: 3,
                                    decoration: InputDecoration(
                                      hintText: 'Enter your expert remarks...',
                                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                                    ),
                                  ),
                                  const SizedBox(height: 24),
                                  FilledButton.icon(
                                    onPressed: _isSubmitting ? null : _submitVerification,
                                    icon: _isSubmitting ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)) : const Icon(Icons.send),
                                    label: const Text('Submit Verification', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                                    style: FilledButton.styleFrom(
                                      backgroundColor: Colors.green[700],
                                      padding: const EdgeInsets.symmetric(vertical: 16),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                    ),
                                  ),
                                ],
                                ),
                              ),
                            ),
                          ),

                        if (!isVerified && !isPendingVerification && isOwner) ...[
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

                        if (isPendingVerification && isOwner && !widget.isVerifyMode) ...[
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

                        if (isOwner && !widget.isVerifyMode) ...[
                          const SizedBox(height: 4),
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
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
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

  Widget _buildDetailRow(IconData icon, String label, String value, {Widget? trailing}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: Colors.grey[600]),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: TextStyle(fontSize: 12, color: Colors.grey[600], fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Row(
                children: [
                  Text(value, style: const TextStyle(fontSize: 14, color: Colors.black87)),
                  if (trailing != null) ...[
                    const SizedBox(width: 6),
                    trailing,
                  ],
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
