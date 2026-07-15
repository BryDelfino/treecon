import 'dart:io';
import 'package:flutter/material.dart';

/// Full-screen image viewer supporting pinch-to-zoom and double-tap-to-zoom.
class FullScreenImageViewer extends StatefulWidget {
  final String? imageUrl;
  final String? localImagePath;

  const FullScreenImageViewer({super.key, this.imageUrl, this.localImagePath});

  static void show(BuildContext context, {String? imageUrl, String? localImagePath}) {
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black,
        pageBuilder: (context, animation, secondaryAnimation) => FadeTransition(
          opacity: animation,
          child: FullScreenImageViewer(imageUrl: imageUrl, localImagePath: localImagePath),
        ),
      ),
    );
  }

  @override
  State<FullScreenImageViewer> createState() => _FullScreenImageViewerState();
}

class _FullScreenImageViewerState extends State<FullScreenImageViewer> with SingleTickerProviderStateMixin {
  final TransformationController _controller = TransformationController();
  TapDownDetails? _doubleTapDetails;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleDoubleTap() {
    final isZoomedIn = _controller.value.getMaxScaleOnAxis() > 1.01;
    if (isZoomedIn) {
      _controller.value = Matrix4.identity();
      return;
    }

    final tapPosition = _doubleTapDetails?.localPosition ?? Offset.zero;
    const scale = 3.0;
    final matrix = Matrix4.identity()
      ..translateByDouble(-tapPosition.dx * (scale - 1), -tapPosition.dy * (scale - 1), 0, 1)
      ..scaleByDouble(scale, scale, scale, 1);
    _controller.value = matrix;
  }

  @override
  Widget build(BuildContext context) {
    final hasLocal = widget.localImagePath != null && widget.localImagePath!.isNotEmpty && File(widget.localImagePath!).existsSync();
    final hasNetwork = widget.imageUrl != null && widget.imageUrl!.isNotEmpty;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onDoubleTapDown: (details) => _doubleTapDetails = details,
              onDoubleTap: _handleDoubleTap,
              child: InteractiveViewer(
                transformationController: _controller,
                minScale: 1.0,
                maxScale: 5.0,
                child: Center(
                  child: hasLocal
                      ? Image.file(File(widget.localImagePath!), fit: BoxFit.contain)
                      : hasNetwork
                          ? Image.network(
                              widget.imageUrl!,
                              fit: BoxFit.contain,
                              errorBuilder: (context, error, stackTrace) => const Icon(Icons.broken_image, color: Colors.white54, size: 64),
                            )
                          : const Icon(Icons.park_outlined, color: Colors.white54, size: 64),
                ),
              ),
            ),
          ),
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            right: 8,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white, size: 28),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
        ],
      ),
    );
  }
}
