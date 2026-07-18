// ignore_for_file: avoid_dynamic_calls
import 'package:flutter/material.dart';
import 'package:shared_services/shared_services.dart';
import 'package:intl/intl.dart';
import 'dart:typed_data';
import '../../../observations/presentation/widgets/full_screen_image_viewer.dart';
import '../../../observations/presentation/pages/observation_details_page.dart';
class ObservationDetailsPanel extends StatefulWidget {
  final Map<String, dynamic> obs;
  final VoidCallback onClose;
  final VoidCallback onModified;
  final String? currentUserRole;

  const ObservationDetailsPanel({
    super.key,
    required this.obs,
    required this.onClose,
    required this.onModified,
    this.currentUserRole,
  });

  @override
  State<ObservationDetailsPanel> createState() => _ObservationDetailsPanelState();
}

class _ObservationDetailsPanelState extends State<ObservationDetailsPanel> {
  String? _province;
  bool _isLoadingProvince = true;

  @override
  void initState() {
    super.initState();
    _fetchProvince();
  }

  @override
  void didUpdateWidget(ObservationDetailsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.obs['observation_id'] != widget.obs['observation_id']) {
      setState(() {
        _province = null;
        _isLoadingProvince = true;
      });
      _fetchProvince();
    }
  }

  Future<void> _fetchProvince() async {
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

  Map<String, double>? _parseCoordinates(dynamic coords) {
    if (coords == null) return null;
    if (coords is Map) {
      final map = coords.cast<String, dynamic>();
      final list = map['coordinates'];
      if (list is List && list.length >= 2) return {'lat': (list[1] as num).toDouble(), 'lng': (list[0] as num).toDouble()};
    } else if (coords is String) {
      // WKT format: POINT(lng lat)
      if (coords.toUpperCase().startsWith('POINT(')) {
        final inner = coords.substring(6, coords.length - 1).split(' ');
        if (inner.length >= 2) {
          final lng = double.tryParse(inner[0]);
          final lat = double.tryParse(inner[1]);
          if (lat != null && lng != null) return {'lat': lat, 'lng': lng};
        }
      }
      // EWKB hex format from PostGIS (e.g. "0101000020E6100000...")
      if (coords.length >= 42 && RegExp(r'^[0-9a-fA-F]+$').hasMatch(coords)) {
        try {
          return _parseEWKBHex(coords);
        } catch (e) {
          debugPrint('[Province] EWKB parse error: $e');
        }
      }
    }
    return null;
  }

  Map<String, double>? _parseEWKBHex(String hex) {
    final bytes = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < hex.length; i += 2) {
      bytes[i ~/ 2] = int.parse(hex.substring(i, i + 2), radix: 16);
    }
    final byteData = ByteData.view(bytes.buffer);
    final byteOrder = bytes[0]; // 0x01 = little-endian
    final endian = byteOrder == 1 ? Endian.little : Endian.big;
    final geomType = byteData.getUint32(1, endian);
    final hasSRID = (geomType & 0x20000000) != 0;
    final coordOffset = hasSRID ? 9 : 5;
    // PostGIS stores X=longitude first, then Y=latitude
    final lng = byteData.getFloat64(coordOffset, endian);
    final lat = byteData.getFloat64(coordOffset + 8, endian);
    return {'lat': lat, 'lng': lng};
  }

  @override
  Widget build(BuildContext context) {
    final isOwner = Supabase.instance.client.auth.currentUser?.id == widget.obs['user_id'];
    final coords = _parseCoordinates(widget.obs['coordinates']);
    final double? lat = widget.obs['latitude'] != null ? double.tryParse(widget.obs['latitude'].toString()) : coords?['lat'];
    final double? lng = widget.obs['longitude'] != null ? double.tryParse(widget.obs['longitude'].toString()) : coords?['lng'];
    final latStr = lat != null ? lat.toStringAsFixed(6) : 'N/A';
    final lngStr = lng != null ? lng.toStringAsFixed(6) : 'N/A';

    final rawTimestamp = widget.obs['observation_timestamp'];
    final rawDate = rawTimestamp != null ? DateTime.tryParse(rawTimestamp.toString()) : null;
    final dateStr = rawDate != null ? DateFormat.yMMMd().add_jm().format(rawDate.toLocal()) : 'Unknown Date';
    
    final rawUploadStr = widget.obs['upload_timestamp'];
    final rawUpload = rawUploadStr != null ? DateTime.tryParse(rawUploadStr.toString()) : null;
    final uploadStr = rawUpload != null ? DateFormat.yMMMd().add_jm().format(rawUpload.toLocal()) : 'Not Uploaded Yet';
    final isPublic = widget.obs['is_public'] == true;
    final isVerified = widget.obs['verification_result'] == 'APPROVED' || widget.obs['verification_result'] == 'REJECTED';
    final verificationResult = widget.obs['verification_result']?.toString() ?? 'NONE';
    final underVerification = widget.obs['under_verification'] == true;
    
    final imageUrl = widget.obs['image_url']?.toString();

    String verifyStatusText = 'Unverified';
    Color verifyColor = Colors.orange;
    
    if (isVerified) {
      if (verificationResult == 'APPROVED') {
        verifyStatusText = 'Verified';
        verifyColor = Colors.blue;
      } else if (verificationResult == 'REJECTED') {
        verifyStatusText = 'Rejected';
        verifyColor = Colors.red;
      } else {
        verifyStatusText = 'Verified';
        verifyColor = Colors.blue;
      }
    } else if (underVerification) {
      verifyStatusText = 'Pending Verification';
      verifyColor = Colors.purple;
    }
    
    final isAnonymous = widget.obs['is_anonymous'] == true;
    final ownerRole = widget.obs['users'] != null && widget.obs['users'] is Map
        ? (widget.obs['users'] as Map)['role']?.toString().toUpperCase()
        : null;
    final isExpert = ownerRole == 'EXPERT';
    final contributorName = (isPublic && isAnonymous && !isOwner)
        ? 'Anonymous User'
        : (widget.obs['users'] != null && widget.obs['users'] is Map
            ? (widget.obs['users'] as Map)['user_name']?.toString() ?? 'Unknown User'
            : 'Unknown User');

    final verifierName = widget.obs['verifier'] != null && widget.obs['verifier'] is Map 
        ? (widget.obs['verifier'] as Map)['user_name']?.toString() ?? 'Unknown'
        : 'Unknown';
    final rawVerificationStr = widget.obs['verification_timestamp'];
    final rawVerification = rawVerificationStr != null ? DateTime.tryParse(rawVerificationStr.toString()) : null;
    final verificationStr = rawVerification != null ? DateFormat.yMMMd().add_jm().format(rawVerification.toLocal()) : 'Unknown Date';

    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        width: 400,
        margin: const EdgeInsets.only(left: 16, top: 16, bottom: 16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.15),
              blurRadius: 15,
              offset: const Offset(0, 4),
            )
          ],
        ),
        child: Column(
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                children: [
                  Icon(Icons.person_pin_circle, color: Colors.blue[700]),
                  const SizedBox(width: 8),
                  const Text('Observation Details', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: widget.onClose,
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            // Body
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16.0),
                children: [
                  if (imageUrl != null && imageUrl.isNotEmpty) ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          onTap: () => FullScreenImageViewer.show(context, imageUrl),
                          child: Image.network(
                            imageUrl,
                            height: 250,
                            width: double.infinity,
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) => Container(
                              height: 250,
                              color: Colors.grey[100],
                              child: const Center(child: Icon(Icons.broken_image, size: 64, color: Colors.grey)),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ] else ...[
                    Container(
                      height: 250,
                      decoration: BoxDecoration(
                        color: Colors.grey[100],
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Center(child: Icon(Icons.park, size: 64, color: Colors.grey)),
                    ),
                    const SizedBox(height: 16),
                  ],
                  
                  _buildMetaRow(
                    Icons.person,
                    'Observer',
                    contributorName,
                    trailing: (isAnonymous && isOwner) || (isExpert && (!isAnonymous || isOwner))
                        ? Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (isAnonymous && isOwner) ...[
                                Icon(Icons.visibility_off_rounded, size: 14, color: Colors.purple[700]),
                                if (isExpert) const SizedBox(width: 4),
                              ],
                              if (isExpert && (!isAnonymous || isOwner))
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                  decoration: BoxDecoration(color: Colors.blue.shade100, borderRadius: BorderRadius.circular(4)),
                                  child: Text('EXPERT', style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.blue.shade900)),
                                ),
                            ],
                          )
                        : null,
                  ),
                  _buildMetaRow(Icons.calendar_today, 'Observation Timestamp', dateStr),
                  if (widget.currentUserRole == 'EXPERT' && isExpert && (widget.obs['is_anonymous'] != true || isOwner))
                    _buildMetaRow(Icons.devices_outlined, 'Source', widget.obs['source']?.toString().toUpperCase() ?? 'UNKNOWN'),
                  _buildMetaRow(Icons.map, 'Province', _isLoadingProvince ? 'Loading...' : (_province ?? 'Unknown')),
                  if (isOwner)
                    _buildMetaRow(Icons.location_on, 'Coordinates (Lat/Lng)', '$latStr, $lngStr'),
                  _buildMetaRow(Icons.cloud_upload, 'Upload Timestamp', uploadStr),
                  _buildMetaRow(
                    isVerified ? Icons.verified : (underVerification ? Icons.pending_actions : Icons.new_releases), 
                    'Status', 
                    verifyStatusText,
                    color: verifyColor
                  ),
                  if (isVerified) ...[
                    _buildMetaRow(Icons.person_outline, 'Verified By', verifierName),
                    _buildMetaRow(Icons.access_time, 'Verification Timestamp', verificationStr),
                  ],
                  
                  if (isVerified && widget.obs['remarks'] != null && widget.obs['remarks'].toString().isNotEmpty)
                    Container(
                      margin: const EdgeInsets.only(top: 16),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(color: Colors.grey[100], borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.grey[300]!)),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Remarks', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black87)),
                          const SizedBox(height: 4),
                          Text(widget.obs['remarks'].toString(), style: const TextStyle(color: Colors.black87)),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            if (isOwner || underVerification) ...[
              const Divider(height: 1),
              // Actions
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    if (isOwner) ...[
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () {
                            widget.onClose();
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) => ObservationDetailsPage(
                                  obs: widget.obs,
                                  isVerifyMode: false,
                                  showViewOnMapButton: false,
                                  currentUserRole: widget.currentUserRole,
                                ),
                              ),
                            ).then((_) => widget.onModified());
                          },
                          icon: const Icon(Icons.info_outline),
                          label: const Text('View Details'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.green[700],
                            side: BorderSide(color: Colors.green[700]!),
                            padding: const EdgeInsets.symmetric(vertical: 16),
                          ),
                        ),
                      ),
                    ],
                    if (isOwner && underVerification) const SizedBox(height: 12),
                    if (underVerification) ...[
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: () {
                            widget.onClose();
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) => ObservationDetailsPage(
                                  obs: widget.obs,
                                  isVerifyMode: true,
                                  showViewOnMapButton: false,
                                  currentUserRole: widget.currentUserRole,
                                ),
                              ),
                            ).then((_) => widget.onModified());
                          },
                          icon: const Icon(Icons.fact_check_outlined),
                          label: const Text('Verify Observation'),
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.purple[700],
                            padding: const EdgeInsets.symmetric(vertical: 16),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildMetaRow(IconData icon, String label, String value, {Color? color, Widget? trailing}) {
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
                Row(
                  children: [
                    Text(value, style: TextStyle(fontSize: 14, color: color ?? Colors.black87)),
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
      ),
    );
  }
}
