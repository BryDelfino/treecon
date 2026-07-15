import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';

/// Full-screen image viewer with scroll-wheel zoom and dedicated
/// zoom in/out controls, for use on web/desktop.
class FullScreenImageViewer extends StatefulWidget {
  final String imageUrl;

  const FullScreenImageViewer({super.key, required this.imageUrl});

  static void show(BuildContext context, String imageUrl) {
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black,
        pageBuilder: (context, animation, secondaryAnimation) => FadeTransition(
          opacity: animation,
          child: FullScreenImageViewer(imageUrl: imageUrl),
        ),
      ),
    );
  }

  @override
  State<FullScreenImageViewer> createState() => _FullScreenImageViewerState();
}

class _FullScreenImageViewerState extends State<FullScreenImageViewer> {
  final TransformationController _controller = TransformationController();
  static const double _minScale = 1.0;
  static const double _maxScale = 5.0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  double get _currentScale => _controller.value.getMaxScaleOnAxis();

  void _zoomBy(double factor, {Offset? focalPoint}) {
    final newScale = (_currentScale * factor).clamp(_minScale, _maxScale);
    final effectiveFactor = newScale / _currentScale;
    if (effectiveFactor == 1.0) return;

    final center = focalPoint ?? const Offset(0, 0);
    final matrix = _controller.value.clone()
      ..translateByDouble(center.dx, center.dy, 0, 1)
      ..scaleByDouble(effectiveFactor, effectiveFactor, effectiveFactor, 1)
      ..translateByDouble(-center.dx, -center.dy, 0, 1);
    _controller.value = matrix;
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      final factor = event.scrollDelta.dy < 0 ? 1.1 : 0.9;
      _zoomBy(factor, focalPoint: event.localPosition);
    }
  }

  void _resetZoom() {
    _controller.value = Matrix4.identity();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: Listener(
              onPointerSignal: _handlePointerSignal,
              child: InteractiveViewer(
                transformationController: _controller,
                minScale: _minScale,
                maxScale: _maxScale,
                child: Center(
                  child: Image.network(
                    widget.imageUrl,
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stackTrace) => const Icon(Icons.broken_image, color: Colors.white54, size: 64),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: 16,
            right: 16,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white, size: 28),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
          Positioned(
            bottom: 24,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.remove, color: Colors.white),
                      tooltip: 'Zoom out',
                      onPressed: () => _zoomBy(0.8),
                    ),
                    IconButton(
                      icon: const Icon(Icons.restart_alt, color: Colors.white),
                      tooltip: 'Reset zoom',
                      onPressed: _resetZoom,
                    ),
                    IconButton(
                      icon: const Icon(Icons.add, color: Colors.white),
                      tooltip: 'Zoom in',
                      onPressed: () => _zoomBy(1.25),
                    ),
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
