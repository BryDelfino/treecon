import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

class MapPage extends StatelessWidget {
    const MapPage({super.key});

    @override
    Widget build(BuildContext context) {
        return Scaffold(
            appBar: AppBar(
                title: Text("Map Page"),
                backgroundColor: Colors.green,
            ),
            body: Stack(
                children: [
                    FlutterMap(
                        options: const MapOptions(
                            initialCenter: LatLng(12.8797, 121.7740),
                            initialZoom: 5,
                        ),
                        children: [
                            TileLayer(
                                urlTemplate: 'https://tiles.stadiamaps.com/tiles/stamen_terrain/{z}/{x}/{y}.png', 
                            ),
                        ]
                    ),
                ],
            ),
        );
    }
 }