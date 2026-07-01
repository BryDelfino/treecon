import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:http/http.dart' as http;

class NetworkService {
  NetworkService._internal();
  static final NetworkService instance = NetworkService._internal();

  final Connectivity _connectivity = Connectivity();
  final StreamController<bool> _connectivityController = StreamController<bool>.broadcast();

  bool _isOnline = false;

  bool get isOnline => _isOnline;
  Stream<bool> get onConnectivityChanged => _connectivityController.stream;

  Future<void> init() async {
    // Initial check
    final List<ConnectivityResult> results = await _connectivity.checkConnectivity();
    await _updateConnectionStatus(results);

    // Listen to stream
    _connectivity.onConnectivityChanged.listen((List<ConnectivityResult> results) async {
      await _updateConnectionStatus(results);
    });
  }

  Future<void> _updateConnectionStatus(List<ConnectivityResult> results) async {
    bool hasConnection = false;
    // connectivity_plus 6.x returns a List<ConnectivityResult>
    for (var result in results) {
      if (result != ConnectivityResult.none) {
        hasConnection = true;
        break;
      }
    }

    if (hasConnection) {
      // Perform a ping check to be sure we have real internet, not just local network
      _isOnline = await _pingInternet();
    } else {
      _isOnline = false;
    }

    _connectivityController.add(_isOnline);
  }

  Future<bool> _pingInternet() async {
    try {
      final response = await http.head(Uri.parse('https://www.google.com')).timeout(
        const Duration(seconds: 3),
      );
      return response.statusCode >= 200 && response.statusCode < 400;
    } catch (_) {
      return false;
    }
  }

  void dispose() {
    _connectivityController.close();
  }
}
