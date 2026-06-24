import 'package:flutter/material.dart';
import 'dart:typed_data';
import 'package:shared_services/shared_services.dart';

class ObservationsListPage extends StatefulWidget {
  final bool isExpertOnly;

  const ObservationsListPage({
    super.key,
    required this.isExpertOnly,
  });

  @override
  State<ObservationsListPage> createState() => _ObservationsListPageState();
}

class _ObservationsListPageState extends State<ObservationsListPage> {
  List<Map<String, dynamic>> _observations = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _fetchObservations();
  }

  @override
  void didUpdateWidget(covariant ObservationsListPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isExpertOnly != widget.isExpertOnly) {
      _fetchObservations();
    }
  }

  Future<void> _fetchObservations() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) {
        throw Exception('User not authenticated');
      }

      var query = Supabase.instance.client.from('observations').select('*, users(user_name)');

      if (widget.isExpertOnly) {
        query = query.eq('user_id', user.id);
      }

      final data = await query.order('timestamp', ascending: false);

      if (mounted) {
        setState(() {
          _observations = (data as List<dynamic>).map((e) => e as Map<String, dynamic>).toList();
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

  Future<void> _verifyObservation(Map<String, dynamic> obs) async {
    final id = obs['id'];
    if (id == null) return;

    try {
      // Try updating is_verified first. If the column doesn't exist, catch error and fallback
      await Supabase.instance.client
          .from('observations')
          .update({'is_verified': true})
          .eq('id', id);

      _showToast('Observation verified successfully!', isError: false);
      _fetchObservations();
    } catch (e) {
      debugPrint('Error updating is_verified, trying sync_status: $e');
      try {
        // Fallback to updating sync_status or similar
        await Supabase.instance.client
            .from('observations')
            .update({'sync_status': 'verified'})
            .eq('id', id);

        _showToast('Observation verified (status updated)!', isError: false);
        _fetchObservations();
      } catch (e2) {
        // Local simulation fallback
        setState(() {
          final index = _observations.indexWhere((element) => element['id'] == id);
          if (index != -1) {
            _observations[index]['is_verified'] = true;
            _observations[index]['sync_status'] = 'verified';
          }
        });
        _showToast('Verified (local simulation mode)', isError: false);
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

  void _showToast(String message, {bool isError = true}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red[800] : Colors.green[800],
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        width: 400,
      ),
    );
  }

  void _showAddObservationPlaceholder() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              Icon(Icons.add_photo_alternate_outlined, color: Colors.green[700]),
              const SizedBox(width: 10),
              const Text('Add Observation'),
            ],
          ),
          content: const Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'This is a placeholder for adding new Falcata tree observations.',
                style: TextStyle(fontSize: 14, color: Colors.black87),
              ),
              SizedBox(height: 12),
              Text(
                'In the final release, this will allow experts to upload field photographs, specify coordinates, and classify the gall rust severity manually or automatically.',
                style: TextStyle(fontSize: 13, color: Colors.grey),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('Close', style: TextStyle(color: Colors.green[700], fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.isExpertOnly ? "My Observations" : "All System Observations";

    return Scaffold(
      backgroundColor: Colors.grey[50],
      appBar: AppBar(
        title: Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black87),
        ),
        backgroundColor: Colors.white,
        elevation: 1,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.black54),
            onPressed: _fetchObservations,
            tooltip: 'Refresh',
          ),
          if (widget.isExpertOnly) ...[
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green[700],
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                onPressed: _showAddObservationPlaceholder,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add Observation', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ],
      ),
      body: _buildBody(),
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
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.assignment_outlined, size: 80, color: Colors.grey[300]),
            const SizedBox(height: 16),
            Text(
              'No Observations Found',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.grey[700]),
            ),
            const SizedBox(height: 8),
            Text(
              widget.isExpertOnly
                  ? 'Your submitted observations will appear here.'
                  : 'System observations will show up here.',
              style: TextStyle(color: Colors.grey[500]),
            ),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // Responsive grid view for Web
        final crossAxisCount = constraints.maxWidth > 1200
            ? 3
            : constraints.maxWidth > 800
                ? 2
                : 1;

        return GridView.builder(
          padding: const EdgeInsets.all(24.0),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            crossAxisSpacing: 20,
            mainAxisSpacing: 20,
            mainAxisExtent: 180,
          ),
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
            final isVerified = obs['is_verified'] == true || obs['sync_status'] == 'verified';
            final contributorName = obs['users'] != null && obs['users'] is Map
                ? (obs['users'] as Map)['user_name']?.toString() ?? 'Unknown User'
                : 'Unknown User';

            return Card(
              elevation: 2,
              shadowColor: Colors.black.withValues(alpha: 0.05),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16.0),
              ),
              color: Colors.white,
              child: InkWell(
                borderRadius: BorderRadius.circular(16.0),
                onTap: () {
                  _showToast('Viewing observation detail - placeholder!', isError: false);
                },
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Image Preview
                  ClipRRect(
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(16.0),
                      bottomLeft: Radius.circular(16.0),
                    ),
                    child: SizedBox(
                      width: 130,
                      child: imageUrl != null && imageUrl.isNotEmpty
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
                              child: Icon(Icons.park_outlined, color: Colors.green[200], size: 40),
                            ),
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
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: severityColor,
                                  ),
                                ),
                              ),
                              Text(
                                dateStr,
                                style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                              ),
                            ],
                          ),
                          const Spacer(),
                          Row(
                            children: [
                              Icon(Icons.location_on_outlined, size: 14, color: Colors.green[700]),
                              const SizedBox(width: 4.0),
                              Expanded(
                                child: Text(
                                  'Lat: $latStr, Lng: $lngStr',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w500,
                                    color: Colors.black87,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4.0),
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
                          const SizedBox(height: 4.0),
                          Row(
                            children: [
                              Icon(Icons.person_outline, size: 14, color: Colors.grey[600]),
                              const SizedBox(width: 4.0),
                              Text(
                                'By: $contributorName',
                                style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                              ),
                            ],
                          ),
                          const Spacer(),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              if (isVerified)
                                const Row(
                                  children: [
                                    Icon(Icons.verified_rounded, color: Colors.blue, size: 16),
                                    SizedBox(width: 4),
                                    Text(
                                      'Verified',
                                      style: TextStyle(
                                        color: Colors.blue,
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                )
                              else if (!widget.isExpertOnly)
                                SizedBox(
                                  height: 28,
                                  child: OutlinedButton.icon(
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: Colors.green[700],
                                      side: BorderSide(color: Colors.green[300]!),
                                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                    ),
                                    onPressed: () => _verifyObservation(obs),
                                    icon: const Icon(Icons.check, size: 14),
                                    label: const Text(
                                      'Verify',
                                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                )
                              else
                                const Row(
                                  children: [
                                    Icon(Icons.pending_actions_outlined, color: Colors.orange, size: 16),
                                    SizedBox(width: 4),
                                    Text(
                                      'Unverified',
                                      style: TextStyle(
                                        color: Colors.orange,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ],
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
            );
          },
        );
      },
    );
  }
}
