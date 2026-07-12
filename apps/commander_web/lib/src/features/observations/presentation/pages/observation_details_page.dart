// ignore_for_file: avoid_dynamic_calls
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/services.dart';
import 'dart:convert';
import 'package:latlong2/latlong.dart';
import 'dart:typed_data';
import 'package:intl/intl.dart';
import 'dart:typed_data';

class ObservationDetailsPage extends StatefulWidget {
  final Map<String, dynamic> obs;
  final bool isVerifyMode;

  const ObservationDetailsPage({
    super.key,
    required this.obs,
    required this.isVerifyMode,
  });

  @override
  State<ObservationDetailsPage> createState() => _ObservationDetailsPageState();
}

class _ObservationDetailsPageState extends State<ObservationDetailsPage> {
  String? _selectedResult;
  final TextEditingController _remarksController = TextEditingController();
  bool _isSubmitting = false;
  
  String? _province;
  bool _isLoadingProvince = true;

  RealtimeChannel? _subscription;

  @override
  void initState() {
    super.initState();
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
              if (newRow['under_verification'] != true || newRow['is_public'] != true || newRow['is_deleted'] == true) {
                _showToast('The user has dequeued, deleted, or made this observation private.', isError: true);
                Navigator.pop(context, true); // Pop out and signal the list to refresh
              } else {
                setState(() {
                  widget.obs['is_anonymous'] = newRow['is_anonymous'];
                });
              }
            }
          },
        )
        .subscribe();
  }

  Future<void> _fetchProvince() async {
    final coords = _parseCoordinates(widget.obs['coordinates']);
    if (coords == null) {
      if (mounted) {
        setState(() {
          _province = 'Unknown';
          _isLoadingProvince = false;
        });
      }
      return;
    }

    try {
      final String geoJsonString = await rootBundle.loadString('assets/philippines.json');
      final data = json.decode(geoJsonString);
      final features = data['features'] as List;

      final point = LatLng(coords['lat']!, coords['lng']!);

      for (var feature in features) {
        final props = feature['properties'];
        final geometry = feature['geometry'];
        if (geometry == null) continue;
        final type = geometry['type'];
        final coordsList = geometry['coordinates'] as List;

        if (type == 'Polygon') {
          final ring = coordsList[0] as List;
          final points = ring.map((c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble())).toList();
          if (_isPointInPolygon(point, points)) {
            if (props != null && props['adm2_name'] != null && props['adm2_name'] != 'Special Geographic Area') {
              if (mounted) {
                setState(() {
                  _province = props['adm2_name'];
                  _isLoadingProvince = false;
                });
              }
              return;
            }
          }
        } else if (type == 'MultiPolygon') {
          for (var poly in coordsList) {
            final ring = poly[0] as List;
            final points = ring.map((c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble())).toList();
            if (_isPointInPolygon(point, points)) {
              if (props != null && props['adm2_name'] != null && props['adm2_name'] != 'Special Geographic Area') {
                if (mounted) {
                  setState(() {
                    _province = props['adm2_name'];
                    _isLoadingProvince = false;
                  });
                }
                return;
              }
            }
          }
        }
      }
      if (mounted) {
        setState(() {
          _province = 'Unknown';
          _isLoadingProvince = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _province = 'Unknown';
          _isLoadingProvince = false;
        });
      }
    }
  }

  bool _isPointInPolygon(LatLng point, List<LatLng> polygon) {
    int intersectCount = 0;
    for (int j = 0; j < polygon.length - 1; j++) {
      if (_rayCastIntersect(point, polygon[j], polygon[j + 1])) {
        intersectCount++;
      }
    }
    return (intersectCount % 2) == 1;
  }

  bool _rayCastIntersect(LatLng point, LatLng vertA, LatLng vertB) {
    double aY = vertA.latitude;
    double bY = vertB.latitude;
    double aX = vertA.longitude;
    double bX = vertB.longitude;
    double pY = point.latitude;
    double pX = point.longitude;

    if ((aY > pY && bY > pY) || (aY < pY && bY < pY) || (aX < pX && bX < pX)) {
      return false;
    }

    double m = (aY - bY) / (aX - bX);
    double bee = (-aX) * m + aY;
    double x = (pY - bee) / m;

    return x > pX;
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

  Future<void> _submitVerification() async {
    if (_selectedResult == null) {
      _showToast('Please select a verification result.');
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
        _showToast('Action failed: The user likely cancelled the request or set the observation to private.', isError: true);
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
    final latStr = coords != null ? coords['lat']!.toStringAsFixed(6) : 'N/A';
    final lngStr = coords != null ? coords['lng']!.toStringAsFixed(6) : 'N/A';
    final isVerified = obs['verification_result'] == 'APPROVED' || obs['verification_result'] == 'REJECTED';
    final isPendingVerification = obs['under_verification'] == true;
    
    final isPublic = obs['is_public'] == true;
    final isAnonymous = obs['is_anonymous'] == true;
    final contributorName = (isPublic && isAnonymous)
        ? 'Anonymous Scout'
        : (obs['users'] != null && obs['users'] is Map
            ? (obs['users'] as Map)['user_name']?.toString() ?? 'Unknown User'
            : 'Unknown User');
        
    final rawTimestamp = obs['observation_timestamp'] ?? obs['upload_timestamp'];
    final rawDate = rawTimestamp != null ? DateTime.tryParse(rawTimestamp.toString()) : null;
    final dateStr = rawDate != null ? DateFormat.yMMMd().add_jm().format(rawDate.toLocal()) : 'N/A';
    final confidenceScore = obs['confidence_score'] != null ? '${obs['confidence_score']}%' : 'N/A';
    final isOwner = obs['user_id'] == Supabase.instance.client.auth.currentUser?.id;
    final rawVerificationResult = obs['verification_result']?.toString() ?? 'NONE';
    final verificationResult = rawVerificationResult == 'APPROVED' ? 'Verified' : (rawVerificationResult == 'REJECTED' ? 'Rejected' : rawVerificationResult);
    final verifierName = obs['verifier'] != null && obs['verifier'] is Map 
        ? (obs['verifier'] as Map)['user_name']?.toString() ?? 'Unknown'
        : 'Unknown';
    final rawVerificationStr = obs['verification_timestamp'];
    final rawVerification = rawVerificationStr != null ? DateTime.tryParse(rawVerificationStr.toString()) : null;
    final verificationStr = rawVerification != null ? DateFormat.yMMMd().add_jm().format(rawVerification.toLocal()) : 'Unknown Date';
    Color verifyColor = isVerified ? (rawVerificationResult == 'APPROVED' ? Colors.blue : Colors.red) : Colors.orange;

    return Scaffold(
      backgroundColor: Colors.grey[50],
      appBar: AppBar(
        title: const Text('Observation Details', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black87)),
        backgroundColor: Colors.white,
        elevation: 1,
        iconTheme: const IconThemeData(color: Colors.black87),
      ),
      body: Center(
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
                            ? Image.network(
                                imageUrl,
                                fit: BoxFit.cover,
                                errorBuilder: (context, error, stackTrace) => Container(
                                  height: 300,
                                  color: Colors.grey[200],
                                  child: const Center(child: Icon(Icons.broken_image, color: Colors.grey, size: 64)),
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
                                const Text('Metadata', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                                const Divider(height: 24),
                                _buildDetailRow(Icons.person, 'Observer', contributorName),
                                const SizedBox(height: 12),
                                _buildDetailRow(Icons.calendar_today, 'Observation Timestamp', dateStr),
                                if (isOwner) ...[
                                  const SizedBox(height: 12),
                                  _buildDetailRow(Icons.location_on, 'Coordinates', 'Lat: $latStr, Lng: $lngStr'),
                                ],
                                const SizedBox(height: 12),
                                _buildDetailRow(Icons.map, 'Province', _isLoadingProvince ? 'Loading...' : _province ?? 'Unknown'),
                                const SizedBox(height: 12),
                                _buildDetailRow(Icons.analytics, 'Confidence Score', confidenceScore),
                                if (obs['remarks'] != null && obs['remarks'].toString().isNotEmpty) ...[
                                  const SizedBox(height: 12),
                                  _buildDetailRow(Icons.notes, 'Current Remarks', obs['remarks']),
                                ],
                              ],
                            ),
                          ),
                        ),

                        const SizedBox(height: 24),

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
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDetailRow(IconData icon, String label, String value) {
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
              Text(value, style: const TextStyle(fontSize: 14, color: Colors.black87)),
            ],
          ),
        ),
      ],
    );
  }
}
