import 'dart:async';
import 'dart:convert';

import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemNavigator;
import 'package:flutter/foundation.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_marker_cluster/flutter_map_marker_cluster.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'package:shared_services/shared_services.dart';
import 'package:scout_mobile/src/core/services/network_service.dart';
import 'package:intl/intl.dart';
import 'package:scout_mobile/src/features/observations/presentation/pages/observation_details_page.dart';

class MapPage extends StatefulWidget {
  final Map<String, dynamic>? highlightObservation;

  const MapPage({super.key, this.highlightObservation});

  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> with SingleTickerProviderStateMixin {
  final _mapController = MapController();
  LatLng? _highlightedLatLng;
  late final AnimationController _highlightPulseController;
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
  String? _currentUserRole;

  DateTime? _datasetStartDate;
  DateTime? _datasetEndDate;
  bool _showMyDatasetsOnly = false;
  String _datasetVisibilityFilter = 'All';

  List<Map<String, dynamic>> get _filteredDatasets {
    return _availableDatasets.where((ds) {
      if (_currentUserRole == 'EXPERT') {
        if (_showMyDatasetsOnly) {
          final currentUserId = Supabase.instance.client.auth.currentUser?.id;
          if (currentUserId != null && ds['user_id'] != currentUserId) {
            return false;
          }
        }
        if (_datasetVisibilityFilter != 'All') {
          final isPublic = ds['is_public'] == true;
          if (_datasetVisibilityFilter == 'Public' && !isPublic) return false;
          if (_datasetVisibilityFilter == 'Private' && isPublic) return false;
        }
      }

      if (_datasetStartDate != null || _datasetEndDate != null) {
        final dateStr = ds['created_at'] as String?;
        if (dateStr != null) {
          final date = DateTime.tryParse(dateStr);
          if (date != null) {
            if (_datasetStartDate != null && date.isBefore(_datasetStartDate!)) return false;
            if (_datasetEndDate != null && date.isAfter(_datasetEndDate!.add(const Duration(days: 1)))) return false;
          }
        }
      }
      return true;
    }).toList();
  }

  // Plantation state
  bool _showPlantations = false;
  bool _isPlantationsLoading = false;
  List<Map<String, dynamic>> _plantationsData = [];
  bool _isPlantationExpanded = false;
  bool _isCaExpanded = false;
  bool _isKrigingExpanded = false;
  String _selectedPlantationProvince = 'All';
  String _selectedPlantationSeverity = 'All';
  final List<String> _availableSeverities = ['All', 'Healthy', 'Low', 'Moderate', 'High', 'Severe'];

  // Observations state
  bool _showObservations = true;
  bool _isObservationsExpanded = false;
  String _selectedObservationVerification = 'All';
  String _selectedObservationUserRole = 'All';
  String _selectedObservationProvince = 'All';
  DateTime? _observationStartDate;
  DateTime? _observationEndDate;
  bool _showMyObservationsOnly = false;
  bool _hideAnonymousObservations = false;
  List<Map<String, dynamic>> _observationsData = [];
  final List<String> _availableVerificationStatuses = ['All', 'Verified', 'Unverified'];
  final List<String> _availableUserRoles = ['All', 'Expert', 'Community'];

  Map<String, dynamic>? _selectedRegionProps;

  StreamSubscription<bool>? _networkSub;

  @override
  void initState() {
    super.initState();
    _highlightPulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    final hasSession = Supabase.instance.client.auth.currentSession != null;
    if (widget.highlightObservation != null) {
      _showObservations = true;
    }
    if (NetworkService.instance.isOnline && hasSession) {
      _loadCountryBoundary();
      _fetchDatasets();
      if (widget.highlightObservation != null) {
        _fetchObservations().then((_) => _applyHighlightedObservation());
      } else if (_showObservations) {
        _fetchObservations();
      }
    } else {
      _isLoading = false;
      if (widget.highlightObservation != null) {
        _applyHighlightedObservation();
      }
    }

    _networkSub = NetworkService.instance.onConnectivityChanged.listen((isOnline) {
      if (!mounted) return;
      if (!isOnline) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
      final hasSession = Supabase.instance.client.auth.currentSession != null;
      if (isOnline && hasSession && !ProvinceLookup.isLoaded && !_isCaLoading && !_isKrigingLoading) {
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
    _highlightPulseController.dispose();
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

  // Loads the country boundary once and caches province polygons
  Future<void> _loadCountryBoundary() async {
    try {
      await ProvinceLookup.load();
      if (mounted) {
        setState(() {
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

  List<DropdownMenuItem<String>> _buildProvinceDropdownItems() => ProvinceLookup.buildDropdownItems();

  List<Widget> _buildProvinceSelectedItems(BuildContext context) {
    return _buildProvinceDropdownItems().map((item) {
      if (item.value?.startsWith('HEADER_') == true) return const SizedBox.shrink();
      if (item.value == 'All') return const Align(alignment: Alignment.centerLeft, child: Text('All Provinces', style: TextStyle(fontSize: 12)));
      final prov = item.value!;
      return Align(
        alignment: Alignment.centerLeft,
        child: Text(
          prov,
          style: const TextStyle(fontSize: 12),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      );
    }).toList();
  }

  String _getProvinceForObservation(LatLng point) => ProvinceLookup.provinceForPoint(point.latitude, point.longitude);

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

      // Fetch current user's profile to check role
      final currentUserProfile = await Supabase.instance.client
          .from('users')
          .select('role')
          .eq('user_id', user.id)
          .maybeSingle();
      
      if (currentUserProfile != null) {
        _currentUserRole = currentUserProfile['role']?.toString().toUpperCase();
      }

      // Fetch dataset authors profiles separately
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
    return Supabase.instance.client.storage.from('datasets').getPublicUrl(dataset['filepath']);
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

  Future<void> _showRegionInfoSheet(Map<String, dynamic> properties) async {
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

    return showModalBottomSheet(
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
                  const Icon(Icons.location_on, color: Colors.green),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16), overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
              const Divider(height: 20),
              if (_showKriging) ...[
                const Text("Gall Rust Spread Mapper", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.grey)),
                if (krigingSeverity != 'N/A')
                  Text('Severity: $krigingSeverity% (${_getSeverityClass(double.tryParse(krigingSeverity) ?? 0)})', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: _getSeverityColor(double.tryParse(krigingSeverity) ?? 0)))
                else
                  const Text('No data available.', style: TextStyle(fontSize: 13)),
                if (_showCA) const SizedBox(height: 12),
              ],
              if (_showCA) ...[
                const Text("Gall Rust Spread Forecast", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.grey)),
                if (caSeverity != 'N/A') ...[
                  Text('Before (Current): ${krigingSeverity == 'N/A' ? 'N/A' : '$krigingSeverity% (${_getSeverityClass(double.tryParse(krigingSeverity) ?? 0)})'}', style: TextStyle(fontSize: 13, fontWeight: krigingSeverity == 'N/A' ? FontWeight.normal : FontWeight.bold, color: krigingSeverity == 'N/A' ? Colors.black87 : _getSeverityColor(double.tryParse(krigingSeverity) ?? 0))),
                  Text('After (Step $_caSteps): $caSeverity% (${_getSeverityClass(double.tryParse(caSeverity) ?? 0)})', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: _getSeverityColor(double.tryParse(caSeverity) ?? 0))),
                ] else
                  const Text('No data available.', style: TextStyle(fontSize: 13)),
              ],
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }

  void _showToast(String message, {bool isError = true}) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(
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
              onPressed: () => messenger.hideCurrentSnackBar(),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              splashRadius: 16.0,
            ),
          ],
        ),
        backgroundColor: isError ? Colors.red[800] : Colors.green[800],
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12.0)),
        margin: const EdgeInsets.all(16.0),
      ),
    );
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
        });
      } else {
        debugPrint("API Error: ${response.statusCode} ${response.body}");
        _showToast('Failed to load plantation points (${response.statusCode}).');
      }
    } catch (e) {
      debugPrint("Connection error: $e");
      _showToast('Could not reach the spatial engine: $e');
    } finally {
      setState(() => _isPlantationsLoading = false);
    }
  }

  List<Marker> _buildPlantationMarkers() {
    final filtered = _plantationsData.where((p) {
      final lat = double.tryParse(p['latitude'].toString()) ?? 0.0;
      final lng = double.tryParse(p['longitude'].toString()) ?? 0.0;
      final severity = double.tryParse((p['GSI'] ?? p['severity_index_pct'] ?? 0.0).toString()) ?? 0.0;
      
      if (_selectedPlantationSeverity != 'All' && _getSeverityClass(severity) != _selectedPlantationSeverity) return false;
      if (_selectedPlantationProvince != 'All' && _getProvinceForObservation(LatLng(lat, lng)) != _selectedPlantationProvince) return false;
      
      return true;
    }).toList();

    return filtered.map((p) {
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

  // --- Observation Fetching ---
  Future<void> _fetchObservations() async {
    debugPrint('[OBS] _fetchObservations() called');
    try {
      final response = await Supabase.instance.client
          .from('observations')
          .select('*, users!observations_user_id_fkey(user_name, role, avatar_url), verifier:users!observations_verifier_id_fkey(user_name)')
          .order('observation_timestamp', ascending: false);

      if (mounted) {
        final rawData = List<Map<String, dynamic>>.from(response);
        setState(() {
          _observationsData = rawData.where((obs) {
            if (obs['is_deleted'] == true) return false;
            if (obs['is_public'] != true) return false;
            if (obs['verification_result'] == 'REJECTED') return false;
            return true;
          }).toList();
        });
      }
      debugPrint('[OBS] fetched ${_observationsData.length} observations');
    } catch (e) {
      debugPrint('[OBS] ERROR fetching observations: $e');
    }
  }

  Future<void> _applyHighlightedObservation() async {
    final rawObs = widget.highlightObservation;
    if (rawObs == null || !mounted) return;

    Map<String, dynamic> obs = rawObs;
    final id = rawObs['observation_id'] ?? rawObs['id'];
    final currentUser = Supabase.instance.client.auth.currentUser;

    // The obs passed in from "My Observations" doesn't include the joined
    // owner profile (it's always the current user's own, so it's normally
    // omitted). Attach it here so the map popup doesn't show "Unknown User".
    if (rawObs['users'] == null && currentUser != null && NetworkService.instance.isOnline) {
      try {
        final profile = await Supabase.instance.client
            .from('users')
            .select('user_name, role, avatar_url')
            .eq('user_id', currentUser.id)
            .maybeSingle();
        if (profile != null) {
          obs = {...rawObs, 'users': profile};
        }
      } catch (e) {
        debugPrint('[OBS] highlight profile fetch error: $e');
      }
    }

    if (!mounted) return;

    final alreadyPresent = _observationsData.any((o) => (o['observation_id'] ?? o['id']) == id);
    if (!alreadyPresent) {
      setState(() {
        _observationsData = [..._observationsData, obs];
      });
    } else if (obs['users'] != null) {
      setState(() {
        _observationsData = _observationsData
            .map((o) => (o['observation_id'] ?? o['id']) == id ? obs : o)
            .toList();
      });
    }

    final coords = _parseCoordinates(obs['coordinates']);
    final double? lat = obs['latitude'] != null ? double.tryParse(obs['latitude'].toString()) : coords?['lat'];
    final double? lng = obs['longitude'] != null ? double.tryParse(obs['longitude'].toString()) : coords?['lng'];
    if (lat == null || lng == null) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _mapController.move(LatLng(lat, lng), 17);
      setState(() {
        _highlightedLatLng = LatLng(lat, lng);
      });
      _highlightPulseController
        ..reset()
        ..repeat();
      _showObservationInfoSheet(obs);
    });
  }

  Map<String, double>? _parseCoordinates(dynamic coords) {
    if (coords == null) return null;
    if (coords is Map) {
      final map = coords.cast<String, dynamic>();
      final list = map['coordinates'];
      if (list is List && list.length >= 2) {
        return {'lat': (list[1] as num).toDouble(), 'lng': (list[0] as num).toDouble()};
      }
    } else if (coords is String) {
      if (coords.toUpperCase().startsWith('POINT(')) {
        final inner = coords.substring(6, coords.length - 1).split(' ');
        if (inner.length >= 2) {
          final lng = double.tryParse(inner[0]);
          final lat = double.tryParse(inner[1]);
          if (lat != null && lng != null) return {'lat': lat, 'lng': lng};
        }
      }
      // EWKB hex from PostGIS
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

  Map<String, double>? _parseEWKBHex(String hex) {
    final bytes = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < hex.length; i += 2) {
      bytes[i ~/ 2] = int.parse(hex.substring(i, i + 2), radix: 16);
    }
    final byteData = ByteData.view(bytes.buffer);
    final byteOrder = bytes[0];
    final endian = byteOrder == 1 ? Endian.little : Endian.big;
    final geomType = byteData.getUint32(1, endian);
    final hasSRID = (geomType & 0x20000000) != 0;
    final coordOffset = hasSRID ? 9 : 5;
    final lng = byteData.getFloat64(coordOffset, endian);
    final lat = byteData.getFloat64(coordOffset + 8, endian);
    return {'lat': lat, 'lng': lng};
  }

  bool _isObservationInProvince(Map<String, dynamic> obs, String province) {
    if (province == 'All') return true;
    final coords = _parseCoordinates(obs['coordinates']);
    final double lat = obs['latitude'] != null ? double.tryParse(obs['latitude'].toString()) ?? (coords?['lat'] ?? 0.0) : (coords?['lat'] ?? 0.0);
    final double lng = obs['longitude'] != null ? double.tryParse(obs['longitude'].toString()) ?? (coords?['lng'] ?? 0.0) : (coords?['lng'] ?? 0.0);
    return ProvinceLookup.provinceForPoint(lat, lng) == province;
  }

  List<Marker> _buildObservationMarkers() {
    final filtered = _observationsData.where((obs) {
      if (obs['is_deleted'] == true) return false;
      final isVerified = obs['verification_result'] == 'APPROVED' || obs['verification_result'] == 'REJECTED';
      if (_selectedObservationVerification == 'Verified' && !isVerified) return false;
      if (_selectedObservationVerification == 'Unverified' && isVerified) return false;

      final role = obs['users'] != null && obs['users'] is Map
          ? (obs['users'] as Map)['role']?.toString().toUpperCase()
          : null;
      final isExpert = role == 'EXPERT';
      if (_selectedObservationUserRole == 'Expert' && !isExpert) return false;
      if (_selectedObservationUserRole == 'Community' && isExpert) return false;

      if (_showMyObservationsOnly && obs['user_id'] != Supabase.instance.client.auth.currentUser?.id) return false;

      if (_hideAnonymousObservations &&
          obs['is_anonymous'] == true &&
          obs['user_id'] != Supabase.instance.client.auth.currentUser?.id) {
        return false;
      }

      if (_observationStartDate != null || _observationEndDate != null) {
        final obsDateStr = obs['observation_timestamp'] as String?;
        if (obsDateStr != null) {
          final obsDate = DateTime.tryParse(obsDateStr);
          if (obsDate != null) {
            if (_observationStartDate != null && obsDate.isBefore(_observationStartDate!)) return false;
            if (_observationEndDate != null && obsDate.isAfter(_observationEndDate!.add(const Duration(days: 1)))) return false;
          }
        }
      }

      return _isObservationInProvince(obs, _selectedObservationProvince);
    }).toList();

    return filtered.map((obs) {
      final coords = _parseCoordinates(obs['coordinates']);
      final double lat = obs['latitude'] != null ? double.tryParse(obs['latitude'].toString()) ?? (coords?['lat'] ?? 0.0) : (coords?['lat'] ?? 0.0);
      final double lng = obs['longitude'] != null ? double.tryParse(obs['longitude'].toString()) ?? (coords?['lng'] ?? 0.0) : (coords?['lng'] ?? 0.0);
      final confidence = double.tryParse(obs['confidence_score']?.toString() ?? '') ?? 0.0;
      final isVerified = obs['verification_result'] == 'APPROVED' || obs['verification_result'] == 'REJECTED';

      Color color;
      if (confidence >= 80.0) {
        color = const Color(0xFFF44336);
      } else if (confidence >= 60.0) {
        color = const Color(0xFFFF9800);
      } else if (confidence >= 40.0) {
        color = const Color(0xFFFFEB3B);
      } else {
        color = const Color(0xFF4CAF50);
      }

      return Marker(
        point: LatLng(lat, lng),
        width: 24,
        height: 24,
        child: GestureDetector(
          onTap: () => _showObservationInfoSheet(obs),
          child: Container(
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.rectangle,
              borderRadius: isVerified ? BorderRadius.circular(6) : null,
              border: Border.all(color: Colors.white, width: 2),
              boxShadow: const [
                BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 2))
              ],
            ),
            child: isVerified
              ? const Icon(Icons.star, size: 14, color: Colors.white)
              : const Icon(Icons.warning_amber_rounded, size: 14, color: Colors.white),
          ),
        ),
      );
    }).toList();
  }

  void _showObservationInfoSheet(Map<String, dynamic> obs) {
    final coords = _parseCoordinates(obs['coordinates']);
    final lat = coords?['lat'] ?? 0.0;
    final lng = coords?['lng'] ?? 0.0;
    final isOwner = obs['user_id'] == Supabase.instance.client.auth.currentUser?.id;
    final province = _getProvinceForObservation(LatLng(lat, lng));
    final isVerified = obs['verification_result'] == 'APPROVED' || obs['verification_result'] == 'REJECTED';
    final rawTimestamp = obs['observation_timestamp'];
    final rawDate = rawTimestamp != null ? DateTime.tryParse(rawTimestamp.toString()) : null;
    final date = rawDate != null ? DateFormat.yMMMd().add_jm().format(rawDate.toLocal()) : 'Unknown Date';
    final imageUrl = obs['image_url']?.toString();
    final remarks = obs['remarks']?.toString() ?? 'No remarks provided.';

    final isAnonymous = obs['is_anonymous'] == true;
    final contributorName = (isAnonymous && !isOwner)
        ? 'Anonymous Scout'
        : (obs['users'] != null && obs['users'] is Map
            ? (obs['users'] as Map)['user_name']?.toString() ?? 'Unknown User'
            : 'Unknown User');
    final role = obs['users'] != null && obs['users'] is Map
        ? (obs['users'] as Map)['role']?.toString().toUpperCase()
        : null;
    final isExpert = role == 'EXPERT';
    final avatarUrl = (isAnonymous && !isOwner)
        ? null
        : (obs['users'] != null && obs['users'] is Map
            ? (obs['users'] as Map)['avatar_url']?.toString()
            : null);
    
    final verifierName = obs['verifier'] != null && obs['verifier'] is Map
        ? (obs['verifier'] as Map)['user_name']?.toString()
        : 'Unknown Expert';
    final rawVerification = obs['verification_timestamp'] != null ? DateTime.tryParse(obs['verification_timestamp']) : null;
    final verificationDate = rawVerification != null ? DateFormat.yMMMd().add_jm().format(rawVerification.toLocal()) : 'Unknown Date';
    final verificationResult = obs['verification_result']?.toString();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24.0)),
      ),
      builder: (context) {
        return SafeArea(
          child: SingleChildScrollView(
            child: Padding(
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
                  Icon(Icons.person_pin_circle, color: Colors.blue[700]),
                  const SizedBox(width: 8),
                  const Text("Field Observation", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                ],
              ),
              const Divider(height: 20),
              if (imageUrl != null && imageUrl.isNotEmpty) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.network(imageUrl, height: 140, width: double.infinity, fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) => const SizedBox(height: 140, child: Center(child: Icon(Icons.broken_image, color: Colors.grey))),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              Row(
                children: [
                  Icon(isVerified ? Icons.verified : Icons.pending, size: 16, color: isVerified ? Colors.blue : Colors.orange),
                  const SizedBox(width: 4),
                  Text(isVerified ? "Verified" : "Unverified", style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: isVerified ? Colors.blue : Colors.orange)),
                ],
              ),
              if (isVerified) ...[
                const SizedBox(height: 4),
                Text("Verified by: $verifierName", style: const TextStyle(fontSize: 12, color: Colors.blue)),
                Text("Verification Timestamp: $verificationDate", style: const TextStyle(fontSize: 12, color: Colors.blue)),
              ],
              if (!isVerified && verificationResult == 'FAILED') ...[
                const SizedBox(height: 4),
                const Text("Verification Rejected", style: TextStyle(fontSize: 12, color: Colors.red, fontWeight: FontWeight.bold)),
              ],
              const SizedBox(height: 4),
              Row(
                children: [
                  if (avatarUrl != null && avatarUrl.isNotEmpty)
                    CircleAvatar(radius: 8, backgroundImage: NetworkImage(avatarUrl))
                  else
                    const Icon(Icons.person, size: 14, color: Colors.grey),
                  const SizedBox(width: 4),
                  Text(contributorName, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                  if (isAnonymous && isOwner) ...[
                    const SizedBox(width: 4),
                    Icon(Icons.visibility_off_rounded, size: 13, color: Colors.purple[700]),
                  ],
                  if (isExpert) ...[
                    const SizedBox(width: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                      decoration: BoxDecoration(color: Colors.blue.shade100, borderRadius: BorderRadius.circular(4)),
                      child: Text('EXPERT', style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.blue.shade900)),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 4),
              Text("Observation Timestamp: $date", style: const TextStyle(fontSize: 13)),
              Text("Province: $province", style: const TextStyle(fontSize: 13)),
              if (isOwner)
                Text("Lat/Lng: ${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}", style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 8),

              (() {
                final hasRemarks = remarks.trim().isNotEmpty;
                final isPending = obs['under_verification'] == true || obs['verification_result'] == 'PENDING';
                
                bool shouldShowRemarksSection = false;
                if (hasRemarks) {
                  shouldShowRemarksSection = true;
                } else if (isPending) {
                  shouldShowRemarksSection = true;
                }

                if (shouldShowRemarksSection) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text("Remarks", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.grey)),
                      if (hasRemarks)
                        Text(remarks, style: const TextStyle(fontSize: 13))
                      else
                        const Text('Remarks are hidden until verified.', style: TextStyle(fontSize: 13, color: Colors.grey, fontStyle: FontStyle.italic)),
                    ],
                  );
                }
                return const SizedBox.shrink();
              })(),
              
              if (isOwner) ...[
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () {
                      Navigator.pop(context); // Close bottom sheet
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => ObservationDetailsPage(
                            obs: obs,
                            isCached: false,
                          ),
                        ),
                      ).then((result) {
                        if (result != null) {
                          _fetchObservations();
                        }
                      });
                    },
                    icon: const Icon(Icons.info_outline),
                    label: const Text('View Details'),
                  ),
                ),
              ],
            ],
          ),
            ),
          ),
        );
      },
    ).whenComplete(() {
      if (!mounted) return;
      _highlightPulseController.stop();
      setState(() {
        _highlightedLatLng = null;
      });
    });
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
        debugPrint("API Error: ${response.statusCode} ${response.body}");
        _showToast('Failed to load spread mapper data (${response.statusCode}).');
      }
    } catch (e) {
      debugPrint("Connection error: $e");
      _showToast('Could not reach the spatial engine: $e');
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
        debugPrint("API Error: ${response.statusCode} ${response.body}");
        _showToast('Failed to load forecast data (${response.statusCode}).');
      }
    } catch (e) {
      debugPrint("Connection error: $e");
      _showToast('Could not reach the spatial engine: $e');
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
                            height: 200,
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.grey.shade400),
                              borderRadius: BorderRadius.circular(8),
                              color: Colors.white,
                            ),
                            child: _filteredDatasets.isEmpty 
                              ? const Center(child: Text("No datasets found", style: TextStyle(color: Colors.grey, fontSize: 12)))
                              : ListView.builder(
                                  itemCount: _filteredDatasets.length,
                                  itemBuilder: (context, index) {
                                    final dataset = _filteredDatasets[index];
                                    final isSelected = _selectedDataset != null && _selectedDataset!['filepath'] == dataset['filepath'];
                                    final isOwner = dataset['user_id'] == Supabase.instance.client.auth.currentUser?.id;
                                    final uploaderName = dataset['users'] != null && dataset['users'] is Map
                                        ? (dataset['users'] as Map)['user_name']?.toString() ?? 'Unknown User'
                                        : 'Unknown User';
                                    final dateStr = dataset['created_at'] != null ? DateTime.tryParse(dataset['created_at'].toString())?.toString().split(' ')[0] ?? '' : '';
                                    
                                    return Card(
                                      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                      color: isSelected ? Colors.green.shade100 : Colors.white,
                                      elevation: isSelected ? 2 : 0,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(6),
                                        side: BorderSide(color: isSelected ? Colors.green.shade600 : Colors.grey.shade200),
                                      ),
                                      child: ListTile(
                                        dense: true,
                                        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                                        title: Row(
                                          children: [
                                            Expanded(child: Text(dataset['filename'] ?? 'Dataset', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold), overflow: TextOverflow.ellipsis)),
                                            const SizedBox(width: 4),
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                              decoration: BoxDecoration(
                                                color: dataset['is_public'] == true ? Colors.green.shade50 : Colors.grey.shade100,
                                                borderRadius: BorderRadius.circular(4),
                                                border: Border.all(color: dataset['is_public'] == true ? Colors.green.shade200 : Colors.grey.shade300),
                                              ),
                                              child: Text(
                                                dataset['is_public'] == true ? 'Public' : 'Private',
                                                style: TextStyle(fontSize: 9, color: dataset['is_public'] == true ? Colors.green.shade700 : Colors.grey.shade700, fontWeight: FontWeight.bold),
                                              ),
                                            ),
                                          ],
                                        ),
                                        subtitle: Text('By: $uploaderName • $dateStr', style: const TextStyle(fontSize: 10)),
                                        trailing: isOwner 
                                          ? const Icon(Icons.star, size: 14, color: Colors.orange)
                                          : const Icon(Icons.public, size: 14, color: Colors.grey),
                                        onTap: () {
                                          _onDatasetSelected(dataset);
                                          setModalState(() {});
                                        },
                                      ),
                                    );
                                  },
                                ),
                          ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          if (_currentUserRole == 'EXPERT')
                            Expanded(
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8),
                                decoration: BoxDecoration(
                                  border: Border.all(color: Colors.grey.shade300),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: DropdownButtonHideUnderline(
                                  child: DropdownButton<String>(
                                    isExpanded: true,
                                    value: _datasetVisibilityFilter,
                                    items: ['All', 'Public', 'Private'].map((v) => DropdownMenuItem(value: v, child: Text(v, style: const TextStyle(fontSize: 12)))).toList(),
                                    onChanged: (val) {
                                      if (val != null) {
                                        setModalState(() => _datasetVisibilityFilter = val);
                                        setState(() => _datasetVisibilityFilter = val);
                                      }
                                    },
                                  ),
                                ),
                              ),
                            ),
                          if (_currentUserRole == 'EXPERT')
                            const SizedBox(width: 8),
                          Expanded(
                            child: OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 4), 
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                side: BorderSide(color: Colors.grey.shade300),
                              ),
                              onPressed: () async {
                                final date = await showDatePicker(
                                  context: context,
                                  initialDate: _datasetStartDate ?? DateTime.now(),
                                  firstDate: DateTime(2000),
                                  lastDate: DateTime.now(),
                                );
                                if (date != null) {
                                  setModalState(() => _datasetStartDate = date);
                                  setState(() => _datasetStartDate = date);
                                }
                              },
                              child: Text(_datasetStartDate != null ? _datasetStartDate!.toString().split(' ')[0] : 'Start Date', style: const TextStyle(fontSize: 12)),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 4), 
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                side: BorderSide(color: Colors.grey.shade300),
                              ),
                              onPressed: () async {
                                final date = await showDatePicker(
                                  context: context,
                                  initialDate: _datasetEndDate ?? DateTime.now(),
                                  firstDate: DateTime(2000),
                                  lastDate: DateTime.now(),
                                );
                                if (date != null) {
                                  setModalState(() => _datasetEndDate = date);
                                  setState(() => _datasetEndDate = date);
                                }
                              },
                              child: Text(_datasetEndDate != null ? _datasetEndDate!.toString().split(' ')[0] : 'End Date', style: const TextStyle(fontSize: 12)),
                            ),
                          ),
                          if (_datasetStartDate != null || _datasetEndDate != null) ...[
                            const SizedBox(width: 4),
                            IconButton(
                              icon: const Icon(Icons.clear, size: 16),
                              onPressed: () {
                                setModalState(() { _datasetStartDate = null; _datasetEndDate = null; });
                                setState(() { _datasetStartDate = null; _datasetEndDate = null; });
                              },
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                            ),
                          ],
                        ],
                      ),
                      if (_currentUserRole == 'EXPERT')
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text("My Datasets Only", style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                          value: _showMyDatasetsOnly,
                          activeTrackColor: Colors.green.shade200,
                          activeThumbColor: Colors.green.shade700,
                          onChanged: (val) {
                            setModalState(() => _showMyDatasetsOnly = val);
                            setState(() {
                              _showMyDatasetsOnly = val;
                              _selectedDataset = null;
                              _showCA = false;
                              _showKriging = false;
                              _showPlantations = false;
                              _caPolygons.clear();
                              _krigingPolygons.clear();
                              _plantationsData.clear();
                            });
                          },
                        ),
                      if (_currentUserRole == 'EXPERT')
                        Padding(
                          padding: const EdgeInsets.only(top: 8.0),
                          child: Text(
                            'Note: Uploading and deletion of datasets can be done using the Commander web app.',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey[700],
                              fontStyle: FontStyle.italic,
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
                      ExpansionTile(
                        tilePadding: const EdgeInsets.only(left: 16, right: 8),
                        title: const Text("Plantation Points", style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                        leading: Icon(Icons.location_on, color: _showPlantations ? Colors.green.shade700 : Colors.grey),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Switch(
                              value: _showPlantations,
                              activeTrackColor: Colors.green.shade700,
                              onChanged: _selectedDataset == null ? null : (val) {
                                setModalState(() {
                                  _showPlantations = val;
                                });
                                setState(() {
                                  _showPlantations = val;
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
                          setModalState(() {
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
                            items: _buildProvinceDropdownItems(),
                            selectedItemBuilder: _buildProvinceSelectedItems,
                            onChanged: (val) {
                              if (val != null) {
                                setModalState(() {
                                  _selectedPlantationProvince = val;
                                });
                                setState(() {
                                  _selectedPlantationProvince = val;
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
                                setModalState(() {
                                  _selectedPlantationSeverity = val;
                                });
                                setState(() {
                                  _selectedPlantationSeverity = val;
                                });
                              }
                            },
                          ),
                        ],
                      ),
                      ExpansionTile(
                        tilePadding: const EdgeInsets.only(left: 16, right: 8),
                        title: Row(
                          children: [
                            const Expanded(
                              child: Text(
                                "Gall Rust Spread\nForecast",
                                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                              ),
                            ),
                            const SizedBox(width: 4),
                            Tooltip(
                              message: '⚠️ The step count has not yet been\ncalibrated to a specific time period.\nEach step is a simulation iteration,\nnot a day, week, or month.',
                              child: Icon(Icons.info_outline, size: 16, color: Colors.amber[700]),
                            ),
                            if (_isCaLoading) ...[
                              const SizedBox(width: 12),
                              const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                            ],
                          ],
                        ),
                        leading: Icon(Icons.online_prediction, color: _showCA ? Colors.green.shade700 : Colors.grey),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Switch(
                              value: _showCA,
                              activeTrackColor: Colors.green.shade700,
                              onChanged: _selectedDataset == null ? null : (val) {
                                setModalState(() {
                                  _showCA = val;
                                });
                                setState(() {
                                  _showCA = val;
                                });
                              },
                            ),
                            Icon(
                              _isCaExpanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                              color: Colors.grey,
                            ),
                          ],
                        ),
                        onExpansionChanged: (expanded) {
                          setModalState(() {
                            _isCaExpanded = expanded;
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
                          // Forecast Step Slider
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Row(
                                children: [
                                  const Text("Forecast Steps:", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                                  const SizedBox(width: 4),
                                  Tooltip(
                                    message: "A 'step' represents a mathematical cycle of spread.",
                                    child: Icon(Icons.info_outline, size: 14, color: Colors.grey.shade600),
                                  ),
                                ],
                              ),
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
                      ),
                      
                      ExpansionTile(
                        tilePadding: const EdgeInsets.only(left: 16, right: 8),
                        title: const Text("Gall Rust Spread\nMapper", style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                        leading: Icon(Icons.grain, color: _showKriging ? Colors.green.shade700 : Colors.grey),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Switch(
                              value: _showKriging,
                              activeTrackColor: Colors.green.shade700,
                              onChanged: _selectedDataset == null ? null : (val) {
                                setModalState(() {
                                  _showKriging = val;
                                });
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
                          setModalState(() {
                            _isKrigingExpanded = expanded;
                          });
                        },
                        childrenPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        children: [
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
                        ],
                      ),

                      // --- Field Observations ---
                      ExpansionTile(
                        tilePadding: const EdgeInsets.only(left: 16, right: 8),
                        title: const Text("Field Observations", style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                        leading: Icon(Icons.person_pin_circle, color: _showObservations ? Colors.blue.shade700 : Colors.grey),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Switch(
                              value: _showObservations,
                              activeTrackColor: Colors.blue.shade700,
                              onChanged: (val) {
                                setModalState(() {
                                  _showObservations = val;
                                });
                                setState(() {
                                  _showObservations = val;
                                });
                                if (val && _observationsData.isEmpty) {
                                  _fetchObservations();
                                }
                              },
                            ),
                            Icon(
                              _isObservationsExpanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                              color: Colors.grey,
                            ),
                          ],
                        ),
                        onExpansionChanged: (expanded) {
                          setModalState(() {
                            _isObservationsExpanded = expanded;
                          });
                        },
                        childrenPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        children: [
                          const Align(
                            alignment: Alignment.centerLeft,
                            child: Text("Filter by Verification:", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                          ),
                          const SizedBox(height: 4),
                          DropdownButton<String>(
                            isExpanded: true,
                            value: _selectedObservationVerification,
                            items: _availableVerificationStatuses.map((stat) {
                              return DropdownMenuItem(
                                value: stat,
                                child: Text(stat, style: const TextStyle(fontSize: 12)),
                              );
                            }).toList(),
                            onChanged: (val) {
                              if (val != null) {
                                setModalState(() => _selectedObservationVerification = val);
                                setState(() => _selectedObservationVerification = val);
                              }
                            },
                          ),
                          const SizedBox(height: 12),
                          const Align(
                            alignment: Alignment.centerLeft,
                            child: Text("Filter by User Role:", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                          ),
                          const SizedBox(height: 4),
                          DropdownButton<String>(
                            isExpanded: true,
                            value: _selectedObservationUserRole,
                            items: _availableUserRoles.map((role) {
                              return DropdownMenuItem(
                                value: role,
                                child: Text(role, style: TextStyle(fontSize: 12, color: _showMyObservationsOnly ? Colors.grey : Colors.black87)),
                              );
                            }).toList(),
                            onChanged: _showMyObservationsOnly ? null : (val) {
                              if (val != null) {
                                setModalState(() => _selectedObservationUserRole = val);
                                setState(() => _selectedObservationUserRole = val);
                              }
                            },
                          ),
                          const SizedBox(height: 12),
                          const Align(
                            alignment: Alignment.centerLeft,
                            child: Text("Filter by Province:", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                          ),
                          const SizedBox(height: 4),
                          DropdownButton<String>(
                            isExpanded: true,
                            value: _selectedObservationProvince,
                            items: _buildProvinceDropdownItems(),
                            selectedItemBuilder: _buildProvinceSelectedItems,
                            onChanged: (val) {
                              if (val != null) {
                                setModalState(() => _selectedObservationProvince = val);
                                setState(() => _selectedObservationProvince = val);
                              }
                            },
                          ),
                          const SizedBox(height: 12),
                          const Align(
                            alignment: Alignment.centerLeft,
                            child: Text("Filter by Date Interval:", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton(
                                  style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 4), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4))),
                                  onPressed: () async {
                                    final date = await showDatePicker(
                                      context: context,
                                      initialDate: _observationStartDate ?? DateTime.now(),
                                      firstDate: DateTime(2000),
                                      lastDate: DateTime.now(),
                                    );
                                    if (date != null) {
                                      setModalState(() => _observationStartDate = date);
                                      setState(() => _observationStartDate = date);
                                    }
                                  },
                                  child: Text(_observationStartDate != null ? _observationStartDate!.toString().split(' ')[0] : 'Start Date', style: const TextStyle(fontSize: 11)),
                                ),
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: OutlinedButton(
                                  style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 4), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4))),
                                  onPressed: () async {
                                    final date = await showDatePicker(
                                      context: context,
                                      initialDate: _observationEndDate ?? DateTime.now(),
                                      firstDate: DateTime(2000),
                                      lastDate: DateTime.now(),
                                    );
                                    if (date != null) {
                                      setModalState(() => _observationEndDate = date);
                                      setState(() => _observationEndDate = date);
                                    }
                                  },
                                  child: Text(_observationEndDate != null ? _observationEndDate!.toString().split(' ')[0] : 'End Date', style: const TextStyle(fontSize: 11)),
                                ),
                              ),
                              if (_observationStartDate != null || _observationEndDate != null) ...[
                                const SizedBox(width: 4),
                                IconButton(
                                  icon: const Icon(Icons.clear, size: 16),
                                  onPressed: () {
                                    setModalState(() { _observationStartDate = null; _observationEndDate = null; });
                                    setState(() { _observationStartDate = null; _observationEndDate = null; });
                                  },
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 12),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text("My Observations Only", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                            value: _showMyObservationsOnly,
                            onChanged: (val) {
                              setModalState(() {
                                _showMyObservationsOnly = val;
                                if (val) _selectedObservationUserRole = 'All';
                              });
                              setState(() {
                                _showMyObservationsOnly = val;
                                if (val) _selectedObservationUserRole = 'All';
                              });
                            },
                          ),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text("Hide Anonymous Observations", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                            value: _hideAnonymousObservations,
                            onChanged: (val) {
                              setModalState(() {
                                _hideAnonymousObservations = val;
                              });
                              setState(() {
                                _hideAnonymousObservations = val;
                              });
                            },
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
              if (_showCA) ...[
                const Divider(height: 20),
                const Text("Gall Rust Spread Forecast", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.grey)),
                Builder(builder: (context) {
                  final lat = double.tryParse(p['latitude'].toString()) ?? 0.0;
                  final lng = double.tryParse(p['longitude'].toString()) ?? 0.0;
                  final forecasted = _getCAForecastForPoint(LatLng(lat, lng));
                  if (forecasted != null) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Before (Current): ${isGsiValid ? '$gsiStr% (${_getSeverityClass(gsiVal)})' : 'N/A'}', style: TextStyle(fontSize: 13, fontWeight: isGsiValid ? FontWeight.bold : FontWeight.normal, color: isGsiValid ? _getSeverityColor(gsiVal) : Colors.black87)),
                        Text('After (Step $_caSteps): $forecasted% (${_getSeverityClass(forecasted)})', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: _getSeverityColor(forecasted))),
                      ],
                    );
                  }
                  return const Text("No forecast available for this point.", style: TextStyle(fontSize: 13, color: Colors.grey));
                }),
              ],
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
                        onTap: (tapPosition, point) {
                          final List<Polygon> activePolygons = _showCA ? _caPolygons : (_showKriging ? _krigingPolygons : []);
                          bool found = false;
                          for (var poly in activePolygons) {
                            if (_isPointInPolygon(point, poly.points)) {
                              final props = poly.hitValue as Map<String, dynamic>?;
                              if (props != null) {
                                setState(() {
                                  _selectedRegionProps = props;
                                });
                                _showRegionInfoSheet(props).whenComplete(() {
                                  if (mounted) {
                                    setState(() {
                                      _selectedRegionProps = null;
                                    });
                                  }
                                });
                                found = true;
                                break;
                              }
                            }
                          }
                          if (!found && _selectedRegionProps != null) {
                            setState(() {
                              _selectedRegionProps = null;
                            });
                          }
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



                        // Highlight layer
                        if (_selectedRegionProps != null)
                          PolygonLayer(
                            polygons: _getHighlightedPolygons(),
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

                        // Observation markers with clustering
                        if (_showObservations && _observationsData.isNotEmpty)
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

                        // Pulsing highlight ring for a programmatically focused observation,
                        // mimicking a spiderfy "unfold" reveal without disabling clustering.
                        if (_highlightedLatLng != null)
                          MarkerLayer(
                            markers: [
                              Marker(
                                point: _highlightedLatLng!,
                                width: 90,
                                height: 90,
                                alignment: Alignment.center,
                                child: IgnorePointer(
                                  child: AnimatedBuilder(
                                    animation: _highlightPulseController,
                                    builder: (context, child) {
                                      final t = _highlightPulseController.value;
                                      final scale = 0.3 + (t * 1.4);
                                      final opacity = (1 - t).clamp(0.0, 1.0);
                                      return Stack(
                                        alignment: Alignment.center,
                                        children: [
                                          Transform.scale(
                                            scale: scale,
                                            child: Container(
                                              width: 56,
                                              height: 56,
                                              decoration: BoxDecoration(
                                                shape: BoxShape.circle,
                                                color: Colors.orange.withValues(alpha: opacity * 0.45),
                                              ),
                                            ),
                                          ),
                                          Container(
                                            width: 20,
                                            height: 20,
                                            decoration: BoxDecoration(
                                              shape: BoxShape.circle,
                                              color: Colors.orange.shade700,
                                              border: Border.all(color: Colors.white, width: 3),
                                              boxShadow: const [
                                                BoxShadow(color: Colors.black38, blurRadius: 4, offset: Offset(0, 1)),
                                              ],
                                            ),
                                          ),
                                        ],
                                      );
                                    },
                                  ),
                                ),
                              ),
                            ],
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
                                              ? "Loading simulation layers..."
                                              : _isCaLoading
                                                  ? "Loading gall rust spread forecast..."
                                                  : _isKrigingLoading
                                                      ? "Loading gall rust mapper..."
                                                      : "Loading plantation points...",
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
