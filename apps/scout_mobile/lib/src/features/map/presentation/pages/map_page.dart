import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';

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
  static const double _borderWidth = 0.5;
  static const Color _selectedColor = Colors.black;

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
      for (final dynamic feature in features) {
        final f = feature as Map<String, dynamic>;
        final Map<String, dynamic> geometry = f['geometry'] as Map<String, dynamic>;
        final String geomType = geometry['type'] as String;

        if (geomType == 'MultiPolygon') {
          final List<dynamic> coordinates = geometry['coordinates'] as List<dynamic>;
          for (final dynamic polygonData in coordinates) {
            for (final dynamic ringData in polygonData as List<dynamic>) {
              final List<LatLng> points = [];
              for (final dynamic coord in ringData as List<dynamic>) {
                final c = coord as List<dynamic>;
                final double lng = (c[0] as num).toDouble();
                final double lat = (c[1] as num).toDouble();
                points.add(LatLng(lat, lng));
              }
              if (points.isNotEmpty) {
                polygons.add(Polygon(points: points, hitValue: f['properties']));
              }
            }
          }
        } else if (geomType == 'Polygon') {
          final List<dynamic> coordinates = geometry['coordinates'] as List<dynamic>;
          for (final dynamic ringData in coordinates) {
            final List<LatLng> points = [];
            for (final dynamic coord in ringData as List<dynamic>) {
              final c = coord as List<dynamic>;
              final double lng = (c[0] as num).toDouble();
              final double lat = (c[1] as num).toDouble();
              points.add(LatLng(lat, lng));
            }
            if (points.isNotEmpty) {
              polygons.add(Polygon(points: points, hitValue: f['properties']));
            }
          }
        }
      }
      if (mounted) {
        setState(() {
          _countryPolygons = polygons;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading country GeoJSON: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  // Parses a hex color string (e.g. "#A1D99B") into a Flutter Color
  Color _parseHexColor(String hex) {
    final buffer = StringBuffer();
    if (hex.length == 6 || hex.length == 7) buffer.write('ff');
    buffer.write(hex.replaceFirst('#', ''));
    return Color(int.parse(buffer.toString(), radix: 16));
  }

  String get _apiBaseUrl {
    // Wi-Fi interface IP address of the host machine
    const hostIp = '192.168.18.9';
    if (defaultTargetPlatform == TargetPlatform.android) {
      return 'http://$hostIp:8000';
    }
    return 'http://127.0.0.1:8000';
  }

  // Fetches IDW Contours from Python server
  Future<void> _fetchIDW() async {
    if (!mounted) return;
    setState(() {
      _isIdwLoading = true;
    });
    try {
      final response = await http.post(
        Uri.parse('$_apiBaseUrl/api/idw'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'grid_resolution': 0.12,
          'power': 2.0,
        }),
      );
      if (response.statusCode == 200 && mounted) {
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
      if (mounted) {
        setState(() {
          _isIdwLoading = false;
        });
      }
    }
  }

  // Fetches Kriging Contours from Python server
  Future<void> _fetchKriging() async {
    if (!mounted) return;
    setState(() {
      _isKrigingLoading = true;
    });
    try {
      final response = await http.post(
        Uri.parse('$_apiBaseUrl/api/kriging'),
        headers: {'Content-Type': 'application/json'},
      );
      if (response.statusCode == 200 && mounted) {
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
      if (mounted) {
        setState(() {
          _isKrigingLoading = false;
        });
      }
    }
  }

  // Fetches Cellular Automata spread forecast from Python server
  Future<void> _fetchForecast(int steps) async {
    if (!mounted) return;
    setState(() {
      _isCaLoading = true;
    });
    try {
      final response = await http.post(
        Uri.parse('$_apiBaseUrl/api/forecast'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'steps': steps,
          'grid_resolution': 0.12,
          'spread_factor': 0.08,
        }),
      );
      if (response.statusCode == 200 && mounted) {
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
      if (mounted) {
        setState(() {
          _isCaLoading = false;
        });
      }
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
                final Color opacityColor = baseColor.withValues(alpha: _fillOpacity * 1.5 > 1.0 ? 1.0 : _fillOpacity * 1.5);
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
                  final Color opacityColor = baseColor.withValues(alpha: _fillOpacity * 1.5 > 1.0 ? 1.0 : _fillOpacity * 1.5);
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

  void _showSettingsBottomSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24.0)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(Icons.layers_outlined, color: Colors.green[700]),
                      const SizedBox(width: 8),
                      const Text(
                        "Map Controls & Settings",
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 24),
                  const Text(
                    "Simulation Layers",
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Colors.grey,
                      letterSpacing: 1.1,
                    ),
                  ),
                  const SizedBox(height: 8),
                  CheckboxListTile(
                    title: const Text(
                      "IDW Interpolation Contours",
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                    ),
                    secondary: Icon(Icons.waves, color: _showIDW ? Colors.green[700] : Colors.grey),
                    value: _showIDW,
                    activeColor: Colors.green[700],
                    onChanged: (bool? val) {
                      setModalState(() {
                        _showIDW = val ?? false;
                      });
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
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                    ),
                    secondary: Icon(Icons.online_prediction, color: _showCA ? Colors.green[700] : Colors.grey),
                    value: _showCA,
                    activeColor: Colors.green[700],
                    onChanged: (bool? val) {
                      setModalState(() {
                        _showCA = val ?? false;
                      });
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
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                    ),
                    secondary: Icon(Icons.grain, color: _showKriging ? Colors.green[700] : Colors.grey),
                    value: _showKriging,
                    activeColor: Colors.green[700],
                    onChanged: (bool? val) {
                      setModalState(() {
                        _showKriging = val ?? false;
                      });
                      setState(() {
                        _showKriging = val ?? false;
                      });
                    },
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                  ),
                  if (_showCA) ...[
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          "CA Forecast Steps",
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.green[100],
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            "Step $_caSteps",
                            style: TextStyle(
                              color: Colors.green[800],
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                    Slider(
                      value: _caSteps.toDouble(),
                      min: 1,
                      max: 15,
                      divisions: 14,
                      activeColor: Colors.green[700],
                      onChanged: (val) {
                        setModalState(() {
                          _caSteps = val.round();
                        });
                        setState(() {
                          _caSteps = val.round();
                        });
                      },
                      onChangeEnd: (val) {
                        _fetchForecast(val.round());
                      },
                    ),
                  ],
                  const SizedBox(height: 16),
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
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          "Spatial Map",
          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        ),
        backgroundColor: Colors.green[700],
        foregroundColor: Colors.white,
        elevation: 2,
      ),
      body: Stack(
        children: [
          FlutterMap(
            options: const MapOptions(
              initialCenter: LatLng(12.8797, 121.7740),
              initialZoom: 6,
              minZoom: 5,
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Topo_Map/MapServer/tile/{z}/{y}/{x}',
                userAgentPackageName: 'com.treecon.scout',
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

              // Simulation contour layers
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

          // Floating button to open bottom sheet
          if (!_isLoading)
            Positioned(
              bottom: 16,
              right: 16,
              child: FloatingActionButton(
                onPressed: () => _showSettingsBottomSheet(context),
                backgroundColor: Colors.green[700],
                foregroundColor: Colors.white,
                child: const Icon(Icons.layers_outlined),
              ),
            ),

          // Progress Overlay
          if (_isLoading || _isIdwLoading || _isCaLoading || _isKrigingLoading)
            Positioned(
              top: 16,
              left: 16,
              right: 16,
              child: Card(
                elevation: 4,
                color: Colors.white,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(color: Colors.green, strokeWidth: 2),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Text(
                          _isLoading
                              ? "Loading boundary map..."
                              : (_isIdwLoading && _isCaLoading && _isKrigingLoading)
                                  ? "Fetching simulation layers..."
                                  : _isIdwLoading
                                      ? "Fetching IDW contours..."
                                      : _isCaLoading
                                          ? "Fetching CA forecast..."
                                          : "Fetching Kriging contours...",
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                        ),
                      ),
                    ],
                  ),
                ),
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
          currentIndex: 1,
          onTap: (index) {
            if (index == 0) {
              Navigator.of(context).pushReplacementNamed('/observations');
            } else if (index == 1) {
              // already on map
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
    );
  }
}
