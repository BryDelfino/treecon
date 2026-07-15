import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

/// A single administrative-level-2 (province) polygon ring, loaded from
/// a Philippines GeoJSON asset (adm2_name / adm1_name properties).
class ProvincePolygon {
  final String name;
  final String region;
  final List<List<double>> points; // [lat, lng] pairs

  const ProvincePolygon({required this.name, required this.region, required this.points});
}

/// Client-side province lookup shared by the map sidebars and the
/// observation filter modals. Loads a `philippines.json` GeoJSON asset
/// (each app ships its own copy under `assets/philippines.json`) and
/// answers point-in-polygon province queries against it.
class ProvinceLookup {
  static List<ProvincePolygon> _polygons = [];
  static Map<String, String> provinceToRegion = {};
  static bool _loaded = false;

  static bool get isLoaded => _loaded;

  static Future<void> load({String assetPath = 'assets/philippines.json'}) async {
    if (_loaded) return;
    try {
      final jsonString = await rootBundle.loadString(assetPath);
      final geojson = json.decode(jsonString) as Map<String, dynamic>;
      final features = geojson['features'] as List<dynamic>;
      final List<ProvincePolygon> polys = [];

      void addRing(List<dynamic> ring, String name, String region) {
        final points = <List<double>>[];
        for (var pt in ring) {
          final point = pt as List<dynamic>;
          points.add([(point[1] as num).toDouble(), (point[0] as num).toDouble()]);
        }
        polys.add(ProvincePolygon(name: name, region: region, points: points));
      }

      for (var f in features) {
        final feature = f as Map<String, dynamic>;
        if (feature['geometry'] == null) continue;
        final geom = feature['geometry'] as Map<String, dynamic>;
        final type = geom['type'] as String;
        final coords = geom['coordinates'] as List<dynamic>;
        final props = feature['properties'] as Map<String, dynamic>?;
        final name = props?['adm2_name'] as String?;
        final region = props?['adm1_name'] as String? ?? '';
        if (name == null || name == 'Special Geographic Area') continue;

        if (type == 'Polygon') {
          addRing(coords[0] as List<dynamic>, name, region);
        } else if (type == 'MultiPolygon') {
          for (var poly in coords) {
            addRing((poly as List<dynamic>)[0] as List<dynamic>, name, region);
          }
        }
      }

      _polygons = polys;
      provinceToRegion = {for (final p in polys) p.name: p.region};
      _loaded = true;
    } catch (_) {
      // Leave unloaded; callers should treat an empty province list as "unavailable".
    }
  }

  static bool _isPointInPolygon(double lat, double lng, List<List<double>> polygon) {
    bool isInside = false;
    for (int i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
      final yi = polygon[i][0], xi = polygon[i][1];
      final yj = polygon[j][0], xj = polygon[j][1];
      if (((yi > lat) != (yj > lat)) && (lng < (xj - xi) * (lat - yi) / (yj - yi) + xi)) {
        isInside = !isInside;
      }
    }
    return isInside;
  }

  /// Returns the province name for a coordinate, or 'Unknown' if not found
  /// (e.g. lookup data not loaded yet, or the point falls outside all polygons).
  static String provinceForPoint(double lat, double lng) {
    for (final poly in _polygons) {
      if (_isPointInPolygon(lat, lng, poly.points)) {
        return poly.name;
      }
    }
    return 'Unknown';
  }

  static List<String> get availableProvinces {
    final Set<String> provinces = {'All'};
    for (final p in _polygons) {
      provinces.add(p.name);
    }
    final list = provinces.toList();
    list.sort((a, b) {
      if (a == 'All') return -1;
      if (b == 'All') return 1;
      final regionCompare = (provinceToRegion[a] ?? '').compareTo(provinceToRegion[b] ?? '');
      if (regionCompare != 0) return regionCompare;
      return a.compareTo(b);
    });
    return list;
  }

  /// Builds a region-grouped dropdown item list matching the map sidebar's style.
  static List<DropdownMenuItem<String>> buildDropdownItems() {
    final items = <DropdownMenuItem<String>>[
      const DropdownMenuItem(
        value: 'All',
        child: Text('All Provinces', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
      ),
    ];

    final grouped = <String, List<String>>{};
    for (final prov in availableProvinces) {
      if (prov == 'All') continue;
      final region = provinceToRegion[prov] ?? 'Other Regions';
      grouped.putIfAbsent(region, () => []).add(prov);
    }

    final sortedRegions = grouped.keys.toList()..sort();
    for (final region in sortedRegions) {
      items.add(
        DropdownMenuItem(
          value: 'HEADER_$region',
          enabled: false,
          child: Text(
            region,
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.green.shade800),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
      for (final prov in grouped[region]!) {
        items.add(
          DropdownMenuItem(
            value: prov,
            child: Padding(
              padding: const EdgeInsets.only(left: 16.0),
              child: Text(prov, style: const TextStyle(fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ),
        );
      }
    }
    return items;
  }
}
