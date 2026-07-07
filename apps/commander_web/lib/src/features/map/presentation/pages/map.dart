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
  final _hitNotifier = ValueNotifier<LayerHitResult<Object>?>(null);

  List<Polygon> _countryPolygons = [];
  List<Polygon> _caPolygons = [];
  List<Polygon> _krigingPolygons = [];
  bool _isLoading = true;
  bool _isCaLoading = false;
  bool _isKrigingLoading = false;

  // Customization state (fixed defaults)
  static const double _borderOpacity = 0.80;
  static const double _borderWidth = 0.5;
  static const Color _selectedColor = Colors.black;

  // Simulation layers state
  bool _showCA = false;
  bool _showKriging = false;
  int _caSteps = 5;
  double _caOpacity = 0.6;
  double _krigingOpacity = 0.6;
  bool _isCAExpanded = false;
  bool _isKrigingExpanded = false;

  Map<String, dynamic>? _selectedRegionProps;
  LatLng? _selectedRegionLocation;

  String _getSeverityClass(double value) {
    if (value <= 20) return "Healthy";
    if (value <= 40) return "Low";
    if (value <= 60) return "Moderate";
    if (value <= 80) return "High";
    return "Severe";
  }

  List<Polygon> _applyOpacity(List<Polygon> source, double targetOpacity) {
    return source.map((p) => Polygon(
      points: p.points,
      // ignore: deprecated_member_use
      color: (p.color ?? Colors.transparent).withValues(alpha: targetOpacity),
      borderColor: Colors.transparent,
      borderStrokeWidth: 0,
      hitValue: p.hitValue,
    )).toList();
  }

  List<Polygon> _getHighlightedPolygons() {
    if (_selectedRegionProps == null || _selectedRegionProps!['points'] == null) return [];
    return [
      Polygon(
        points: _selectedRegionProps!['points'] as List<LatLng>,
        color: Colors.transparent,
        borderColor: Colors.yellowAccent,
        borderStrokeWidth: 4.0,
      )
    ];
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
    _loadCountryBoundary();
    _fetchForecast(_caSteps);
    _fetchKriging();
  }

  Widget _buildInfoWindow(Map<String, dynamic> properties) {
    final name = properties['adm2_name'] ?? properties['adm3_name'] ?? 'Unknown Region';
    final severityValue = properties['severity_value']?.toString() ?? 'N/A';
    
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Card(
          elevation: 6,
          color: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.all(12.0),
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
                if (severityValue != 'N/A')
                  Text('Severity: $severityValue% (${_getSeverityClass(double.tryParse(severityValue) ?? 0)})', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                if (severityValue == 'N/A')
                  const Text('No severity data available.', style: TextStyle(fontSize: 12)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // Loads the country boundary once and caches polygons
  Future<void> _loadCountryBoundary() async {
    try {
      final String jsonString = await rootBundle.loadString('assets/philippines.json');
      final Map<String, dynamic> geoJson = json.decode(jsonString);
      final List<Polygon> polygons = [];

      final List<Map<String, dynamic>> features = (geoJson['features'] as List<dynamic>).cast<Map<String, dynamic>>();
      for (final Map<String, dynamic> feature in features) {
        final Map<String, dynamic> geometry = feature['geometry'] as Map<String, dynamic>;
        final String geomType = geometry['type'] as String;

        if (geomType == 'MultiPolygon') {
          final List<dynamic> coordinates = geometry['coordinates'] as List<dynamic>;
          for (final polygonData in coordinates) {
            for (final ringData in polygonData as List<dynamic>) {
              final List<LatLng> points = [];
              for (final coord in ringData as List<dynamic>) {
                final List<dynamic> coordList = coord as List<dynamic>;
                final double lng = (coordList[0] as num).toDouble();
                final double lat = (coordList[1] as num).toDouble();
                points.add(LatLng(lat, lng));
              }
              if (points.isNotEmpty) {
                final props = Map<String, dynamic>.from(feature['properties'] as Map);
                props['centroid'] = _getCentroid(points);
                props['points'] = points;
                polygons.add(Polygon(
                  points: points,
                  color: Colors.transparent,
                  borderColor: _selectedColor.withValues(alpha: _borderOpacity),
                  borderStrokeWidth: _borderWidth,
                  hitValue: props,
                ));
              }
            }
          }
        } else if (geomType == 'Polygon') {
          final List<dynamic> coordinates = geometry['coordinates'] as List<dynamic>;
          for (final ringData in coordinates) {
            final List<LatLng> points = [];
            for (final coord in ringData as List<dynamic>) {
              final List<dynamic> coordList = coord as List<dynamic>;
              final double lng = (coordList[0] as num).toDouble();
              final double lat = (coordList[1] as num).toDouble();
              points.add(LatLng(lat, lng));
            }
            if (points.isNotEmpty) {
              final props = Map<String, dynamic>.from(feature['properties'] as Map);
              props['centroid'] = _getCentroid(points);
              props['points'] = points;
              polygons.add(Polygon(
                points: points,
                color: Colors.transparent,
                borderColor: _selectedColor.withValues(alpha: _borderOpacity),
                borderStrokeWidth: _borderWidth,
                hitValue: props,
              ));
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
              if (_countryPolygons.isNotEmpty)
                PolygonLayer(
                  polygons: _countryPolygons,
                  simplificationTolerance: 1.2,
                  hitNotifier: _hitNotifier,
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
                      height: 140,
                      alignment: Alignment.topCenter,
                      child: _buildInfoWindow(_selectedRegionProps!),
                    )
                  ],
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
                      ],
                    ),
                  ),
                ),
              ),
            ),

          if (_isLoading || _isCaLoading || _isKrigingLoading)
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
                          : (_isCaLoading && _isKrigingLoading)
                              ? "Fetching simulation layers..."
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