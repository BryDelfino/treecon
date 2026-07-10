import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle, SystemNavigator;
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_marker_cluster/flutter_map_marker_cluster.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:shared_services/shared_services.dart';
import 'package:scout_mobile/src/core/services/network_service.dart';

class MapPage extends StatefulWidget {
  const MapPage({super.key});

  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> {
  final _mapController = MapController();
  List<Polygon> _countryPolygons = [];
  List<Polygon> _caPolygons = [];
  List<Polygon> _krigingPolygons = [];
  bool _isLoading = true;
  bool _isCaLoading = false;
  bool _isKrigingLoading = false;
  DateTime? _lastBackPress;

  // Simulation layers state
  bool _showCA = false;
  bool _showKriging = false;
  int _caSteps = 5;
  double _caOpacity = 0.6;
  double _krigingOpacity = 0.6;

  // Map controls state
  bool _isSatellite = false;
  double _currentZoom = 6.0;
  LatLng _mapCenter = const LatLng(12.8797, 121.7740);

  // Dataset state
  bool _isDatasetsLoading = false;
  List<Map<String, dynamic>> _availableDatasets = [];
  Map<String, dynamic>? _selectedDataset;

  // Plantation state
  bool _showPlantations = false;
  bool _isPlantationsLoading = false;
  List<Map<String, dynamic>> _plantationsData = [];

  StreamSubscription<bool>? _networkSub;

  @override
  void initState() {
    super.initState();
    final hasSession = Supabase.instance.client.auth.currentSession != null;
    if (NetworkService.instance.isOnline && hasSession) {
      _loadCountryBoundary();
      _fetchDatasets();
    } else {
      _isLoading = false;
    }

    _networkSub = NetworkService.instance.onConnectivityChanged.listen((isOnline) {
      if (!mounted) return;
      final hasSession = Supabase.instance.client.auth.currentSession != null;
      if (isOnline && hasSession && _countryPolygons.isEmpty && !_isCaLoading && !_isKrigingLoading) {
        setState(() {
          _isLoading = true;
        });
        _loadCountryBoundary();
        _fetchDatasets();
      }
    });
  }

  @override
  void dispose() {
    _networkSub?.cancel();
    super.dispose();
  }

  String get _apiBaseUrl {
    const envUrl = String.fromEnvironment('PYTHON_API_URL');
    if (envUrl.isNotEmpty) return envUrl;
    
    // Wi-Fi interface IP address of the host machine
    const hostIp = '192.168.18.9';
    if (defaultTargetPlatform == TargetPlatform.android) {
      return 'http://$hostIp:8000';
    }
    return 'http://127.0.0.1:8000';
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

  String _getSeverityClass(double value) {
    if (value < 10.0) return "Healthy";
    if (value < 25.0) return "Low";
    if (value < 50.0) return "Moderate";
    if (value < 75.0) return "High";
    return "Severe";
  }

  Color _getSeverityColor(double value) {
    if (value < 10.0) return Colors.green.shade700;
    if (value < 25.0) return Colors.yellow.shade800;
    if (value < 50.0) return Colors.orange;
    if (value < 75.0) return Colors.deepOrange;
    return Colors.red;
  }

  // --- Dataset Fetching ---
  Future<void> _fetchDatasets() async {
    setState(() => _isDatasetsLoading = true);
    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) {
        setState(() => _isDatasetsLoading = false);
        return;
      }
      
      final response = await Supabase.instance.client
          .from('datasets')
          .select('*')
          .or('is_public.eq.true,user_id.eq.${user.id}')
          .order('created_at', ascending: false);

      final datasets = List<Map<String, dynamic>>.from(response)
          .where((ds) => ds['is_deleted'] != true)
          .toList();

      // Fetch user profiles separately
      final userIds = datasets.map((ds) => ds['user_id']).whereType<String>().toSet().toList();
      if (userIds.isNotEmpty) {
        final usersResponse = await Supabase.instance.client
            .from('users')
            .select('user_id, user_name, role, avatar_url')
            .inFilter('user_id', userIds);

        final usersMap = <String, Map<String, dynamic>>{};
        for (var u in usersResponse) {
          usersMap[u['user_id'] as String] = u;
        }

        for (var ds in datasets) {
          final uid = ds['user_id'] as String?;
          if (uid != null && usersMap.containsKey(uid)) {
            ds['users'] = usersMap[uid];
          }
        }
      }
          
      setState(() {
        _availableDatasets = datasets;
        _isDatasetsLoading = false;
      });
    } catch (e) {
      debugPrint("Error fetching datasets: $e");
      setState(() => _isDatasetsLoading = false);
    }
  }

  String _getDatasetPublicUrl(Map<String, dynamic> dataset) {
    final isOwner = dataset['user_id'] == Supabase.instance.client.auth.currentUser?.id;
    final path = isOwner ? dataset['raw_filepath'] : dataset['perturbed_filepath'];
    return Supabase.instance.client.storage.from('datasets').getPublicUrl(path);
  }

  void _onDatasetSelected(Map<String, dynamic>? dataset) {
    setState(() {
      _selectedDataset = dataset;
      _caPolygons.clear();
      _krigingPolygons.clear();
      _plantationsData.clear();
    });

    if (dataset != null) {
      final url = _getDatasetPublicUrl(dataset);
      _fetchForecast(_caSteps, url);
      _fetchKriging(url);
      _fetchPlantations(url);
    }
  }

  // --- Plantation Fetching ---
  Future<void> _fetchPlantations(String datasetUrl) async {
    setState(() => _isPlantationsLoading = true);
    try {
      final response = await http.get(
        Uri.parse('$_apiBaseUrl/api/plantations?dataset_url=${Uri.encodeComponent(datasetUrl)}'),
      );
      if (response.statusCode == 200) {
        final List<dynamic> data = json.decode(response.body);
        setState(() {
          _plantationsData = data.cast<Map<String, dynamic>>();
          _showPlantations = true;
        });
      } else {
        debugPrint("API Error: ${response.statusCode}");
      }
    } catch (e) {
      debugPrint("Connection error: $e");
    } finally {
      setState(() => _isPlantationsLoading = false);
    }
  }

  List<Marker> _buildPlantationMarkers() {
    return _plantationsData.map((p) {
      final lat = double.tryParse(p['latitude'].toString()) ?? 0.0;
      final lng = double.tryParse(p['longitude'].toString()) ?? 0.0;
      
      final severity = double.tryParse((p['GSI'] ?? p['severity_index_pct'] ?? 0.0).toString()) ?? 0.0;
      
      Color color;
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
          onTap: () => _showPlantationInfoSheet(p),
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

  // --- Kriging Fetch ---
  Future<void> _fetchKriging(String datasetUrl) async {
    if (!mounted) return;
    setState(() {
      _isKrigingLoading = true;
    });
    try {
      final response = await http.post(
        Uri.parse('$_apiBaseUrl/api/kriging'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'dataset_url': datasetUrl,
        }),
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

  // --- CA Forecast Fetch ---
  Future<void> _fetchForecast(int steps, String datasetUrl) async {
    if (!mounted) return;
    setState(() {
      _isCaLoading = true;
    });
    try {
      final response = await http.post(
        Uri.parse('$_apiBaseUrl/api/forecast'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'dataset_url': datasetUrl,
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
                final props = Map<String, dynamic>.from(properties);
                props['centroid'] = _getCentroid(points);
                props['points'] = points;
                parsedList.add(Polygon(
                  points: points,
                  color: baseColor,
                  borderColor: baseColor,
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
                  final props = Map<String, dynamic>.from(properties);
                  props['centroid'] = _getCentroid(points);
                  props['points'] = points;
                  parsedList.add(Polygon(
                    points: points,
                    color: baseColor,
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

  // --- Bottom Sheet Settings ---
  void _showSettingsBottomSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24.0)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return DraggableScrollableSheet(
              initialChildSize: 0.55,
              minChildSize: 0.3,
              maxChildSize: 0.85,
              expand: false,
              builder: (context, scrollController) {
                return SingleChildScrollView(
                  controller: scrollController,
                  padding: const EdgeInsets.all(24.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Drag handle
                      Center(
                        child: Container(
                          width: 40,
                          height: 4,
                          margin: const EdgeInsets.only(bottom: 16),
                          decoration: BoxDecoration(
                            color: Colors.grey[300],
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
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

                      // --- Dataset Selector ---
                      const Text(
                        "DATASET",
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Colors.grey,
                          letterSpacing: 1.1,
                        ),
                      ),
                      const SizedBox(height: 8),
                      _isDatasetsLoading
                        ? const Center(child: SizedBox(height: 24, width: 24, child: CircularProgressIndicator(strokeWidth: 2)))
                        : Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.grey.shade300),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<String>(
                                value: _selectedDataset?['raw_filepath'],
                                hint: const Text('Select a dataset...', style: TextStyle(fontSize: 13)),
                                isExpanded: true,
                                icon: const Icon(Icons.arrow_drop_down),
                                items: _availableDatasets.map((ds) {
                                  final isOwner = ds['user_id'] == Supabase.instance.client.auth.currentUser?.id;
                                  final uploaderName = ds['users'] != null && ds['users'] is Map
                                    ? (ds['users'] as Map)['user_name']?.toString() ?? 'Unknown'
                                    : 'Unknown';
                                  return DropdownMenuItem<String>(
                                    value: ds['raw_filepath'] as String,
                                    child: Text(
                                      '${ds['filename']}${isOwner ? ' (Mine)' : ' by $uploaderName'}',
                                      style: const TextStyle(fontSize: 13),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  );
                                }).toList(),
                                onChanged: (val) {
                                  final dataset = _availableDatasets.firstWhere(
                                    (ds) => ds['raw_filepath'] == val,
                                  );
                                  _onDatasetSelected(dataset);
                                  setModalState(() {});
                                },
                              ),
                            ),
                          ),
                      const SizedBox(height: 20),

                      // --- Simulation Layers ---
                      const Text(
                        "SIMULATION LAYERS",
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Colors.grey,
                          letterSpacing: 1.1,
                        ),
                      ),
                      const SizedBox(height: 8),
                      CheckboxListTile(
                        title: const Text(
                          "Plantation Points",
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                        ),
                        secondary: Icon(Icons.scatter_plot, color: _showPlantations ? Colors.green[700] : Colors.grey),
                        value: _showPlantations,
                        activeColor: Colors.green[700],
                        onChanged: _selectedDataset == null ? null : (bool? val) {
                          setModalState(() {
                            _showPlantations = val ?? false;
                          });
                          setState(() {
                            _showPlantations = val ?? false;
                          });
                        },
                        controlAffinity: ListTileControlAffinity.leading,
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                      ),
                      CheckboxListTile(
                        title: Row(
                          children: [
                            const Text(
                              "Gall Rust Spread Forecast",
                              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                            ),
                            const SizedBox(width: 4),
                            Tooltip(
                              message: '⚠️ The step count has not yet been\ncalibrated to a specific time period.\nEach step is a simulation iteration,\nnot a day, week, or month.',
                              child: Icon(Icons.info_outline, size: 16, color: Colors.amber[700]),
                            ),
                          ],
                        ),
                        secondary: Icon(Icons.online_prediction, color: _showCA ? Colors.green[700] : Colors.grey),
                        value: _showCA,
                        activeColor: Colors.green[700],
                        onChanged: _selectedDataset == null ? null : (bool? val) {
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
                          "Gall Rust Spread Mapper",
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                        ),
                        secondary: Icon(Icons.grain, color: _showKriging ? Colors.green[700] : Colors.grey),
                        value: _showKriging,
                        activeColor: Colors.green[700],
                        onChanged: _selectedDataset == null ? null : (bool? val) {
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

                      // --- CA Steps Slider ---
                      if (_showCA) ...[
                        const SizedBox(height: 16),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              "Forecast Steps",
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
                            if (_selectedDataset != null) {
                              final url = _getDatasetPublicUrl(_selectedDataset!);
                              _fetchForecast(val.round(), url);
                            }
                          },
                        ),
                      ],

                      // --- Opacity Sliders ---
                      const SizedBox(height: 16),
                      const Text(
                        "LAYER OPACITY",
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Colors.grey,
                          letterSpacing: 1.1,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          const SizedBox(width: 8),
                          const Text("CA", style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
                          Expanded(
                            child: Slider(
                              value: _caOpacity,
                              min: 0.0,
                              max: 1.0,
                              divisions: 10,
                              activeColor: Colors.green[700],
                              onChanged: (val) {
                                setModalState(() => _caOpacity = val);
                                setState(() => _caOpacity = val);
                              },
                            ),
                          ),
                          SizedBox(
                            width: 36,
                            child: Text(
                              '${(_caOpacity * 100).round()}%',
                              style: const TextStyle(fontSize: 11),
                            ),
                          ),
                        ],
                      ),
                      Row(
                        children: [
                          const SizedBox(width: 8),
                          const Text("Kriging", style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
                          Expanded(
                            child: Slider(
                              value: _krigingOpacity,
                              min: 0.0,
                              max: 1.0,
                              divisions: 10,
                              activeColor: Colors.green[700],
                              onChanged: (val) {
                                setModalState(() => _krigingOpacity = val);
                                setState(() => _krigingOpacity = val);
                              },
                            ),
                          ),
                          SizedBox(
                            width: 36,
                            child: Text(
                              '${(_krigingOpacity * 100).round()}%',
                              style: const TextStyle(fontSize: 11),
                            ),
                          ),
                        ],
                      ),

                      // --- Severity Legend ---
                      const SizedBox(height: 16),
                      const Text(
                        "SEVERITY LEGEND",
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Colors.grey,
                          letterSpacing: 1.1,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          _legendItem(Colors.green.shade700, "Healthy"),
                          _legendItem(Colors.yellow.shade700, "Low"),
                          _legendItem(Colors.orange, "Moderate"),
                          _legendItem(Colors.red, "High"),
                          _legendItem(const Color(0xFF800000), "Severe"),
                        ],
                      ),
                      const SizedBox(height: 24),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
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

  // --- Plantation Info Bottom Sheet ---
  void _showPlantationInfoSheet(Map<String, dynamic> p) {
    final isOwner = _selectedDataset != null && _selectedDataset!['user_id'] == Supabase.instance.client.auth.currentUser?.id;

    String getValue(List<String> keys) {
      for (final k in p.keys) {
        final norm = k.toLowerCase().replaceAll('_', '').replaceAll(' ', '');
        for (final target in keys) {
          if (norm == target.toLowerCase().replaceAll('_', '').replaceAll(' ', '')) {
            final v = p[k];
            if (v != null && v.toString().trim().isNotEmpty) return v.toString();
          }
        }
      }
      return 'N/A';
    }

    final recordIdStr = getValue(['recordid', 'record', 'id']);
    final popupTitle = (isOwner && recordIdStr != 'N/A') ? "Record $recordIdStr" : "Plantation Record";
    final gsiStr = getValue(['gsi', 'severity_index_pct', 'GSI']);
    final gsiVal = double.tryParse(gsiStr) ?? 0.0;
    final isGsiValid = gsiStr != 'N/A';

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24.0)),
      ),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Row(
                children: [
                  Icon(Icons.eco, color: Colors.green[700]),
                  const SizedBox(width: 8),
                  Text(popupTitle, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                ],
              ),
              const Divider(height: 20),
              if (isOwner) ...[
                Text("Lat/Lng: ${getValue(['latitude', 'lat'])}, ${getValue(['longitude', 'lng'])}", style: const TextStyle(fontSize: 13)),
                const SizedBox(height: 4),
              ],
              Text("Region: ${getValue(['region', 'region_number'])}", style: const TextStyle(fontSize: 13)),
              Text("Plantation: ${getValue(['plantation', 'plantation_id', 'plantation_number'])}", style: const TextStyle(fontSize: 13)),
              Text("Plot Number: ${getValue(['plot', 'plot_number', 'plotnumber'])}", style: const TextStyle(fontSize: 13)),
              Text("GRI: ${getValue(['gri', 'GRI'])}", style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 4),
              Text(
                "GSI: ${isGsiValid ? '$gsiStr% (${_getSeverityClass(gsiVal)})' : 'N/A'}", 
                style: TextStyle(
                  fontSize: 14, 
                  fontWeight: isGsiValid ? FontWeight.bold : FontWeight.normal,
                  color: isGsiValid ? _getSeverityColor(gsiVal) : Colors.black87,
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }

  // --- Placeholder Widgets ---
  Widget _mapControlButton({
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.1),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Icon(icon, color: Colors.green[800], size: 24),
      ),
    );
  }

  String _getScaleText() {
    final metersPerPixel = 156543.03392 * math.cos(_mapCenter.latitude * math.pi / 180) / math.pow(2, _currentZoom);
    final distanceMeters = 60 * metersPerPixel;
    if (distanceMeters >= 1000) {
      return '${(distanceMeters / 1000).toStringAsFixed(1)} km';
    } else {
      return '${distanceMeters.toStringAsFixed(0)} m';
    }
  }

  Widget _buildOfflinePlaceholder() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.cloud_off_rounded, size: 80, color: Colors.grey[400]),
            const SizedBox(height: 20),
            const Text(
              "Map Unavailable Offline",
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.black87),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              "The spread tracking simulation relies on an internet connection to run forecast calculations. Connect to the internet to use the map features.",
              style: TextStyle(fontSize: 14, color: Colors.grey[600]),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSignInPlaceholder() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.lock_outline_rounded, size: 80, color: Colors.grey[400]),
            const SizedBox(height: 20),
            const Text(
              "Sign In Required",
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.black87),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              "Sign in to your account to access the spatial map and simulation features.",
              style: TextStyle(fontSize: 14, color: Colors.grey[600]),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: Colors.green[700],
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
              onPressed: () {
                Navigator.of(context).pushNamedAndRemoveUntil('/', (route) => false);
              },
              icon: const Icon(Icons.login),
              label: const Text(
                "Sign In Now",
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<bool>(
      stream: NetworkService.instance.onConnectivityChanged,
      initialData: NetworkService.instance.isOnline,
      builder: (context, snapshot) {
        final isOnline = snapshot.data ?? false;
        
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            final now = DateTime.now();
            if (_lastBackPress != null && now.difference(_lastBackPress!) < const Duration(seconds: 2)) {
              SystemNavigator.pop();
            } else {
              _lastBackPress = now;
              ScaffoldMessenger.of(context).clearSnackBars();
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: const Text('Press back again to exit'),
                  duration: const Duration(seconds: 2),
                  backgroundColor: Colors.grey[800],
                  behavior: SnackBarBehavior.floating,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              );
            }
          },
          child: Scaffold(
            appBar: AppBar(
              automaticallyImplyLeading: false,
              title: const Text(
                "Spatial Map",
                style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
              ),
              backgroundColor: Colors.green[700],
              foregroundColor: Colors.white,
              elevation: 2,
            ),
          body: !isOnline
              ? _buildOfflinePlaceholder()
              : Supabase.instance.client.auth.currentSession == null
                  ? _buildSignInPlaceholder()
                  : Stack(
                  children: [
                    FlutterMap(
                      mapController: _mapController,
                      options: MapOptions(
                        initialCenter: const LatLng(12.8797, 121.7740),
                        initialZoom: 6,
                        minZoom: 5,
                        maxZoom: 17.0,
                        onPositionChanged: (camera, hasGesture) {
                          setState(() {
                            _currentZoom = camera.zoom;
                            _mapCenter = camera.center;
                          });
                        },
                      ),
                      children: [
                        TileLayer(
                          urlTemplate: _isSatellite
                              ? 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}'
                              : 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Topo_Map/MapServer/tile/{z}/{y}/{x}',
                          userAgentPackageName: 'com.treecon.scout',
                        ),

                        // Simulation contour layers with opacity
                        if (_showCA && _caPolygons.isNotEmpty)
                          PolygonLayer(
                            polygons: _applyOpacity(_caPolygons, _caOpacity),
                          ),
                        if (_showKriging && _krigingPolygons.isNotEmpty)
                          PolygonLayer(
                            polygons: _applyOpacity(_krigingPolygons, _krigingOpacity),
                          ),

                        // Plantation markers with clustering
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
                      ],
                    ),

                    // Dataset selector chip at top
                    if (!_isLoading)
                      Positioned(
                        top: 12,
                        left: 12,
                        right: 12,
                        child: SafeArea(
                          child: GestureDetector(
                            onTap: () => _showSettingsBottomSheet(context),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(12),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.1),
                                    blurRadius: 8,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: Row(
                                children: [
                                  Icon(Icons.storage, size: 18, color: Colors.green[700]),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      _selectedDataset != null
                                        ? _selectedDataset!['filename'] ?? 'Unknown'
                                        : 'Tap to select a dataset...',
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: _selectedDataset != null ? FontWeight.w600 : FontWeight.normal,
                                        color: _selectedDataset != null ? Colors.black87 : Colors.grey[600],
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  Icon(Icons.arrow_drop_down, color: Colors.grey[600]),
                                ],
                              ),
                            ),
                          ),
                        ),
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

                    // Map scale box
                    if (!_isLoading)
                      Positioned(
                        bottom: 16,
                        right: 88,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.8),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.grey.shade400, width: 1.0),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.1),
                                blurRadius: 4,
                                offset: const Offset(0, 2),
                              )
                            ]
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 24,
                                height: 4,
                                decoration: const BoxDecoration(
                                  border: Border(
                                    bottom: BorderSide(color: Colors.black87, width: 2),
                                    left: BorderSide(color: Colors.black87, width: 2),
                                    right: BorderSide(color: Colors.black87, width: 2),
                                  )
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                _getScaleText(),
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                      ),

                    // Map controls (zoom, tile, rotation)
                    if (!_isLoading)
                      Positioned(
                        bottom: 16,
                        left: 12,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Reset rotation (always visible)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: _mapControlButton(
                                icon: Icons.navigation_rounded,
                                onTap: () {
                                  _mapController.rotate(0);
                                },
                              ),
                            ),
                            // Satellite toggle
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: _mapControlButton(
                                icon: _isSatellite ? Icons.map_outlined : Icons.satellite_alt,
                                onTap: () => setState(() => _isSatellite = !_isSatellite),
                              ),
                            ),
                            // Zoom in
                            _mapControlButton(
                              icon: Icons.add,
                              onTap: () {
                                final zoom = _mapController.camera.zoom + 1;
                                _mapController.move(_mapController.camera.center, zoom);
                              },
                            ),
                            const SizedBox(height: 2),
                            // Zoom out
                            _mapControlButton(
                              icon: Icons.remove,
                              onTap: () {
                                final zoom = _mapController.camera.zoom - 1;
                                _mapController.move(_mapController.camera.center, zoom);
                              },
                            ),
                          ],
                        ),
                      ),

                    // Progress Overlay
                    if (_isLoading || _isCaLoading || _isKrigingLoading || _isPlantationsLoading)
                      Positioned(
                        top: _selectedDataset != null ? 68 : 16,
                        left: 16,
                        right: 16,
                        child: SafeArea(
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
                                          : (_isCaLoading && _isKrigingLoading)
                                              ? "Fetching simulation layers..."
                                              : _isCaLoading
                                                  ? "Fetching CA forecast..."
                                                  : _isKrigingLoading
                                                      ? "Fetching Kriging contours..."
                                                      : "Fetching plantation data...",
                                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ), // closes ternary for sign-in check
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
          ),  // closes Scaffold
        );  // closes PopScope
      },
    );
  }
}
