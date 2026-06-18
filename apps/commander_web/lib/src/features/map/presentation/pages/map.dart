import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;

class MapPage extends StatefulWidget {
  const MapPage({super.key});

  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> {

  List<Polygon> _countryPolygons = [];
  List<Polygon> _idwPolygons = [];
  List<Polygon> _caPolygons = [];
  List<Polygon> _krigingPolygons = [];
  bool _isLoading = true;
  bool _isIdwLoading = false;
  bool _isCaLoading = false;
  bool _isKrigingLoading = false;

  // Customization state (fixed defaults)
  static const double _fillOpacity = 0.25;
  static const double _borderOpacity = 0.80;
  static const double _borderWidth = 2.0;
  static const Color _selectedColor = Colors.green;

  // Simulation layers state
  bool _showIDW = false;
  bool _showCA = false;
  bool _showKriging = false;
  int _caSteps = 5;

  @override
  void initState() {
    super.initState();
    _loadCountryBoundary();
    _fetchIDW();
    _fetchForecast(_caSteps);
    _fetchKriging();
  }

  // Loads the country boundary once and caches polygons
  Future<void> _loadCountryBoundary() async {
    try {
      final String jsonString = await rootBundle.loadString('assets/philippines.json');
      final Map<String, dynamic> geoJson = json.decode(jsonString);
      final List<Polygon> polygons = [];

      final List<dynamic> features = geoJson['features'] as List<dynamic>;
      for (final feature in features) {
        final Map<String, dynamic> geometry = feature['geometry'] as Map<String, dynamic>;
        final String geomType = geometry['type'] as String;

        if (geomType == 'MultiPolygon') {
          final List<dynamic> coordinates = geometry['coordinates'] as List<dynamic>;
          for (final polygonData in coordinates) {
            for (final ringData in polygonData as List<dynamic>) {
              final List<LatLng> points = [];
              for (final coord in ringData as List<dynamic>) {
                final double lng = (coord[0] as num).toDouble();
                final double lat = (coord[1] as num).toDouble();
                points.add(LatLng(lat, lng));
              }
              if (points.isNotEmpty) {
                polygons.add(Polygon(points: points, hitValue: feature['properties']));
              }
            }
          }
        } else if (geomType == 'Polygon') {
          final List<dynamic> coordinates = geometry['coordinates'] as List<dynamic>;
          for (final ringData in coordinates) {
            final List<LatLng> points = [];
            for (final coord in ringData as List<dynamic>) {
              final double lng = (coord[0] as num).toDouble();
              final double lat = (coord[1] as num).toDouble();
              points.add(LatLng(lat, lng));
            }
            if (points.isNotEmpty) {
              polygons.add(Polygon(points: points, hitValue: feature['properties']));
            }
          }
        }
      }
      setState(() {
        _countryPolygons = polygons;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Error loading country GeoJSON: $e');
      setState(() {
        _isLoading = false;
      });
    }
  }

  // Parses a hex color string (e.g. "#A1D99B") into a Flutter Color
  Color _parseHexColor(String hex) {
    final buffer = StringBuffer();
    if (hex.length == 6 || hex.length == 7) buffer.write('ff');
    buffer.write(hex.replaceFirst('#', ''));
    return Color(int.parse(buffer.toString(), radix: 16));
  }

  // Fetches IDW Contours from Python server
  Future<void> _fetchIDW() async {
    setState(() {
      _isIdwLoading = true;
    });
    try {
      final response = await http.post(
        Uri.parse('http://127.0.0.1:8000/api/idw'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'grid_resolution': 0.12,
          'power': 2.0,
        }),
      );
      if (response.statusCode == 200) {
        final polygons = _parseGeoJSON(response.body);
        setState(() {
          _idwPolygons = polygons;
        });
      } else {
        debugPrint("API Error: ${response.statusCode}");
      }
    } catch (e) {
      debugPrint("Connection error: $e");
    } finally {
      setState(() {
        _isIdwLoading = false;
      });
    }
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
                // ignore: deprecated_member_use
                final Color opacityColor = baseColor.withOpacity(_fillOpacity * 1.5 > 1.0 ? 1.0 : _fillOpacity * 1.5);
                parsedList.add(Polygon(
                  points: points,
                  color: opacityColor,
                  borderColor: opacityColor,
                  borderStrokeWidth: 0.8,
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
                  // ignore: deprecated_member_use
                  final Color opacityColor = baseColor.withOpacity(_fillOpacity * 1.5 > 1.0 ? 1.0 : _fillOpacity * 1.5);
                  parsedList.add(Polygon(
                    points: points,
                    color: opacityColor,
                    borderColor: Colors.transparent,
                    borderStrokeWidth: 0,
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

  Widget _buildLayerButton({
    required String title,
    required bool active,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        style: ElevatedButton.styleFrom(
          backgroundColor: active ? _selectedColor : Colors.white,
          foregroundColor: active ? Colors.white : Colors.black87,
          elevation: active ? 2 : 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(
              color: active ? Colors.transparent : Colors.grey.shade300,
            ),
          ),
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
        onPressed: onTap,
        icon: Icon(icon, size: 18),
        label: Text(
          title,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Treecon Commander - Spatial Map"),
        backgroundColor: Colors.green.shade700,
        foregroundColor: Colors.white,
        elevation: 2,
      ),
      body: Stack(
        children: [
          FlutterMap(
            options: const MapOptions(
              initialCenter: LatLng(12.8797, 121.7740),
              initialZoom: 6,
              minZoom: 6,
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Topo_Map/MapServer/tile/{z}/{y}/{x}',
                userAgentPackageName: 'com.treecon.commander',
              ),
              if (_countryPolygons.isNotEmpty)
                PolygonLayer(
                  polygons: _countryPolygons.map((poly) => Polygon(
                    points: poly.points,
                    color: Colors.transparent,
                    borderColor: _selectedColor.withValues(alpha: _borderOpacity),
                    borderStrokeWidth: _borderWidth,
                  )).toList(),
                ),
              
              // 2. Dynamic simulation contour layers
              if (_showIDW && _idwPolygons.isNotEmpty)
                PolygonLayer(
                  polygons: _idwPolygons,
                ),
              if (_showCA && _caPolygons.isNotEmpty)
                PolygonLayer(
                  polygons: _caPolygons,
                ),
              if (_showKriging && _krigingPolygons.isNotEmpty)
                PolygonLayer(
                  polygons: _krigingPolygons,
                ),
            ],
          ),
          
          // Floating Settings Controls
          if (!_isLoading)
            Positioned(
              top: 16,
              right: 16,
              child: SizedBox(
                width: 320,
                child: Card(
                  elevation: 8,
                  // ignore: deprecated_member_use
                  shadowColor: Colors.black.withOpacity(0.3),
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

                        // Layer Selection
                        const Text(
                          "Simulation Layers",
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Colors.grey,
                          ),
                        ),
                        const SizedBox(height: 8),
                        CheckboxListTile(
                          title: const Text(
                            "IDW Interpolation Contours",
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                          ),
                          secondary: Icon(Icons.waves, color: _showIDW ? Colors.green.shade700 : Colors.grey),
                          value: _showIDW,
                          activeColor: Colors.green.shade700,
                          onChanged: (bool? val) {
                            setState(() {
                              _showIDW = val ?? false;
                            });
                          },
                          controlAffinity: ListTileControlAffinity.leading,
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                        ),
                        CheckboxListTile(
                          title: const Text(
                            "CA Spread Forecast",
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                          ),
                          secondary: Icon(Icons.online_prediction, color: _showCA ? Colors.green.shade700 : Colors.grey),
                          value: _showCA,
                          activeColor: Colors.green.shade700,
                          onChanged: (bool? val) {
                            setState(() {
                              _showCA = val ?? false;
                            });
                          },
                          controlAffinity: ListTileControlAffinity.leading,
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                        ),
                        CheckboxListTile(
                          title: const Text(
                            "Kriging Interpolation Contours",
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                          ),
                          secondary: Icon(Icons.grain, color: _showKriging ? Colors.green.shade700 : Colors.grey),
                          value: _showKriging,
                          activeColor: Colors.green.shade700,
                          onChanged: (bool? val) {
                            setState(() {
                              _showKriging = val ?? false;
                            });
                          },
                          controlAffinity: ListTileControlAffinity.leading,
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            
          // Forecast Slider Panel
          if (_showCA)
            Positioned(
              left: 16,
              right: 16,
              bottom: 24,
              child: Center(
                child: SizedBox(
                  width: 500,
                  child: Card(
                    elevation: 10,
                    // ignore: deprecated_member_use
                    shadowColor: Colors.black.withOpacity(0.3),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Row(
                                children: [
                                  Icon(Icons.history_toggle_off, color: _selectedColor),
                                  const SizedBox(width: 8),
                                  const Text(
                                    "CA Spread Steps (Forecast Interval)",
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14,
                                    ),
                                  ),
                                ],
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  // ignore: deprecated_member_use
                                  color: _selectedColor.withOpacity(0.15),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  "Step $_caSteps",
                                  style: TextStyle(
                                    color: _selectedColor,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Slider(
                            value: _caSteps.toDouble(),
                            min: 1,
                            max: 15,
                            divisions: 14,
                            activeColor: _selectedColor,
                            onChanged: (val) {
                              setState(() {
                                _caSteps = val.round();
                              });
                            },
                            onChangeEnd: (val) {
                              _fetchForecast(val.round());
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),

          if (_isLoading || _isIdwLoading || _isCaLoading || _isKrigingLoading)
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
                      Text(_isLoading
                          ? "Loading boundary map..."
                          : (_isIdwLoading && _isCaLoading && _isKrigingLoading)
                              ? "Fetching simulation layers..."
                              : _isIdwLoading
                                  ? "Fetching IDW contours..."
                                  : _isCaLoading
                                      ? "Fetching CA forecast..."
                                      : "Fetching Kriging contours..."),
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