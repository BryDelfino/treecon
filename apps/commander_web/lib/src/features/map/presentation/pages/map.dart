import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_marker_cluster/flutter_map_marker_cluster.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

class MapPage extends StatefulWidget {
  const MapPage({super.key});

  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> {
  final _hitNotifier = ValueNotifier<LayerHitResult<Object>?>(null);
  final _mapController = MapController();

  List<Polygon> _caPolygons = [];
  List<Polygon> _krigingPolygons = [];
  bool _isCaLoading = false;
  bool _isKrigingLoading = false;

  // Simulation layers state
  bool _showCA = false;
  bool _showKriging = false;
  int _caSteps = 5;
  double _caOpacity = 0.6;
  double _krigingOpacity = 0.6;
  bool _isCAExpanded = false;
  bool _isKrigingExpanded = false;
  bool _isPlantationExpanded = false;
  
  // Observations state
  bool _showVerifiedObservations = true;
  bool _showUnverifiedObservations = true;
  bool _isObservationsExpanded = true;
  bool _isObservationsLoading = false;
  List<Map<String, dynamic>> _observationsData = [];
  Map<String, dynamic>? _selectedObservation;
  String _selectedObservationProvince = 'All';
  
  // Plantations state
  bool _showPlantations = false;
  bool _isPlantationsLoading = false;
  List<Map<String, dynamic>> _plantationsData = [];
  Map<String, dynamic>? _selectedPlantation;
  String _selectedPlantationProvince = 'All';
  String _selectedPlantationSeverity = 'All';

  final List<String> _availableSeverities = [
    'All',
    'Healthy',
    'Low',
    'Moderate',
    'High',
    'Severe'
  ];

  Map<String, dynamic>? _selectedRegionProps;
  LatLng? _selectedRegionLocation;

  String _getSeverityClass(double value) {
    if (value < 10.0) return "Healthy";
    if (value < 25.0) return "Low";
    if (value < 50.0) return "Moderate";
    if (value < 75.0) return "High";
    return "Severe";
  }

  bool _isPointInPolygon(LatLng point, List<LatLng> polygon) {
    bool isInside = false;
    for (int i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
      if (((polygon[i].latitude > point.latitude) != (polygon[j].latitude > point.latitude)) &&
          (point.longitude < (polygon[j].longitude - polygon[i].longitude) * (point.latitude - polygon[i].latitude) / (polygon[j].latitude - polygon[i].latitude) + polygon[i].longitude)) {
        isInside = !isInside;
      }
    }
    return isInside;
  }

  double? _getCAForecastForPoint(LatLng point) {
    if (!_showCA || _caPolygons.isEmpty) return null;
    for (var poly in _caPolygons) {
      if (_isPointInPolygon(point, poly.points)) {
        final props = poly.hitValue as Map<String, dynamic>?;
        if (props != null) {
          return double.tryParse(props['severity_value']?.toString() ?? '');
        }
      }
    }
    return null;
  }

  List<String> get _availableProvinces {
    final Set<String> provinces = {'All'};
    for (var poly in _caPolygons) {
      final props = poly.hitValue as Map<String, dynamic>?;
      if (props != null) {
        final name = props['adm2_name'] as String?;
        if (name != null) provinces.add(name);
      }
    }
    final list = provinces.toList();
    list.sort((a, b) => a == 'All' ? -1 : (b == 'All' ? 1 : a.compareTo(b)));
    return list;
  }

  String _getProvinceForObservation(LatLng point) {
    for (var poly in _caPolygons) {
      if (_isPointInPolygon(point, poly.points)) {
        final props = poly.hitValue as Map<String, dynamic>?;
        if (props != null && props['adm2_name'] != null) {
          return props['adm2_name'];
        }
      }
    }
    return 'Unknown';
  }

  Map<String, double>? _parseCoordinates(dynamic coords) {
    if (coords == null) return null;
    if (coords is Map) {
      // GeoJSON format: {"type": "Point", "coordinates": [lng, lat]}
      final map = coords.cast<String, dynamic>();
      final list = map['coordinates'];
      if (list is List && list.length >= 2) {
        return {'lat': (list[1] as num).toDouble(), 'lng': (list[0] as num).toDouble()};
      }
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
          debugPrint('[OBS] EWKB parse error: $e');
        }
      }
    }
    return null;
  }

  /// Decodes a PostGIS EWKB (Extended Well-Known Binary) hex string into lat/lng.
  /// Format: [byteOrder(1)] [geomType(4)] [srid(4)?] [x/lng(8)] [y/lat(8)]
  Map<String, double>? _parseEWKBHex(String hex) {
    final bytes = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < hex.length; i += 2) {
      bytes[i ~/ 2] = int.parse(hex.substring(i, i + 2), radix: 16);
    }
    final byteData = ByteData.view(bytes.buffer);

    final byteOrder = bytes[0]; // 0x01 = little-endian, 0x00 = big-endian
    final endian = byteOrder == 1 ? Endian.little : Endian.big;

    final geomType = byteData.getUint32(1, endian);
    final hasSRID = (geomType & 0x20000000) != 0;

    // Coordinates start after the SRID (if present)
    final coordOffset = hasSRID ? 9 : 5;

    // PostGIS stores X=longitude first, then Y=latitude
    final lng = byteData.getFloat64(coordOffset, endian);
    final lat = byteData.getFloat64(coordOffset + 8, endian);

    return {'lat': lat, 'lng': lng};
  }

  bool _isObservationInProvince(Map<String, dynamic> obs, String province) {
    if (province == 'All') return true;
    final coords = _parseCoordinates(obs['coordinates']);
    final lat = coords?['lat'] ?? 0.0;
    final lng = coords?['lng'] ?? 0.0;
    final point = LatLng(lat, lng);
    
    for (var poly in _caPolygons) {
      final props = poly.hitValue as Map<String, dynamic>?;
      if (props != null && props['adm2_name'] == province) {
        if (_isPointInPolygon(point, poly.points)) {
          return true;
        }
      }
    }
    return false;
  }

  List<Polygon> _applyOpacity(List<Polygon> source, double targetOpacity) {
    return source.map((p) => Polygon(
      points: p.points,
      // ignore: deprecated_member_use
      color: (p.color ?? Colors.transparent).withValues(alpha: targetOpacity),
      borderColor: Colors.black26,
      borderStrokeWidth: 0.5,
      hitValue: p.hitValue,
    )).toList();
  }

  List<Polygon> _getHighlightedPolygons() {
    if (_selectedRegionProps == null) return [];
    final selectedName = _selectedRegionProps!['adm2_name'] ?? _selectedRegionProps!['adm3_name'];
    if (selectedName == null) return [];

    final List<Polygon> activePolygons = _showCA ? _caPolygons : (_showKriging ? _krigingPolygons : []);
    if (activePolygons.isEmpty) return [];

    final List<Polygon> highlights = [];
    for (var p in activePolygons) {
      final props = p.hitValue as Map<String, dynamic>?;
      if (props != null) {
        final name = props['adm2_name'] ?? props['adm3_name'];
        if (name == selectedName) {
          highlights.add(Polygon(
            points: p.points,
            color: Colors.transparent,
            borderColor: Colors.yellowAccent,
            borderStrokeWidth: 4.0,
          ));
        }
      }
    }
    return highlights;
  }

  Widget _buildLegend() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text("Severity Legend", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.black87)),
        const SizedBox(height: 6),
        Row(
          children: [
            _legendItem(Colors.green.shade700, "Healthy"),
            _legendItem(Colors.yellow.shade700, "Low"),
            _legendItem(Colors.orange, "Moderate"),
            _legendItem(Colors.red, "High"),
            _legendItem(const Color(0xFF800000), "Severe"),
          ],
        ),
      ],
    );
  }

  Widget _legendItem(Color color, String label) {
    return Expanded(
      child: Column(
        children: [
          Container(height: 8, color: color),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(fontSize: 9), textAlign: TextAlign.center),
        ],
      ),
    );
  }

  LatLng _getCentroid(List<LatLng> points) {
    if (points.isEmpty) return const LatLng(0, 0);
    double latSum = 0;
    double lngSum = 0;
    for (var p in points) {
      latSum += p.latitude;
      lngSum += p.longitude;
    }
    return LatLng(latSum / points.length, lngSum / points.length);
  }



  @override
  void initState() {
    super.initState();
    _fetchForecast(_caSteps);
    _fetchKriging();
    _fetchPlantations();
    _fetchObservations();
  }

  Future<void> _fetchObservations() async {
    debugPrint('[OBS] _fetchObservations() called');
    setState(() => _isObservationsLoading = true);
    try {
      final user = Supabase.instance.client.auth.currentUser;
      debugPrint('[OBS] Current user: ${user?.id ?? "NOT LOGGED IN"}');

      final response = await Supabase.instance.client
          .from('observations')
          .select()
          .order('observation_timestamp', ascending: false);

      debugPrint('[OBS] Raw response type: ${response.runtimeType}');
      debugPrint('[OBS] Rows fetched: ${response.length}');

      if (response.isNotEmpty) {
        final first = response.first as Map<String, dynamic>;
        debugPrint('[OBS] First row keys: ${first.keys.toList()}');
        debugPrint('[OBS] First row coordinates: ${first['coordinates']}');
        debugPrint('[OBS] First row coordinates type: ${first['coordinates'].runtimeType}');

        final parsed = _parseCoordinates(first['coordinates']);
        debugPrint('[OBS] Parsed coordinates: $parsed');
      }

      setState(() {
        _observationsData = List<Map<String, dynamic>>.from(response);
      });
      debugPrint('[OBS] _observationsData length after setState: ${_observationsData.length}');
    } catch (e, stackTrace) {
      debugPrint('[OBS] ERROR fetching observations: $e');
      debugPrint('[OBS] Stack trace: $stackTrace');
    } finally {
      setState(() => _isObservationsLoading = false);
    }
  }

  Widget _buildInfoWindow(Map<String, dynamic> properties) {
    final name = properties['adm2_name'] ?? properties['adm3_name'] ?? 'Unknown Region';
    
    // Find matching properties in Kriging and CA datasets
    Map<String, dynamic>? krigingProps;
    Map<String, dynamic>? caProps;

    for (var p in _krigingPolygons) {
      final props = p.hitValue as Map<String, dynamic>?;
      if (props != null && (props['adm2_name'] == name || props['adm3_name'] == name)) {
        krigingProps = props;
        break;
      }
    }

    for (var p in _caPolygons) {
      final props = p.hitValue as Map<String, dynamic>?;
      if (props != null && (props['adm2_name'] == name || props['adm3_name'] == name)) {
        caProps = props;
        break;
      }
    }

    final krigingSeverity = krigingProps?['severity_value']?.toString() ?? 'N/A';
    final caSeverity = caProps?['severity_value']?.toString() ?? 'N/A';
    
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Card(
          elevation: 6,
          color: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.all(12.0),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                Row(
                  children: [
                    const Icon(Icons.location_on, color: Colors.green, size: 16),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14), overflow: TextOverflow.ellipsis),
                    ),
                    GestureDetector(
                      onTap: () => setState(() {
                        _selectedRegionProps = null;
                        _selectedRegionLocation = null;
                      }),
                      child: const Icon(Icons.close, size: 16, color: Colors.grey),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (_showKriging) ...[
                  const Text("Kriging Interpolation", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.grey)),
                  if (krigingSeverity != 'N/A')
                    Text('Severity: $krigingSeverity% (${_getSeverityClass(double.tryParse(krigingSeverity) ?? 0)})', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13))
                  else
                    const Text('No data available.', style: TextStyle(fontSize: 12)),
                  if (_showCA) const SizedBox(height: 8),
                ],
                if (_showCA) ...[
                  const Text("CA Spread Forecast", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.grey)),
                  if (caSeverity != 'N/A') ...[
                    Text('Before (Current): ${krigingSeverity == 'N/A' ? 'N/A' : '$krigingSeverity% (${_getSeverityClass(double.tryParse(krigingSeverity) ?? 0)})'}', style: const TextStyle(fontSize: 12)),
                    Text('After (Step $_caSteps): $caSeverity% (${_getSeverityClass(double.tryParse(caSeverity) ?? 0)})', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: Colors.deepOrange)),
                  ] else
                    const Text('No data available.', style: TextStyle(fontSize: 12)),
                ],
              ],
              ),
            ),
          ),
        ),
      ],
    );
  }


  // Parses a hex color string (e.g. "#A1D99B") into a Flutter Color
  Color _parseHexColor(String hex) {
    final buffer = StringBuffer();
    if (hex.length == 6 || hex.length == 7) buffer.write('ff');
    buffer.write(hex.replaceFirst('#', ''));
    return Color(int.parse(buffer.toString(), radix: 16));
  }

  // Fetches Plantation Points from Python server
  Future<void> _fetchPlantations() async {
    setState(() {
      _isPlantationsLoading = true;
    });
    try {
      final response = await http.get(
        Uri.parse('http://127.0.0.1:8000/api/plantations'),
      );
      if (response.statusCode == 200) {
        final List<dynamic> data = json.decode(response.body);
        setState(() {
          _plantationsData = data.cast<Map<String, dynamic>>();
        });
      } else {
        debugPrint("API Error: ${response.statusCode}");
      }
    } catch (e) {
      debugPrint("Connection error: $e");
    } finally {
      setState(() {
        _isPlantationsLoading = false;
      });
    }
  }

  List<Marker> _buildPlantationMarkers() {
    final filtered = _plantationsData.where((p) {
      final lat = double.tryParse(p['latitude'].toString()) ?? 0.0;
      final lng = double.tryParse(p['longitude'].toString()) ?? 0.0;
      
      final groundTruthSeverity = double.tryParse(p['severity_index_pct'].toString()) ?? 0.0;
      final forecastedSeverity = _getCAForecastForPoint(LatLng(lat, lng));
      final severity = forecastedSeverity ?? groundTruthSeverity;
      
      if (_selectedPlantationSeverity != 'All' && _getSeverityClass(severity) != _selectedPlantationSeverity) return false;
      if (_selectedPlantationProvince != 'All' && _getProvinceForObservation(LatLng(lat, lng)) != _selectedPlantationProvince) return false;
      return true;
    }).toList();

    return filtered.map((p) {
      final lat = double.tryParse(p['latitude'].toString()) ?? 0.0;
      final lng = double.tryParse(p['longitude'].toString()) ?? 0.0;
      
      final groundTruthSeverity = double.tryParse(p['severity_index_pct'].toString()) ?? 0.0;
      final forecastedSeverity = _getCAForecastForPoint(LatLng(lat, lng));
      final severity = forecastedSeverity ?? groundTruthSeverity;
      
      Color color = Colors.green;
      if (severity < 10.0) {
        color = const Color(0xFF4CAF50);
      } else if (severity < 25.0) {
        color = const Color(0xFFFFEB3B);
      } else if (severity < 50.0) {
        color = const Color(0xFFFF9800);
      } else if (severity < 75.0) {
        color = const Color(0xFFF44336);
      } else {
        color = const Color(0xFF800000);
      }

      return Marker(
        point: LatLng(lat, lng),
        width: 20,
        height: 20,
        child: GestureDetector(
          onTap: () {
            setState(() {
              _selectedPlantation = p;
            });
          },
          child: Container(
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
              boxShadow: const [
                BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 2))
              ],
            ),
          ),
        ),
      );
    }).toList();
  }

  Widget _buildPlantationInfoWindow(Map<String, dynamic> p) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Card(
          elevation: 6,
          color: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.all(12.0),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text("Plantation Record", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                    GestureDetector(
                      onTap: () => setState(() => _selectedPlantation = null),
                      child: const Icon(Icons.close, size: 16, color: Colors.grey),
                    ),
                  ],
                ),
                const Divider(),
                Text("Record ID: ${p['record_id']}", style: const TextStyle(fontSize: 12)),
                Text("Plantation ID: ${p['plantation_id']}", style: const TextStyle(fontSize: 12)),
                Text("Plot Number: ${p['plot_number']}", style: const TextStyle(fontSize: 12)),
                Text("Region: ${p['region']}", style: const TextStyle(fontSize: 12)),
                Text("Lat/Lng: ${p['latitude']}, ${p['longitude']}", style: const TextStyle(fontSize: 12)),
                const SizedBox(height: 8),
                if (_showCA) ...[
                  const Text("Ground Truth", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.grey)),
                  Text("Before (Current): ${p['severity_index_pct']}% (${_getSeverityClass(double.tryParse(p['severity_index_pct'].toString()) ?? 0.0)})", style: const TextStyle(fontSize: 12)),
                  const SizedBox(height: 4),
                  const Text("CA Spread Forecast", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.grey)),
                  Builder(builder: (context) {
                    final lat = double.tryParse(p['latitude'].toString()) ?? 0.0;
                    final lng = double.tryParse(p['longitude'].toString()) ?? 0.0;
                    final forecasted = _getCAForecastForPoint(LatLng(lat, lng));
                    if (forecasted != null) {
                      return Text('After (Step $_caSteps): $forecasted% (${_getSeverityClass(forecasted)})', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: Colors.deepOrange));
                    }
                    return const Text("No forecast available for this point.", style: TextStyle(fontSize: 12, color: Colors.grey));
                  }),
                ] else ...[
                  Text("Severity: ${p['severity_index_pct']}% (${_getSeverityClass(double.tryParse(p['severity_index_pct'].toString()) ?? 0.0)})", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.deepOrange)),
                ],
              ],
            ),
            ),
          ),
        ),
      ],
    );
  }

  List<Marker> _buildObservationMarkers() {
    final filtered = _observationsData.where((obs) {
      // Skip deleted observations
      if (obs['is_deleted'] == true) return false;
      final isVerified = obs['is_verified'] == true || obs['sync_status'] == 'verified';
      if (isVerified && !_showVerifiedObservations) return false;
      if (!isVerified && !_showUnverifiedObservations) return false;
      return _isObservationInProvince(obs, _selectedObservationProvince);
    }).toList();
    debugPrint('[OBS] _buildObservationMarkers: ${filtered.length} markers after filtering');

    return filtered.map((obs) {
      final coords = _parseCoordinates(obs['coordinates']);
      final lat = coords?['lat'] ?? 0.0;
      final lng = coords?['lng'] ?? 0.0;
      final confidence = double.tryParse(obs['confidence_score']?.toString() ?? '') ?? 0.0;
      final isVerified = obs['is_verified'] == true || obs['sync_status'] == 'verified';
      
      // Color based on confidence score (higher = more certain = use green spectrum)
      Color color;
      if (confidence >= 80.0) {
        color = const Color(0xFFF44336); // High confidence of disease
      } else if (confidence >= 60.0) {
        color = const Color(0xFFFF9800);
      } else if (confidence >= 40.0) {
        color = const Color(0xFFFFEB3B);
      } else {
        color = const Color(0xFF4CAF50); // Low confidence
      }

      return Marker(
        point: LatLng(lat, lng),
        width: 24,
        height: 24,
        child: GestureDetector(
          onTap: () {
            setState(() {
              _selectedObservation = obs;
            });
          },
          child: Container(
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.rectangle,
              borderRadius: isVerified ? BorderRadius.circular(6) : null,
              border: Border.all(color: Colors.white, width: 2),
            ),
            child: isVerified 
              ? const Icon(Icons.star, size: 14, color: Colors.white)
              : const Icon(Icons.warning_amber_rounded, size: 14, color: Colors.white),
          ),
        ),
      );
    }).toList();
  }

  Widget _buildObservationInfoWindow(Map<String, dynamic> obs) {
    final coords = _parseCoordinates(obs['coordinates']);
    final lat = coords?['lat'] ?? 0.0;
    final lng = coords?['lng'] ?? 0.0;
    final province = _getProvinceForObservation(LatLng(lat, lng));
    final isVerified = obs['is_verified'] == true || obs['sync_status'] == 'verified';
    final date = obs['observation_timestamp'] != null 
        ? DateTime.tryParse(obs['observation_timestamp'])?.toLocal().toString().split('.')[0] ?? 'Unknown Date'
        : 'Unknown Date';
    final imageUrl = obs['image_url']?.toString();

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Card(
          elevation: 6,
          color: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.all(12.0),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text("Field Observation", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                      GestureDetector(
                        onTap: () => setState(() => _selectedObservation = null),
                        child: const Icon(Icons.close, size: 16, color: Colors.grey),
                      ),
                    ],
                  ),
                  const Divider(),
                  if (imageUrl != null && imageUrl.isNotEmpty) ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.network(imageUrl, height: 120, width: double.infinity, fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) => const SizedBox(height: 120, child: Center(child: Icon(Icons.broken_image, color: Colors.grey))),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  Row(
                    children: [
                      Icon(isVerified ? Icons.verified : Icons.pending, size: 16, color: isVerified ? Colors.blue : Colors.orange),
                      const SizedBox(width: 4),
                      Text(isVerified ? "Verified" : "Unverified", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: isVerified ? Colors.blue : Colors.orange)),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text("Observation ID: ${obs['observation_id'] ?? 'Unknown'}", style: const TextStyle(fontSize: 12)),
                  Text("Date: $date", style: const TextStyle(fontSize: 12)),
                  Text("Province: $province", style: const TextStyle(fontSize: 12)),
                  Text("Lat/Lng: ${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}", style: const TextStyle(fontSize: 12)),
                  const SizedBox(height: 8),
                  const Text("Confidence Score", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.grey)),
                  Text("${obs['confidence_score'] ?? 'N/A'}%", style: const TextStyle(fontSize: 12)),
                  const SizedBox(height: 8),
                  const Text("Remarks", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.grey)),
                  Text(obs['remarks'] ?? 'No remarks provided.', style: const TextStyle(fontSize: 12)),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  // Fetches Kriging Contours from Python server
  Future<void> _fetchKriging() async {
    setState(() {
      _isKrigingLoading = true;
    });
    try {
      final response = await http.post(
        Uri.parse('http://127.0.0.1:8000/api/kriging'),
        headers: {'Content-Type': 'application/json'},
      );
      if (response.statusCode == 200) {
        final polygons = _parseGeoJSON(response.body);
        setState(() {
          _krigingPolygons = polygons;
        });
      } else {
        debugPrint("API Error: ${response.statusCode}");
      }
    } catch (e) {
      debugPrint("Connection error: $e");
    } finally {
      setState(() {
        _isKrigingLoading = false;
      });
    }
  }

  // Fetches Cellular Automata spread forecast from Python server
  Future<void> _fetchForecast(int steps) async {
    setState(() {
      _isCaLoading = true;
    });
    try {
      final response = await http.post(
        Uri.parse('http://127.0.0.1:8000/api/forecast'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'steps': steps,
          'grid_resolution': 0.12,
          'spread_factor': 0.08,
        }),
      );
      if (response.statusCode == 200) {
        final polygons = _parseGeoJSON(response.body);
        setState(() {
          _caPolygons = polygons;
        });
      } else {
        debugPrint("API Error: ${response.statusCode}");
      }
    } catch (e) {
      debugPrint("Connection error: $e");
    } finally {
      setState(() {
        _isCaLoading = false;
      });
    }
  }

  // Helper to parse features from spatial engine GeoJSON output
  List<Polygon> _parseGeoJSON(String jsonString) {
    try {
      final Map<String, dynamic> data = json.decode(jsonString);
      final List<Polygon> parsedList = [];
      
      final features = data['features'] as List<dynamic>?;
      if (features != null) {
        for (final feature in features) {
          final f = feature as Map<String, dynamic>;
          final geometry = f['geometry'] as Map<String, dynamic>?;
          final properties = f['properties'] as Map<String, dynamic>?;
          if (geometry == null || properties == null) continue;
          
          final String colorHex = properties['color'] as String? ?? "#74C476";
          final Color baseColor = _parseHexColor(colorHex);
          
          final type = geometry['type'] as String;
          if (type == 'Polygon') {
            final coordinates = geometry['coordinates'] as List<dynamic>;
            for (final ringData in coordinates) {
              final List<LatLng> points = [];
              for (final coord in ringData as List<dynamic>) {
                final c = coord as List<dynamic>;
                points.add(LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()));
              }
              if (points.isNotEmpty) {
                final Color opacityColor = baseColor;
                final props = Map<String, dynamic>.from(properties);
                props['centroid'] = _getCentroid(points);
                props['points'] = points;
                parsedList.add(Polygon(
                  points: points,
                  color: opacityColor,
                  borderColor: opacityColor,
                  borderStrokeWidth: 0.8,
                  hitValue: props,
                ));
              }
            }
          } else if (type == 'MultiPolygon') {
            final coordinates = geometry['coordinates'] as List<dynamic>;
            for (final polygonData in coordinates) {
              for (final ringData in polygonData as List<dynamic>) {
                final List<LatLng> points = [];
                for (final coord in ringData as List<dynamic>) {
                  final c = coord as List<dynamic>;
                  points.add(LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()));
                }
                if (points.isNotEmpty) {
                  final Color opacityColor = baseColor;
                  final props = Map<String, dynamic>.from(properties);
                  props['centroid'] = _getCentroid(points);
                  props['points'] = points;
                  parsedList.add(Polygon(
                    points: points,
                    color: opacityColor,
                    borderColor: Colors.transparent,
                    borderStrokeWidth: 0,
                    hitValue: props,
                  ));
                }
              }
            }
          }
        }
      }
      return parsedList;
    } catch (e) {
      debugPrint("Error parsing overlay GeoJSON: $e");
      return [];
    }
  }



  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          "Spatial Map",
          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black87),
        ),
        backgroundColor: Colors.white,
        elevation: 1,
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: const LatLng(12.8797, 121.7740),
              initialZoom: 6,
              minZoom: 6,
              onTap: (tapPosition, point) {
                final hitResult = _hitNotifier.value;
                if (hitResult != null && hitResult.hitValues.isNotEmpty) {
                  final props = hitResult.hitValues.first as Map<String, dynamic>;
                  setState(() {
                    _selectedRegionProps = props;
                    _selectedRegionLocation = props['centroid'] as LatLng?;
                  });
                } else {
                  setState(() {
                    _selectedRegionProps = null;
                    _selectedRegionLocation = null;
                  });
                }
              },
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Topo_Map/MapServer/tile/{z}/{y}/{x}',
                userAgentPackageName: 'com.treecon.commander',
              ),
              // 2. Dynamic simulation contour layers
              if (_showCA && _caPolygons.isNotEmpty)
                PolygonLayer(
                  polygons: _applyOpacity(_caPolygons, _caOpacity),
                  hitNotifier: _hitNotifier,
                ),
              if (_showKriging && _krigingPolygons.isNotEmpty)
                PolygonLayer(
                  polygons: _applyOpacity(_krigingPolygons, _krigingOpacity),
                  hitNotifier: _hitNotifier,
                ),
              
              // Highlight layer
              if (_selectedRegionProps != null)
                PolygonLayer(
                  polygons: _getHighlightedPolygons(),
                ),
              if (_selectedRegionLocation != null && _selectedRegionProps != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: _selectedRegionLocation!,
                      width: 250,
                      height: 200,
                      alignment: Alignment.topCenter,
                      child: _buildInfoWindow(_selectedRegionProps!),
                    )
                  ],
                ),
              
              // Plantations Layer
              if (_showPlantations && _plantationsData.isNotEmpty)
                MarkerClusterLayerWidget(
                  options: MarkerClusterLayerOptions(
                    maxClusterRadius: 45,
                    size: const Size(40, 40),
                    alignment: Alignment.center,
                    padding: const EdgeInsets.all(50),
                    maxZoom: 15,
                    markers: _buildPlantationMarkers(),
                    builder: (context, markers) {
                      return Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(20),
                          color: Colors.green.shade700,
                        ),
                        child: Center(
                          child: Text(
                            markers.length.toString(),
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              
              // Plantation Popup
              if (_selectedPlantation != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: LatLng(
                        double.tryParse(_selectedPlantation!['latitude'].toString()) ?? 0.0,
                        double.tryParse(_selectedPlantation!['longitude'].toString()) ?? 0.0,
                      ),
                      width: 250,
                      height: 250,
                      alignment: Alignment.topCenter,
                      child: _buildPlantationInfoWindow(_selectedPlantation!),
                    )
                  ],
                ),

              // Observations Layer
              if ((_showVerifiedObservations || _showUnverifiedObservations) && _observationsData.isNotEmpty)
                MarkerClusterLayerWidget(
                  options: MarkerClusterLayerOptions(
                    maxClusterRadius: 45,
                    size: const Size(40, 40),
                    alignment: Alignment.center,
                    padding: const EdgeInsets.all(50),
                    maxZoom: 15,
                    markers: _buildObservationMarkers(),
                    builder: (context, markers) {
                      return Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.rectangle,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.white, width: 2),
                          color: Colors.blue.shade700,
                        ),
                        child: Center(
                          child: Text(
                            markers.length.toString(),
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              
              // Observation Popup
              if (_selectedObservation != null)
                Builder(builder: (context) {
                  final obsCoords = _parseCoordinates(_selectedObservation!['coordinates']);
                  return MarkerLayer(
                    markers: [
                      Marker(
                        point: LatLng(
                          obsCoords?['lat'] ?? 0.0,
                          obsCoords?['lng'] ?? 0.0,
                        ),
                        width: 250,
                        height: 380,
                        alignment: Alignment.topCenter,
                        child: _buildObservationInfoWindow(_selectedObservation!),
                      )
                    ],
                  );
                }),
            ],
          ),
          
          // Floating Settings Controls
          Positioned(
            top: 16,
              right: 16,
              child: SizedBox(
                width: 320,
                child: Card(
                  elevation: 8,
                  // ignore: deprecated_member_use
                  shadowColor: Colors.black.withValues(alpha: 0.3),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.layers_outlined, color: Colors.green.shade700),
                            const SizedBox(width: 8),
                            const Text(
                              "Map Controls & Settings",
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                        const Divider(height: 20),

                        // Accordions
                        ExpansionTile(
                          title: const Text("CA Spread Forecast", style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                          leading: Icon(Icons.online_prediction, color: _showCA ? Colors.green.shade700 : Colors.grey),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Switch(
                                value: _showCA,
                                activeTrackColor: Colors.green.shade700,
                                onChanged: (val) {
                                  setState(() {
                                    _showCA = val;
                                    _selectedRegionProps = null;
                                    _selectedRegionLocation = null;
                                    _selectedPlantation = null;
                                    _selectedObservation = null;
                                  });
                                },
                              ),
                              Icon(
                                _isCAExpanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                                color: Colors.grey,
                              ),
                            ],
                          ),
                          onExpansionChanged: (expanded) {
                            setState(() {
                              _isCAExpanded = expanded;
                            });
                          },
                          childrenPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          children: [
                            // Opacity Slider
                            Row(
                              children: [
                                const Text("Opacity:", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                                Expanded(
                                  child: Slider(
                                    value: _caOpacity,
                                    min: 0.0,
                                    max: 1.0,
                                    activeColor: Colors.green.shade700,
                                    onChanged: (val) {
                                      setState(() {
                                        _caOpacity = val;
                                      });
                                    },
                                  ),
                                ),
                              ],
                            ),
                            // Forecast Step Slider
                            const SizedBox(height: 8),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text("Forecast Steps:", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                                Text("Step $_caSteps", style: TextStyle(color: Colors.green.shade700, fontWeight: FontWeight.bold, fontSize: 12)),
                              ],
                            ),
                            Slider(
                              value: _caSteps.toDouble(),
                              min: 1,
                              max: 15,
                              divisions: 14,
                              activeColor: Colors.green.shade700,
                              onChanged: (val) {
                                  setState(() {
                                    _caSteps = val.round();
                                    _selectedRegionProps = null;
                                    _selectedRegionLocation = null;
                                    _selectedPlantation = null;
                                    _selectedObservation = null;
                                  });
                                },
                                onChangeEnd: (val) {
                                  _fetchForecast(val.round());
                                },
                            ),
                            const SizedBox(height: 12),
                            _buildLegend(),
                          ],
                        ),
                        
                        ExpansionTile(
                          title: const Text("Kriging Interpolation", style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                          leading: Icon(Icons.grain, color: _showKriging ? Colors.green.shade700 : Colors.grey),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Switch(
                                value: _showKriging,
                                activeTrackColor: Colors.green.shade700,
                                onChanged: (val) {
                                  setState(() {
                                    _showKriging = val;
                                    _selectedRegionProps = null;
                                    _selectedRegionLocation = null;
                                    _selectedPlantation = null;
                                    _selectedObservation = null;
                                  });
                                },
                              ),
                              Icon(
                                _isKrigingExpanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                                color: Colors.grey,
                              ),
                            ],
                          ),
                          onExpansionChanged: (expanded) {
                            setState(() {
                              _isKrigingExpanded = expanded;
                            });
                          },
                          childrenPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          children: [
                            // Opacity Slider
                            Row(
                              children: [
                                const Text("Opacity:", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                                Expanded(
                                  child: Slider(
                                    value: _krigingOpacity,
                                    min: 0.0,
                                    max: 1.0,
                                    activeColor: Colors.green.shade700,
                                    onChanged: (val) {
                                      setState(() {
                                        _krigingOpacity = val;
                                      });
                                    },
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            _buildLegend(),
                          ],
                        ),
                        const Divider(height: 20),
                        
                        // Plantation Points Toggle
                        ExpansionTile(
                          title: const Text("Plantation Points", style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                          leading: Icon(Icons.location_on, color: _showPlantations ? Colors.green.shade700 : Colors.grey),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Switch(
                                value: _showPlantations,
                                activeTrackColor: Colors.green.shade700,
                                onChanged: (val) {
                                  setState(() {
                                    _showPlantations = val;
                                    _selectedPlantation = null;
                                  });
                                },
                              ),
                              Icon(
                                _isPlantationExpanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                                color: Colors.grey,
                              ),
                            ],
                          ),
                          onExpansionChanged: (expanded) {
                            setState(() {
                              _isPlantationExpanded = expanded;
                            });
                          },
                          childrenPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          children: [
                            const Align(
                              alignment: Alignment.centerLeft,
                              child: Text("Filter by Province:", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                            ),
                            const SizedBox(height: 4),
                            DropdownButton<String>(
                              isExpanded: true,
                              value: _selectedPlantationProvince,
                              items: _availableProvinces.map((prov) {
                                return DropdownMenuItem(
                                  value: prov,
                                  child: Text(prov, style: const TextStyle(fontSize: 12)),
                                );
                              }).toList(),
                                onChanged: (val) {
                                  if (val != null) {
                                    setState(() {
                                      _selectedPlantationProvince = val;
                                      _selectedPlantation = null;
                                    });
                                  }
                                },
                            ),
                            const SizedBox(height: 12),
                            const Align(
                              alignment: Alignment.centerLeft,
                              child: Text("Filter by Severity:", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                            ),
                            const SizedBox(height: 4),
                            DropdownButton<String>(
                              isExpanded: true,
                              value: _selectedPlantationSeverity,
                              items: _availableSeverities.map((sev) {
                                return DropdownMenuItem(
                                  value: sev,
                                  child: Text(sev, style: const TextStyle(fontSize: 12)),
                                );
                              }).toList(),
                                onChanged: (val) {
                                  if (val != null) {
                                    setState(() {
                                      _selectedPlantationSeverity = val;
                                      _selectedPlantation = null;
                                    });
                                  }
                                },
                            ),
                            const SizedBox(height: 12),
                            _buildLegend(),
                          ],
                        ),
                        const Divider(height: 20),
                        
                        // Field Observations Toggle
                        ExpansionTile(
                          title: const Text("Field Observations", style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                          leading: Icon(Icons.person_pin_circle, color: (_showVerifiedObservations || _showUnverifiedObservations) ? Colors.blue.shade700 : Colors.grey),
                          trailing: Icon(
                            _isObservationsExpanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                            color: Colors.grey,
                          ),
                          onExpansionChanged: (expanded) {
                            setState(() {
                              _isObservationsExpanded = expanded;
                            });
                          },
                          childrenPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          children: [
                            SwitchListTile(
                              title: const Text("Verified Observations", style: TextStyle(fontSize: 12)),
                              value: _showVerifiedObservations,
                              activeTrackColor: Colors.blue.shade700,
                              onChanged: (val) {
                                  setState(() {
                                    _showVerifiedObservations = val;
                                    _selectedObservation = null;
                                  });
                                },
                              contentPadding: EdgeInsets.zero,
                              dense: true,
                            ),
                            SwitchListTile(
                              title: const Text("Unverified Observations", style: TextStyle(fontSize: 12)),
                              value: _showUnverifiedObservations,
                              activeTrackColor: Colors.orange.shade700,
                              onChanged: (val) {
                                  setState(() {
                                    _showUnverifiedObservations = val;
                                    _selectedObservation = null;
                                  });
                                },
                              contentPadding: EdgeInsets.zero,
                              dense: true,
                            ),
                            const SizedBox(height: 8),
                            const Align(
                              alignment: Alignment.centerLeft,
                              child: Text("Filter by Province:", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                            ),
                            const SizedBox(height: 4),
                            DropdownButton<String>(
                              isExpanded: true,
                              value: _selectedObservationProvince,
                              items: _availableProvinces.map((prov) {
                                return DropdownMenuItem(
                                  value: prov,
                                  child: Text(prov, style: const TextStyle(fontSize: 12)),
                                );
                              }).toList(),
                                onChanged: (val) {
                                  if (val != null) {
                                    setState(() {
                                      _selectedObservationProvince = val;
                                      _selectedObservation = null;
                                    });
                                  }
                                },
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

          if (_isCaLoading || _isKrigingLoading || _isPlantationsLoading || _isObservationsLoading)
            Center(
              child: Card(
                elevation: 4,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(color: Colors.green),
                      const SizedBox(width: 16),
                      Text((_isCaLoading && _isKrigingLoading)
                          ? "Fetching simulation layers..."
                          : _isCaLoading
                              ? "Fetching CA forecast..."
                              : _isKrigingLoading
                                  ? "Fetching Kriging contours..."
                                  : _isPlantationsLoading 
                                      ? "Loading plantation points..."
                                      : "Loading observations..."),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}