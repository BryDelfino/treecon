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
  List<List<LatLng>> _boundaryRings = [];
  List<Polygon> _overlayPolygons = [];
  bool _isLoading = true;
  bool _isOverlayLoading = false;

  // Customization state
  double _fillOpacity = 0.25;
  double _borderOpacity = 0.80;
  double _borderWidth = 2.0;
  Color _selectedColor = Colors.green;

  // Simulation layers state
  bool _showIDW = false;
  bool _showCA = false;
  int _caSteps = 5;

  final List<Color> _colorOptions = [
    Colors.green,
    Colors.teal,
    Colors.blue,
    Colors.indigo,
    Colors.orange,
    Colors.red,
    Colors.blueGrey,
  ];

  @override
  void initState() {
    super.initState();
    _loadBoundary();
  }

  // Parses a hex color string (e.g. "#A1D99B") into a Flutter Color
  Color _parseHexColor(String hex) {
    final buffer = StringBuffer();
    if (hex.length == 6 || hex.length == 7) buffer.write('ff');
    buffer.write(hex.replaceFirst('#', ''));
    return Color(int.parse(buffer.toString(), radix: 16));
  }

  // Loads the base country boundary map
  Future<void> _loadBoundary() async {
    try {
      final String jsonString = await rootBundle.loadString('assets/philippines.json');
      final Map<String, dynamic> geoJson = json.decode(jsonString);
      final List<List<LatLng>> rings = [];

      final Map<String, dynamic>? geometry = geoJson['geometry'] as Map<String, dynamic>?;
      if (geometry != null && geometry['type'] == 'MultiPolygon') {
        final coordinates = geometry['coordinates'] as List<dynamic>;
        for (final polygonData in coordinates) {
          final polyList = polygonData as List<dynamic>;
          for (final ringData in polyList) {
            final ringList = ringData as List<dynamic>;
            final List<LatLng> points = [];
            for (final coord in ringList) {
              final coordList = coord as List<dynamic>;
              final double lng = (coordList[0] as num).toDouble();
              final double lat = (coordList[1] as num).toDouble();
              points.add(LatLng(lat, lng));
            }
            if (points.isNotEmpty) {
              rings.add(points);
            }
          }
        }
      }

      setState(() {
        _boundaryRings = rings;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint("Error loading boundary GeoJSON: $e");
      setState(() {
        _isLoading = false;
      });
    }
  }

  // Fetches IDW Contours from Python server
  Future<void> _fetchIDW() async {
    setState(() {
      _isOverlayLoading = true;
      _overlayPolygons = [];
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
        _parseOverlayGeoJSON(response.body);
      } else {
        debugPrint("API Error: ${response.statusCode}");
      }
    } catch (e) {
      debugPrint("Connection error: $e");
    } finally {
      setState(() {
        _isOverlayLoading = false;
      });
    }
  }

  // Fetches Cellular Automata spread forecast from Python server
  Future<void> _fetchForecast(int steps) async {
    setState(() {
      _isOverlayLoading = true;
      _overlayPolygons = [];
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
        _parseOverlayGeoJSON(response.body);
      } else {
        debugPrint("API Error: ${response.statusCode}");
      }
    } catch (e) {
      debugPrint("Connection error: $e");
    } finally {
      setState(() {
        _isOverlayLoading = false;
      });
    }
  }

  // Helper to parse features from spatial engine GeoJSON output
  void _parseOverlayGeoJSON(String jsonString) {
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
      setState(() {
        _overlayPolygons = parsedList;
      });
    } catch (e) {
      debugPrint("Error parsing overlay GeoJSON: $e");
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
    Color borderColor = _selectedColor == Colors.blueGrey 
        ? Colors.blueGrey.shade900 
        : _selectedColor is MaterialColor 
            ? (_selectedColor as MaterialColor).shade800 
            : _selectedColor;

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
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.treecon.commander',
              ),
              
              // 1. Base Mask Boundary Outline
              if (_boundaryRings.isNotEmpty)
                PolygonLayer(
                  polygons: _boundaryRings.map((points) {
                    return Polygon(
                      points: points,
                      // ignore: deprecated_member_use
                      color: _selectedColor.withOpacity(_fillOpacity),
                      // ignore: deprecated_member_use
                      borderColor: borderColor.withOpacity(_borderOpacity),
                      borderStrokeWidth: _borderWidth,
                    );
                  }).toList(),
                ),

              // 2. Dynamic simulation contour layers
              if ((_showIDW || _showCA) && _overlayPolygons.isNotEmpty)
                PolygonLayer(
                  polygons: _overlayPolygons,
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
                          "Simulation Layer",
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Colors.grey,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Column(
                          children: [
                            _buildLayerButton(
                              title: "None (Base Outline Only)",
                              active: !_showIDW && !_showCA,
                              icon: Icons.map_outlined,
                              onTap: () {
                                setState(() {
                                  _showIDW = false;
                                  _showCA = false;
                                  _overlayPolygons = [];
                                });
                              },
                            ),
                            const SizedBox(height: 8),
                            _buildLayerButton(
                              title: "IDW Interpolation Contours",
                              active: _showIDW,
                              icon: Icons.waves,
                              onTap: () {
                                setState(() {
                                  _showIDW = true;
                                  _showCA = false;
                                });
                                _fetchIDW();
                              },
                            ),
                            const SizedBox(height: 8),
                            _buildLayerButton(
                              title: "CA Spread Forecast",
                              active: _showCA,
                              icon: Icons.online_prediction,
                              onTap: () {
                                setState(() {
                                  _showIDW = false;
                                  _showCA = true;
                                });
                                _fetchForecast(_caSteps);
                              },
                            ),
                          ],
                        ),
                        const Divider(height: 24),
                        
                        // Color Options
                        const Text(
                          "Mask Base Color",
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Colors.grey,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: _colorOptions.map((color) {
                            final bool isSelected = _selectedColor == color;
                            return GestureDetector(
                              onTap: () {
                                setState(() {
                                  _selectedColor = color;
                                });
                              },
                              child: Container(
                                width: 30,
                                height: 30,
                                decoration: BoxDecoration(
                                  color: color,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: isSelected ? Colors.black : Colors.white,
                                    width: isSelected ? 2.5 : 1.0,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      // ignore: deprecated_member_use
                                      color: Colors.black.withOpacity(0.15),
                                      blurRadius: 4,
                                      offset: const Offset(0, 2),
                                    )
                                  ],
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                        const SizedBox(height: 16),

                        // Fill Opacity
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              "Mask Fill Opacity",
                              style: TextStyle(fontWeight: FontWeight.w500),
                            ),
                            Text("${(_fillOpacity * 100).round()}%"),
                          ],
                        ),
                        Slider(
                          value: _fillOpacity,
                          min: 0.0,
                          max: 1.0,
                          activeColor: _selectedColor,
                          onChanged: (val) {
                            setState(() {
                              _fillOpacity = val;
                            });
                          },
                        ),

                        // Border Opacity
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              "Mask Border Opacity",
                              style: TextStyle(fontWeight: FontWeight.w500),
                            ),
                            Text("${(_borderOpacity * 100).round()}%"),
                          ],
                        ),
                        Slider(
                          value: _borderOpacity,
                          min: 0.0,
                          max: 1.0,
                          activeColor: _selectedColor,
                          onChanged: (val) {
                            setState(() {
                              _borderOpacity = val;
                            });
                          },
                        ),

                        // Border Width
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              "Mask Border Width",
                              style: TextStyle(fontWeight: FontWeight.w500),
                            ),
                            Text("${_borderWidth.toStringAsFixed(1)} px"),
                          ],
                        ),
                        Slider(
                          value: _borderWidth,
                          min: 0.5,
                          max: 6.0,
                          activeColor: _selectedColor,
                          onChanged: (val) {
                            setState(() {
                              _borderWidth = val;
                            });
                          },
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

          if (_isLoading || _isOverlayLoading)
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
                      Text(_isLoading ? "Loading boundary map..." : "Fetching simulation layers..."),
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