import 'dart:convert';
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_marker_cluster/flutter_map_marker_cluster.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'package:shared_services/shared_services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import '../widgets/observation_details_panel.dart';

const String apiBaseUrl = String.fromEnvironment(
  'PYTHON_API_URL',
  defaultValue: 'http://127.0.0.1:8000',
);

class MapPage extends StatefulWidget {
  final Map<String, dynamic>? highlightObservation;

  const MapPage({super.key, this.highlightObservation});

  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> with SingleTickerProviderStateMixin {
  final _hitNotifier = ValueNotifier<LayerHitResult<Object>?>(null);
  final _mapController = MapController();
  late final AnimationController _highlightPulseController;
  LatLng? _highlightedLatLng;

  List<Polygon> _caPolygons = [];
  List<Polygon> _krigingPolygons = [];
  // Per-plantation-point forecast values (own coordinates, not province
  // centroid), keyed by lat/lng. Used for plantation marker severity instead
  // of the coarser province-level _caPolygons lookup.
  List<Map<String, dynamic>> _caPointForecasts = [];
  bool _isCaLoading = false;
  bool _isKrigingLoading = false;
  // Incremented on every _fetchForecast/_fetchKriging call; used to discard
  // responses from superseded requests that resolve out of order (e.g. a
  // lower-step forecast request that finishes after a later, higher-step one).
  int _forecastRequestId = 0;
  int _krigingRequestId = 0;

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
  String _selectedObservationVerification = 'All';
  String _selectedObservationUserRole = 'All';
  String _selectedObservationProvince = 'All';
  String _selectedObservationSource = 'All';
  DateTime? _observationStartDate;
  DateTime? _observationEndDate;
  bool _showMyObservationsOnly = false;
  bool _showAnonymousOnly = false;

  final List<String> _availableVerificationStatuses = ['All', 'Verified', 'Pending', 'Unverified'];
  final List<String> _availableUserRoles = ['All', 'Expert', 'Community'];
  final List<String> _availableObservationSources = ['All', 'Mobile', 'Web'];
  bool _showObservations = true;
  bool _isObservationsExpanded = false;
  bool _isObservationsLoading = false;
  bool _isControlsCollapsed = false;
  List<Map<String, dynamic>> _observationsData = [];
  Map<String, dynamic>? _selectedObservation;
  String? _currentUserRole;

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

  bool _isSatellite = false;
  double _currentZoom = 6.0;
  double _currentRotation = 0.0;
  LatLng _mapCenter = const LatLng(12.8797, 121.7740);

  // Datasets state
  bool _isDatasetsLoading = false;
  bool _isUploadingDataset = false;
  List<Map<String, dynamic>> _availableDatasets = [];
  Map<String, dynamic>? _selectedDataset;
  DateTime? _datasetStartDate;
  DateTime? _datasetEndDate;
  bool _showMyDatasetsOnly = false;
  String _datasetVisibilityFilter = 'All';

  List<Map<String, dynamic>> get _filteredDatasets {
    return _availableDatasets.where((ds) {
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

  bool _isMapDragging = false;
  bool _isMapHoveringPolygon = false;
  final ValueNotifier<MouseCursor> _mapCursorNotifier = ValueNotifier(SystemMouseCursors.grab);

  void _updateMapCursor() {
    if (_isMapHoveringPolygon) {
      _mapCursorNotifier.value = SystemMouseCursors.click;
    } else if (_isMapDragging) {
      _mapCursorNotifier.value = SystemMouseCursors.grabbing;
    } else {
      _mapCursorNotifier.value = SystemMouseCursors.grab;
    }
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
          bottom: 16.0,
          right: 16.0,
          left: leftMargin,
        ),
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
    if (!_showCA || _caPointForecasts.isEmpty) return null;
    // Matches by proximity rather than exact equality, since floating point
    // values pass through CSV parsing, the backend, and JSON round-trips.
    // The backend now returns one forecast entry per exact plantation
    // coordinate (not grid-snapped), so this only needs to tolerate
    // floating-point round-trip noise -- not spatial proximity. A looser
    // epsilon here would risk matching a marker to a *different* nearby
    // plantation point's forecast.
    const epsilon = 0.000001; // ~11cm
    for (final pf in _caPointForecasts) {
      final lat = (pf['latitude'] as num?)?.toDouble();
      final lng = (pf['longitude'] as num?)?.toDouble();
      if (lat == null || lng == null) continue;
      if ((lat - point.latitude).abs() < epsilon && (lng - point.longitude).abs() < epsilon) {
        return (pf['severity_value'] as num?)?.toDouble();
      }
    }
    return null;
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
    final double lat = obs['latitude'] != null ? double.tryParse(obs['latitude'].toString()) ?? (coords?['lat'] ?? 0.0) : (coords?['lat'] ?? 0.0);
    final double lng = obs['longitude'] != null ? double.tryParse(obs['longitude'].toString()) ?? (coords?['lng'] ?? 0.0) : (coords?['lng'] ?? 0.0);
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



  Future<void> _loadPhilippinesGeoJSON() async {
    await ProvinceLookup.load();
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    BrowserContextMenu.disableContextMenu();
    _highlightPulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );

    _hitNotifier.addListener(() {
      final hitResult = _hitNotifier.value;
      final isHovering = hitResult != null && hitResult.hitValues.isNotEmpty;
      if (_isMapHoveringPolygon != isHovering) {
        _isMapHoveringPolygon = isHovering;
        _updateMapCursor();
      }
    });

    _loadPhilippinesGeoJSON();
    _fetchDatasets();
    _fetchCurrentUserRole();
    if (widget.highlightObservation != null) {
      _showObservations = true;
      _fetchObservations().then((_) => _applyHighlightedObservation());
    } else {
      _fetchObservations();
    }
  }

  Future<void> _fetchCurrentUserRole() async {
    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) return;
      final profile = await Supabase.instance.client
          .from('users')
          .select('role')
          .eq('user_id', user.id)
          .maybeSingle();
      if (mounted && profile != null) {
        setState(() {
          _currentUserRole = profile['role']?.toString().toUpperCase();
        });
      }
    } catch (_) {}
  }

  Future<void> _applyHighlightedObservation() async {
    final rawObs = widget.highlightObservation;
    if (rawObs == null || !mounted) return;

    Map<String, dynamic> obs = rawObs;
    final id = rawObs['observation_id'] ?? rawObs['id'];

    final alreadyPresent = _observationsData.any((o) => (o['observation_id'] ?? o['id']) == id);
    if (!alreadyPresent) {
      setState(() {
        _observationsData = [..._observationsData, obs];
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
        _selectedObservation = obs;
      });
      _highlightPulseController
        ..reset()
        ..repeat();
    });
  }

  Future<void> _fetchDatasets() async {
    setState(() => _isDatasetsLoading = true);
    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) return;
      
      final response = await Supabase.instance.client
          .from('datasets')
          .select('*')
          .or('is_public.eq.true,user_id.eq.${user.id}')
          .order('created_at', ascending: false);

      final datasets = List<Map<String, dynamic>>.from(response)
          .where((ds) => ds['is_deleted'] != true)
          .toList();

      // Fetch user profiles separately (no FK from datasets → public.users)
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

  Future<void> _uploadDataset() async {
    try {
      FilePickerResult? result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['csv'],
        withData: true,
      );

      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      if (file.bytes == null) {
        _showToast('Could not read file.');
        return;
      }
      
      if (file.size > 5 * 1024 * 1024) {
        _showToast('File exceeds 5MB limit.');
        return;
      }

      final firstLine = utf8.decode(file.bytes!.take(2048).toList(), allowMalformed: true).toLowerCase().split('\n').first;
      if (!firstLine.contains('latitude') || !firstLine.contains('longitude')) {
        _showToast('Invalid CSV: Missing latitude or longitude columns.');
        return;
      }

      setState(() => _isUploadingDataset = true);

      bool isPublic = false;
      String displayName = file.name;
      final currentUserId = Supabase.instance.client.auth.currentUser?.id;

      if (mounted) {
        final dialogResult = await showDialog<Map<String, dynamic>>(
          context: context,
          barrierDismissible: false,
          builder: (context) {
            bool tempIsPublic = false;
            final textController = TextEditingController();
            bool hasDuplicateError = _availableDatasets.any((ds) => ds['filename'] == file.name && ds['user_id'] == currentUserId);

            return StatefulBuilder(
              builder: (context, setStateDialog) {
                return AlertDialog(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  title: Row(
                    children: [
                      Icon(Icons.cloud_upload, color: Colors.green.shade700),
                      const SizedBox(width: 8),
                      const Text('Upload Dataset'),
                    ],
                  ),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Display Name', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                      const SizedBox(height: 8),
                      TextField(
                        controller: textController,
                        decoration: InputDecoration(
                          hintText: file.name,
                          border: const OutlineInputBorder(),
                          errorText: hasDuplicateError ? 'You have already uploaded a dataset with this name.' : null,
                          isDense: true,
                        ),
                        onChanged: (val) {
                          setStateDialog(() {
                            final effectiveName = val.trim().isEmpty ? file.name : val.trim();
                            hasDuplicateError = _availableDatasets.any((ds) => ds['filename'] == effectiveName && ds['user_id'] == currentUserId);
                          });
                        },
                      ),
                      const SizedBox(height: 16),
                      const Text('Do you want to make this dataset public? Note: Other users will be able to view this dataset, but exact coordinates will be hidden unless they are the owner.', style: TextStyle(fontSize: 13)),
                      const SizedBox(height: 12),
                      Container(
                        decoration: BoxDecoration(
                          color: Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.grey.shade300)
                        ),
                        child: SwitchListTile(
                          title: const Text('Make Public', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                          value: tempIsPublic,
                          activeTrackColor: Colors.green.shade200,
                          activeThumbColor: Colors.green.shade700,
                          onChanged: (val) => setStateDialog(() => tempIsPublic = val),
                        ),
                      ),
                    ],
                  ),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context, null), child: const Text('Cancel')),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.green.shade700, foregroundColor: Colors.white),
                      onPressed: hasDuplicateError
                          ? null
                          : () => Navigator.pop(context, {
                                'isPublic': tempIsPublic,
                                'displayName': textController.text.trim().isEmpty ? file.name : textController.text.trim(),
                              }),
                      child: const Text('Upload'),
                    ),
                  ],
                );
              },
            );
          },
        );
        if (dialogResult == null) {
          setState(() => _isUploadingDataset = false);
          return;
        }
        isPublic = dialogResult['isPublic'] as bool;
        displayName = dialogResult['displayName'] as String;
      }

      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$apiBaseUrl/api/datasets/process'),
      );
      request.files.add(http.MultipartFile.fromBytes(
        'file',
        file.bytes!,
        filename: file.name,
      ));

      final response = await request.send();
      final responseBody = await response.stream.bytesToString();
      
      if (response.statusCode != 200) {
        final decoded = json.decode(responseBody) as Map<String, dynamic>;
        final error = decoded['detail'] ?? 'Unknown error';
        _showToast('Validation failed: $error');
        setState(() => _isUploadingDataset = false);
        return;
      }

      final processedData = json.decode(responseBody) as Map<String, dynamic>;
      final csvString = processedData['csv'] as String;

      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) {
        setState(() => _isUploadingDataset = false);
        return;
      }

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final safeName = displayName.replaceAll(' ', '_');
      final path = '${user.id}/${timestamp}_$safeName';

      await Supabase.instance.client.storage.from('datasets').uploadBinary(
        path,
        Uint8List.fromList(utf8.encode(csvString)),
        fileOptions: const FileOptions(contentType: 'text/csv'),
      );

      final insertedRows = await Supabase.instance.client.from('datasets').insert({
        'user_id': user.id,
        'filename': displayName,
        'filepath': path,
        'is_public': isPublic,
      }).select('*');

      // Attach user profile to the newly inserted row
      if (insertedRows.isNotEmpty) {
        final userProfile = await Supabase.instance.client
            .from('users')
            .select('user_id, user_name, role, avatar_url')
            .eq('user_id', user.id)
            .maybeSingle();
        if (userProfile != null) {
          insertedRows.first['users'] = userProfile;
        }
      }

      if (mounted) {
        _showToast('Dataset uploaded successfully!', isError: false);
      }

      await _fetchDatasets();
      
      if (insertedRows.isNotEmpty) {
        final newDataset = insertedRows.first;
        setState(() {
          _selectedDataset = newDataset;
          _showCA = false;
          _showKriging = false;
          _showPlantations = false;
          _caPolygons.clear();
          _caPointForecasts.clear();
          _krigingPolygons.clear();
          _plantationsData.clear();
          // Ensure it's in the list if _fetchDatasets missed it due to replication lag
          if (!_availableDatasets.any((d) => d['filepath'] == newDataset['filepath'])) {
            _availableDatasets.insert(0, newDataset);
          }
        });
      }
      
    } catch (e) {
      debugPrint('Upload error: $e');
      _showToast('Error uploading: $e');
    } finally {
      if (mounted) setState(() => _isUploadingDataset = false);
    }
  }

  Future<void> _deleteDataset(Map<String, dynamic> dataset) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Dataset'),
        content: Text('Are you sure you want to delete "${dataset['filename']}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      _showToast('Deleting dataset...', isError: false);
      
      // Soft-delete database row using a secure RPC to bypass RLS check quirks
      await Supabase.instance.client
          .rpc('soft_delete_dataset', params: {'filepath': dataset['filepath']});

      setState(() {
        _availableDatasets.removeWhere((d) => d['filepath'] == dataset['filepath']);
        if (_selectedDataset != null && _selectedDataset!['filepath'] == dataset['filepath']) {
          _selectedDataset = null;
          _showCA = false;
          _showKriging = false;
          _showPlantations = false;
          _caPolygons.clear();
          _caPointForecasts.clear();
          _krigingPolygons.clear();
          _plantationsData.clear();
          _selectedRegionProps = null;
          _selectedRegionLocation = null;
          _selectedPlantation = null;
          _selectedObservation = null;
        }
      });
      _showToast('Dataset deleted successfully.', isError: false);
    } catch (e) {
      debugPrint('Delete error: $e');
      _showToast('Failed to delete: $e', isError: true);
    }
  }

  Future<void> _toggleDatasetVisibility(Map<String, dynamic> dataset, bool newValue) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Change Dataset Visibility'),
        content: Text(
          newValue
              ? 'Make "${dataset['filename']}" public? Other users will be able to view this dataset, but exact coordinates will be hidden unless they are the owner.'
              : 'Make "${dataset['filename']}" private? Other users will no longer be able to view this dataset.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green.shade700, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Proceed'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      await Supabase.instance.client
          .from('datasets')
          .update({'is_public': newValue})
          .eq('filepath', dataset['filepath']);

      setState(() {
        dataset['is_public'] = newValue;
        for (final d in _availableDatasets) {
          if (d['filepath'] == dataset['filepath']) d['is_public'] = newValue;
        }
        if (_selectedDataset != null && _selectedDataset!['filepath'] == dataset['filepath']) {
          _selectedDataset!['is_public'] = newValue;
        }
      });
      _showToast('Dataset visibility updated.', isError: false);
    } catch (e) {
      debugPrint('Visibility update error: $e');
      _showToast('Failed to update visibility: $e', isError: true);
    }
  }

  @override
  void dispose() {
    BrowserContextMenu.enableContextMenu();
    _highlightPulseController.dispose();
    super.dispose();
  }

  Future<void> _fetchObservations() async {
    debugPrint('[OBS] _fetchObservations() called');
    setState(() => _isObservationsLoading = true);
    try {
      final user = Supabase.instance.client.auth.currentUser;
      debugPrint('[OBS] Current user: ${user?.id ?? "NOT LOGGED IN"}');

      final response = await Supabase.instance.client
          .from('observations')
          .select('*, users!observations_user_id_fkey(user_name, role, avatar_url), verifier:users!observations_verifier_id_fkey(user_name)')
          .order('observation_timestamp', ascending: false);

      debugPrint('[OBS] Raw response type: ${response.runtimeType}');
      debugPrint('[OBS] Rows fetched: ${response.length}');

      if (response.isNotEmpty) {
        final first = response.first;
        debugPrint('[OBS] First row keys: ${first.keys.toList()}');
        debugPrint('[OBS] First row coordinates: ${first['coordinates']}');
        debugPrint('[OBS] First row coordinates type: ${first['coordinates'].runtimeType}');

        final parsed = _parseCoordinates(first['coordinates']);
        debugPrint('[OBS] Parsed coordinates: $parsed');
      }

      final rawData = List<Map<String, dynamic>>.from(response);
      setState(() {
        _observationsData = rawData.where((obs) {
          if (obs['is_deleted'] == true) return false;
          if (obs['is_public'] != true) return false;
          if (obs['verification_result'] == 'REJECTED') return false;
          return true;
        }).toList();
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
                    MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        onTap: () => setState(() {
                          _selectedRegionProps = null;
                          _selectedRegionLocation = null;
                        }),
                        child: const Icon(Icons.close, size: 16, color: Colors.grey),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (_showKriging) ...[
                  const Text("Gall Rust Spread Mapper", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.grey)),
                  if (krigingSeverity != 'N/A')
                    Text('Severity: $krigingSeverity% (${_getSeverityClass(double.tryParse(krigingSeverity) ?? 0)})', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: _getSeverityColor(double.tryParse(krigingSeverity) ?? 0)))
                  else
                    const Text('No data available.', style: TextStyle(fontSize: 12)),
                  if (_showCA) const SizedBox(height: 8),
                ],
                if (_showCA) ...[
                  const Text("Gall Rust Spread Forecast", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.grey)),
                  if (caSeverity != 'N/A') ...[
                    Text('Before (Current): ${krigingSeverity == 'N/A' ? 'N/A' : '$krigingSeverity% (${_getSeverityClass(double.tryParse(krigingSeverity) ?? 0)})'}', style: TextStyle(fontSize: 12, fontWeight: krigingSeverity == 'N/A' ? FontWeight.normal : FontWeight.w600, color: krigingSeverity == 'N/A' ? Colors.black87 : _getSeverityColor(double.tryParse(krigingSeverity) ?? 0))),
                    Text('After (Step $_caSteps): $caSeverity% (${_getSeverityClass(double.tryParse(caSeverity) ?? 0)})', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: _getSeverityColor(double.tryParse(caSeverity) ?? 0))),
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
  Future<void> _fetchPlantations(String datasetUrl) async {
    setState(() {
      _isPlantationsLoading = true;
    });
    try {
      final response = await http.get(
        Uri.parse('$apiBaseUrl/api/plantations?dataset_url=${Uri.encodeComponent(datasetUrl)}'),
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
      
      final groundTruthSeverity = double.tryParse((p['GSI'] ?? p['severity_index_pct'] ?? 0.0).toString()) ?? 0.0;
      final forecastedSeverity = _getCAForecastForPoint(LatLng(lat, lng));
      final severity = forecastedSeverity ?? groundTruthSeverity;
      
      if (_selectedPlantationSeverity != 'All' && _getSeverityClass(severity) != _selectedPlantationSeverity) return false;
      if (_selectedPlantationProvince != 'All' && _getProvinceForObservation(LatLng(lat, lng)) != _selectedPlantationProvince) return false;
      return true;
    }).toList();

    return filtered.map((p) {
      final lat = double.tryParse(p['latitude'].toString()) ?? 0.0;
      final lng = double.tryParse(p['longitude'].toString()) ?? 0.0;
      
      final groundTruthSeverity = double.tryParse((p['GSI'] ?? p['severity_index_pct'] ?? 0.0).toString()) ?? 0.0;
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
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
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
        ),
      );
    }).toList();
  }

  Widget _buildPlantationInfoWindow(Map<String, dynamic> p) {
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

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Card(
          elevation: 6,
          color: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Padding(
            // Extra right padding keeps content clear of the close button,
            // which is overlaid outside the scrollable area below.
            padding: const EdgeInsets.fromLTRB(12.0, 12.0, 32.0, 12.0),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(popupTitle, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                Builder(
                  builder: (context) {

                    final gsiStr = getValue(['gsi', 'severity_index_pct', 'GSI']);
                    final gsiVal = double.tryParse(gsiStr) ?? 0.0;
                    final isGsiValid = gsiStr != 'N/A';

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Divider(),
                        if (isOwner) ...[
                          Text("Lat/Lng: ${getValue(['latitude', 'lat'])}, ${getValue(['longitude', 'lng'])}", style: const TextStyle(fontSize: 12)),
                          const SizedBox(height: 4),
                        ],
                        Text("Region: ${getValue(['region', 'region_number'])}", style: const TextStyle(fontSize: 12)),
                        Text("Plantation: ${getValue(['plantation', 'plantation_id', 'plantation_number'])}", style: const TextStyle(fontSize: 12)),
                        Text("Plot Number: ${getValue(['plot', 'plot_number', 'plotnumber'])}", style: const TextStyle(fontSize: 12)),
                        Text("GRI: ${getValue(['gri', 'GRI'])}", style: const TextStyle(fontSize: 12)),
                        Text("GSI: ${isGsiValid ? '$gsiStr% (${_getSeverityClass(gsiVal)})' : 'N/A'}", 
                          style: TextStyle(
                            fontSize: 12, 
                            fontWeight: isGsiValid ? FontWeight.bold : FontWeight.normal,
                            color: isGsiValid ? _getSeverityColor(gsiVal) : Colors.black87
                          )
                        ),
                      ],
                    );
                  }
                ),
                const SizedBox(height: 8),
                if (_showCA) ...[
                  const Divider(),
                  const Text("Gall Rust Spread Forecast", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.grey)),
                  Builder(builder: (context) {
                    final lat = double.tryParse(p['latitude'].toString()) ?? 0.0;
                    final lng = double.tryParse(p['longitude'].toString()) ?? 0.0;
                    final forecasted = _getCAForecastForPoint(LatLng(lat, lng));
                    if (forecasted != null) {
                      return Text('Forecasted GSI (Step $_caSteps): $forecasted% (${_getSeverityClass(forecasted)})', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: _getSeverityColor(forecasted)));
                    }
                    return const Text("No forecast available for this point.", style: TextStyle(fontSize: 12, color: Colors.grey));
                  }),
                ],
              ],
            ),
            ),
          ),
        ),
        Positioned(
          top: 4,
          right: 4,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () => setState(() => _selectedPlantation = null),
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                child: const Icon(Icons.close, size: 16, color: Colors.grey),
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
      final isVerified = obs['verification_result'] == 'APPROVED' || obs['verification_result'] == 'REJECTED';
      final isPending = obs['under_verification'] == true || obs['verification_result'] == 'PENDING';
      if (_selectedObservationVerification == 'Verified' && !isVerified) return false;
      if (_selectedObservationVerification == 'Pending' && !isPending) return false;
      if (_selectedObservationVerification == 'Unverified' && (isVerified || isPending)) return false;

      final role = obs['users'] != null && obs['users'] is Map
          ? (obs['users'] as Map)['role']?.toString().toUpperCase()
          : null;
      final isExpert = role == 'EXPERT';
      if (_selectedObservationUserRole == 'Expert' && !isExpert) return false;
      if (_selectedObservationUserRole == 'Community' && isExpert) return false;

      if (_currentUserRole == 'EXPERT' && _selectedObservationSource != 'All') {
        final source = obs['source']?.toString().toUpperCase();
        if (source != _selectedObservationSource.toUpperCase()) return false;
      }

      if (_showMyObservationsOnly && obs['user_id'] != Supabase.instance.client.auth.currentUser?.id) return false;

      if (_showAnonymousOnly && obs['is_anonymous'] != true) return false;

      if (_observationStartDate != null || _observationEndDate != null) {
        final obsDateStr = obs['observation_timestamp'] as String?;
        if (obsDateStr != null) {
          final obsDate = DateTime.tryParse(obsDateStr);
          if (obsDate != null) {
            if (_observationStartDate != null && obsDate.isBefore(_observationStartDate!)) return false;
            // Add 1 day to end date to make it inclusive of the selected day
            if (_observationEndDate != null && obsDate.isAfter(_observationEndDate!.add(const Duration(days: 1)))) return false;
          }
        }
      }

      return _isObservationInProvince(obs, _selectedObservationProvince);
    }).toList();
    debugPrint('[OBS] _buildObservationMarkers: ${filtered.length} markers after filtering');

    return filtered.map((obs) {
      final coords = _parseCoordinates(obs['coordinates']);
      final double lat = obs['latitude'] != null ? double.tryParse(obs['latitude'].toString()) ?? (coords?['lat'] ?? 0.0) : (coords?['lat'] ?? 0.0);
      final double lng = obs['longitude'] != null ? double.tryParse(obs['longitude'].toString()) ?? (coords?['lng'] ?? 0.0) : (coords?['lng'] ?? 0.0);
      final confidence = double.tryParse(obs['confidence_score']?.toString() ?? '') ?? 0.0;
      final isVerified = obs['verification_result'] == 'APPROVED' || obs['verification_result'] == 'REJECTED';
      
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
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
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
        ),
      );
    }).toList();
  }

  // Fetches Kriging Contours from Python server
  Future<void> _fetchKriging(String datasetUrl) async {
    final requestId = ++_krigingRequestId;
    setState(() {
      _isKrigingLoading = true;
    });
    try {
      final response = await http.post(
        Uri.parse('$apiBaseUrl/api/kriging'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'dataset_url': datasetUrl,
        }),
      );
      // A newer request has since been fired; this response is stale and
      // must not be allowed to overwrite the display.
      if (requestId != _krigingRequestId) return;

      if (response.statusCode == 200) {
        final polygons = _parseGeoJSON(response.body);
        setState(() {
          _krigingPolygons = polygons;
        });
      } else {
        debugPrint("API Error: ${response.statusCode}");
      }
    } catch (e) {
      if (requestId != _krigingRequestId) return;
      debugPrint("Connection error: $e");
    } finally {
      if (requestId == _krigingRequestId) {
        setState(() {
          _isKrigingLoading = false;
        });
      }
    }
  }

  // Fetches Cellular Automata spread forecast from Python server
  Future<void> _fetchForecast(int steps, String datasetUrl) async {
    final requestId = ++_forecastRequestId;
    setState(() {
      _isCaLoading = true;
    });
    try {
      final response = await http.post(
        Uri.parse('$apiBaseUrl/api/forecast'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'dataset_url': datasetUrl,
          'steps': steps,
          'grid_resolution': 0.12,
          'spread_factor': 0.08,
        }),
      );
      // A newer request has since been fired; this response is stale and
      // must not be allowed to overwrite the display.
      if (requestId != _forecastRequestId) return;

      if (response.statusCode == 200) {
        final polygons = _parseGeoJSON(response.body);
        final decoded = json.decode(response.body) as Map<String, dynamic>;
        final rawPointForecasts = decoded['point_forecasts'] as List<dynamic>?;
        final pointForecasts = rawPointForecasts != null
            ? rawPointForecasts.map((e) => Map<String, dynamic>.from(e as Map)).toList()
            : <Map<String, dynamic>>[];
        setState(() {
          _caPolygons = polygons;
          _caPointForecasts = pointForecasts;
        });
      } else {
        debugPrint("API Error: ${response.statusCode}");
      }
    } catch (e) {
      if (requestId != _forecastRequestId) return;
      debugPrint("Connection error: $e");
    } finally {
      if (requestId == _forecastRequestId) {
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
          Row(
            children: [
          Expanded(
            child: ValueListenableBuilder<MouseCursor>(
              valueListenable: _mapCursorNotifier,
              builder: (context, cursor, child) {
                return MouseRegion(
                  cursor: cursor,
                  child: Listener(
                    onPointerDown: (_) {
                      _isMapDragging = true;
                      _updateMapCursor();
                    },
                    onPointerUp: (_) {
                      _isMapDragging = false;
                      _updateMapCursor();
                    },
                    onPointerCancel: (_) {
                      _isMapDragging = false;
                      _updateMapCursor();
                    },
                    onPointerMove: (event) {
                      if (event.buttons == 2) {
                        final newRotation = _currentRotation + (event.delta.dx * 0.5);
                        _mapController.rotate(newRotation);
                      }
                    },
                    child: child,
                  ),
                );
              },
              child: Stack(
                children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: const LatLng(12.8797, 121.7740),
              initialZoom: 6,
              minZoom: 6,
              maxZoom: 17.0,
              onPositionChanged: (camera, hasGesture) {
                setState(() {
                  _currentZoom = camera.zoom;
                  _currentRotation = camera.rotation;
                  _mapCenter = camera.center;
                });
              },
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
                urlTemplate: _isSatellite
                    ? 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}'
                    : 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Topo_Map/MapServer/tile/{z}/{y}/{x}',
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
                      return MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: Container(
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
                      return MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: Container(
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

              // Map Overlay Controls
              Positioned(
                top: 16,
                right: 16,
                child: Column(
                  children: [
                    // Zoom In/Out
                    Container(
                      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(4), boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)]),
                      child: Column(
                        children: [
                          IconButton(
                            tooltip: 'Zoom In',
                            icon: const Icon(Icons.add, size: 20),
                            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                            padding: EdgeInsets.zero,
                            onPressed: () => _mapController.move(_mapController.camera.center, _mapController.camera.zoom + 1),
                          ),
                          Container(height: 1, width: 36, color: Colors.grey.shade300),
                          IconButton(
                            tooltip: 'Zoom Out',
                            icon: const Icon(Icons.remove, size: 20),
                            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                            padding: EdgeInsets.zero,
                            onPressed: () => _mapController.move(_mapController.camera.center, _mapController.camera.zoom - 1),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    // Compass / Reset Rotation
                    Container(
                      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(4), boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)]),
                      child: IconButton(
                        tooltip: 'Reset Rotation',
                        icon: Transform.rotate(
                          angle: -(_currentRotation * math.pi / 180),
                          child: Transform.scale(
                            scaleY: 1.5,
                            child: Transform.rotate(
                              angle: math.pi / 4,
                              child: Container(
                                width: 10,
                                height: 10,
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                    colors: [Colors.red.shade600, Colors.red.shade600, Colors.grey.shade400, Colors.grey.shade400],
                                    stops: const [0.0, 0.5, 0.5, 1.0],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                        padding: EdgeInsets.zero,
                        onPressed: () {
                          _mapController.rotate(0);
                          setState(() {
                            _currentRotation = 0;
                          });
                        },
                      ),
                    ),
                    const SizedBox(height: 8),
                    // Map Type Toggle
                    Container(
                      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(4), boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)]),
                      child: IconButton(
                        tooltip: _isSatellite ? 'Map View' : 'Satellite View',
                        icon: Icon(_isSatellite ? Icons.map : Icons.satellite_alt, size: 20),
                        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                        padding: EdgeInsets.zero,
                        onPressed: () {
                          setState(() {
                            _isSatellite = !_isSatellite;
                          });
                        },
                      ),
                    ),
                    const SizedBox(height: 8),
                    // Scale Bar
                    Container(
                      width: 60, // Fixed pixel width for calculation
                      height: 24,
                      decoration: BoxDecoration(
                        color: Colors.white.withAlpha(204),
                        border: Border.all(color: Colors.black54),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        _getScaleText(),
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              ),

            ],
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
                              ? "Fetching Gall Rust Spread Forecast..."
                              : _isKrigingLoading
                                  ? "Fetching Gall Rust Spread Mapper..."
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
            ),
          ),
          
          // Dedicated Side Bar Settings Controls
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            width: _isControlsCollapsed ? 0 : 320,
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border(left: BorderSide(color: Colors.grey.shade300)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 4,
                  offset: const Offset(-2, 0),
                )
              ],
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const NeverScrollableScrollPhysics(),
              child: SizedBox(
                width: 320,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                  padding: const EdgeInsets.all(16.0),
                  decoration: BoxDecoration(
                    color: Colors.green.shade50,
                    border: Border(bottom: BorderSide(color: Colors.grey.shade300)),
                  ),
                  child: Row(
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
                ),
                Expanded(
                  child: SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Dataset Manager
                          Container(
                            padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 8.0),
                            margin: const EdgeInsets.only(bottom: 12.0),
                            decoration: BoxDecoration(
                              color: Colors.green.shade50,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.green.shade200),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text("Spatial Dataset", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.green.shade800)),
                                    if (_isDatasetsLoading) const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    Expanded(
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8),
                                        decoration: BoxDecoration(
                                          border: Border.all(color: Colors.grey),
                                          borderRadius: BorderRadius.circular(4),
                                          color: Colors.white,
                                        ),
                                        child: DropdownButton<String>(
                                          isExpanded: true,
                                          underline: const SizedBox(),
                                          value: _datasetVisibilityFilter,
                                          items: ['All', 'Public', 'Private'].map((v) => DropdownMenuItem(value: v, child: Text(v, style: const TextStyle(fontSize: 11)))).toList(),
                                          onChanged: (val) {
                                            if (val != null) setState(() => _datasetVisibilityFilter = val);
                                          },
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    Expanded(
                                      child: OutlinedButton(
                                        style: OutlinedButton.styleFrom(
                                          padding: const EdgeInsets.symmetric(horizontal: 4), 
                                          backgroundColor: Colors.white,
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                                        ),
                                        onPressed: () async {
                                          final date = await showDatePicker(
                                            context: context,
                                            initialDate: _datasetStartDate ?? DateTime.now(),
                                            firstDate: DateTime(2000),
                                            lastDate: DateTime.now(),
                                          );
                                          if (date != null) setState(() => _datasetStartDate = date);
                                        },
                                        child: Text(_datasetStartDate != null ? _datasetStartDate!.toString().split(' ')[0] : 'Start', style: const TextStyle(fontSize: 11)),
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    Expanded(
                                      child: OutlinedButton(
                                        style: OutlinedButton.styleFrom(
                                          padding: const EdgeInsets.symmetric(horizontal: 4), 
                                          backgroundColor: Colors.white,
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                                        ),
                                        onPressed: () async {
                                          final date = await showDatePicker(
                                            context: context,
                                            initialDate: _datasetEndDate ?? DateTime.now(),
                                            firstDate: DateTime(2000),
                                            lastDate: DateTime.now(),
                                          );
                                          if (date != null) setState(() => _datasetEndDate = date);
                                        },
                                        child: Text(_datasetEndDate != null ? _datasetEndDate!.toString().split(' ')[0] : 'End', style: const TextStyle(fontSize: 11)),
                                      ),
                                    ),
                                    if (_datasetStartDate != null || _datasetEndDate != null) ...[
                                      const SizedBox(width: 4),
                                      IconButton(
                                        icon: const Icon(Icons.clear, size: 14),
                                        onPressed: () => setState(() { _datasetStartDate = null; _datasetEndDate = null; }),
                                        padding: EdgeInsets.zero,
                                        constraints: const BoxConstraints(),
                                      ),
                                    ],
                                  ],
                                ),
                                const SizedBox(height: 12),
                                SwitchListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: const Text("My Datasets Only", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                                  value: _showMyDatasetsOnly,
                                  activeTrackColor: Colors.green.shade200,
                                  activeThumbColor: Colors.green.shade700,
                                  onChanged: (val) {
                                    setState(() {
                                      _showMyDatasetsOnly = val;
                                      _selectedDataset = null;
                                      _showCA = false;
                                      _showKriging = false;
                                      _showPlantations = false;
                                      _caPolygons.clear();
                                      _caPointForecasts.clear();
                                      _krigingPolygons.clear();
                                      _plantationsData.clear();
                                      _selectedRegionProps = null;
                                      _selectedRegionLocation = null;
                                      _selectedPlantation = null;
                                      _selectedObservation = null;
                                    });
                                  },
                                ),
                                const SizedBox(height: 8),
                                Container(
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
                                                  if (isOwner)
                                                    Row(
                                                      mainAxisSize: MainAxisSize.min,
                                                      children: [
                                                        Text(
                                                          dataset['is_public'] == true ? 'Public' : 'Private',
                                                          style: TextStyle(fontSize: 9, color: dataset['is_public'] == true ? Colors.green.shade700 : Colors.grey.shade700, fontWeight: FontWeight.bold),
                                                        ),
                                                        Transform.scale(
                                                          scale: 0.6,
                                                          child: Switch(
                                                            value: dataset['is_public'] == true,
                                                            activeTrackColor: Colors.green.shade200,
                                                            activeThumbColor: Colors.green.shade700,
                                                            onChanged: (val) => _toggleDatasetVisibility(dataset, val),
                                                          ),
                                                        ),
                                                      ],
                                                    )
                                                  else
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
                                                ? Row(
                                                    mainAxisSize: MainAxisSize.min,
                                                    children: [
                                                      IconButton(
                                                        icon: const Icon(Icons.delete_outline, size: 16, color: Colors.red),
                                                        padding: EdgeInsets.zero,
                                                        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                                                        tooltip: 'Delete Dataset',
                                                        onPressed: () => _deleteDataset(dataset),
                                                      ),
                                                      const Icon(Icons.star, size: 14, color: Colors.orange),
                                                    ],
                                                  )
                                                : const Icon(Icons.public, size: 14, color: Colors.grey),
                                              onTap: () {
                                                setState(() {
                                                  _selectedDataset = dataset;
                                                  _showCA = false;
                                                  _showKriging = false;
                                                  _showPlantations = false;
                                                  _caPolygons.clear();
                                                  _caPointForecasts.clear();
                                                  _krigingPolygons.clear();
                                                  _plantationsData.clear();
                                                  _selectedRegionProps = null;
                                                  _selectedRegionLocation = null;
                                                  _selectedPlantation = null;
                                                  _selectedObservation = null;
                                                });
                                                final url = Supabase.instance.client.storage.from('datasets').getPublicUrl(dataset['filepath']);
                                                _fetchForecast(_caSteps, url);
                                                _fetchKriging(url);
                                                _fetchPlantations(url);
                                              },
                                            ),
                                          );
                                        },
                                      ),
                                ),
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    Expanded(
                                      child: ElevatedButton.icon(
                                        icon: _isUploadingDataset ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)) : const Icon(Icons.upload_file, size: 16),
                                        label: const Text('Upload CSV', style: TextStyle(fontSize: 12)),
                                        style: ElevatedButton.styleFrom(
                                          padding: const EdgeInsets.symmetric(vertical: 8),
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                                        ),
                                        onPressed: _isUploadingDataset ? null : _uploadDataset,
                                      ),
                                    ),
                                    if (_selectedDataset != null && _selectedDataset!['user_id'] == Supabase.instance.client.auth.currentUser?.id) ...[
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: OutlinedButton.icon(
                                          icon: const Icon(Icons.download, size: 16),
                                          label: const Text('Download', style: TextStyle(fontSize: 12)),
                                          style: OutlinedButton.styleFrom(
                                            padding: const EdgeInsets.symmetric(vertical: 8),
                                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                                          ),
                                          onPressed: () {
                                            final url = Supabase.instance.client.storage.from('datasets').getPublicUrl(_selectedDataset!['filepath']);
                                            launchUrl(Uri.parse(url));
                                          },
                                        ),
                                      ),
                                    ]
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          _buildLegend(),
                          const SizedBox(height: 12),

                          // Accordions
                        ExpansionTile(
                          title: const Text("Gall Rust Spread Forecast", style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                          leading: Icon(Icons.online_prediction, color: _showCA ? Colors.green.shade700 : Colors.grey),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Switch(
                                value: _showCA,
                                activeTrackColor: Colors.green.shade700,
                                onChanged: _selectedDataset == null ? null : (val) {
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
                                Row(
                                  children: [
                                    const Text("Forecast Steps:", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                                    const SizedBox(width: 4),
                                    Tooltip(
                                      message: "A 'step' represents a mathematical cycle of spread. Its exact real-world equivalent (e.g. week, month, or year) is not yet calibrated.",
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
                                  setState(() {
                                    _caSteps = val.round();
                                    _selectedRegionProps = null;
                                    _selectedRegionLocation = null;
                                    _selectedPlantation = null;
                                    _selectedObservation = null;
                                  });
                                },
                                onChangeEnd: (val) {
                                  if (_selectedDataset != null) {
                                    final url = Supabase.instance.client.storage.from('datasets').getPublicUrl(_selectedDataset!['filepath']);
                                    _fetchForecast(val.round(), url);
                                  }
                                },
                            ),
                          ],
                        ),
                        
                        ExpansionTile(
                          title: const Text("Gall Rust Spread Mapper", style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                          leading: Icon(Icons.grain, color: _showKriging ? Colors.green.shade700 : Colors.grey),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Switch(
                                value: _showKriging,
                                activeTrackColor: Colors.green.shade700,
                                onChanged: _selectedDataset == null ? null : (val) {
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
                                onChanged: _selectedDataset == null ? null : (val) {
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
                              items: _buildProvinceDropdownItems(),
                              selectedItemBuilder: _buildProvinceSelectedItems,
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
                          ],
                        ),
                        const Divider(height: 20),
                        
                        // Field Observations Toggle
                        ExpansionTile(
                          title: const Text("Field Observations", style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                          leading: Icon(Icons.person_pin_circle, color: _showObservations ? Colors.blue.shade700 : Colors.grey),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Switch(
                                value: _showObservations,
                                activeTrackColor: Colors.blue.shade700,
                                onChanged: (val) {
                                  setState(() {
                                    _showObservations = val;
                                    _selectedObservation = null;
                                  });
                                },
                              ),
                              Icon(
                                _isObservationsExpanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                                color: Colors.grey,
                              ),
                            ],
                          ),
                          onExpansionChanged: (expanded) {
                            setState(() {
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
                                    setState(() {
                                      _selectedObservationVerification = val;
                                      _selectedObservation = null;
                                    });
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
                                  child: Text(role, style: TextStyle(fontSize: 12, color: (_showMyObservationsOnly || _showAnonymousOnly) ? Colors.grey : Colors.black87)),
                                );
                              }).toList(),
                                onChanged: (_showMyObservationsOnly || _showAnonymousOnly) ? null : (val) {
                                  if (val != null) {
                                    setState(() {
                                      _selectedObservationUserRole = val;
                                      _selectedObservation = null;
                                    });
                                  }
                                },
                            ),
                            if (_currentUserRole == 'EXPERT') ...[
                              const SizedBox(height: 12),
                              const Align(
                                alignment: Alignment.centerLeft,
                                child: Text("Filter by Source:", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                              ),
                              const SizedBox(height: 4),
                              DropdownButton<String>(
                                isExpanded: true,
                                value: _selectedObservationSource,
                                items: _availableObservationSources.map((source) {
                                  return DropdownMenuItem(
                                    value: source,
                                    child: Text(source, style: TextStyle(fontSize: 12, color: _showAnonymousOnly ? Colors.grey : Colors.black87)),
                                  );
                                }).toList(),
                                onChanged: _showAnonymousOnly ? null : (val) {
                                  if (val != null) {
                                    setState(() {
                                      _selectedObservationSource = val;
                                      _selectedObservation = null;
                                    });
                                  }
                                },
                              ),
                            ],
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
                                    setState(() {
                                      _selectedObservationProvince = val;
                                      _selectedObservation = null;
                                    });
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
                                        setState(() {
                                          _observationStartDate = date;
                                          _selectedObservation = null;
                                        });
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
                                        setState(() {
                                          _observationEndDate = date;
                                          _selectedObservation = null;
                                        });
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
                                      setState(() {
                                        _observationStartDate = null;
                                        _observationEndDate = null;
                                        _selectedObservation = null;
                                      });
                                    },
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(),
                                  ),
                                ],
                              ],
                            ),
                            const SizedBox(height: 12),
                            CheckboxListTile(
                              controlAffinity: ListTileControlAffinity.trailing,
                              contentPadding: EdgeInsets.zero,
                              title: const Text("My Observations Only", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                              value: _showMyObservationsOnly,
                              onChanged: (val) {
                                setState(() {
                                  _showMyObservationsOnly = val ?? false;
                                  if (val ?? false) _selectedObservationUserRole = 'All';
                                  _selectedObservation = null;
                                });
                              },
                            ),
                            CheckboxListTile(
                              controlAffinity: ListTileControlAffinity.trailing,
                              contentPadding: EdgeInsets.zero,
                              title: const Text("Show Anonymous Observations Only", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                              value: _showAnonymousOnly,
                              onChanged: (val) {
                                setState(() {
                                  _showAnonymousOnly = val ?? false;
                                  if (val ?? false) {
                                    _selectedObservationUserRole = 'All';
                                    _selectedObservationSource = 'All';
                                  }
                                  _selectedObservation = null;
                                });
                              },
                            ),
                          ],
                        ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
            ),
            ),
          ),
          ],
        ),
          
          if (_selectedObservation != null)
            ObservationDetailsPanel(
              obs: _selectedObservation!,
              currentUserRole: _currentUserRole,
              onClose: () {
                _highlightPulseController.stop();
                setState(() {
                  _selectedObservation = null;
                  _highlightedLatLng = null;
                });
              },
              onModified: () {
                setState(() => _selectedObservation = null);
                _fetchObservations();
              },
            ),
            
          // Right Notch Toggle Button
          AnimatedPositioned(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            right: (_isControlsCollapsed ? 0 : 320) - 20,
            top: MediaQuery.of(context).size.height / 2 - 20,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () {
                  setState(() {
                    _isControlsCollapsed = !_isControlsCollapsed;
                  });
                },
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.1),
                        blurRadius: 4,
                      ),
                    ],
                    border: Border.all(color: Colors.grey.shade200),
                  ),
                  child: Icon(
                    _isControlsCollapsed ? Icons.chevron_left : Icons.chevron_right,
                    color: Colors.green[700],
                    size: 26,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}