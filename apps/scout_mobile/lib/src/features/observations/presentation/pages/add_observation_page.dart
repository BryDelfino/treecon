import 'dart:io';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_services/shared_services.dart';
import 'package:uuid/uuid.dart';
import 'dart:async';
import '../../data/cached_observation.dart';
import '../../data/observation_local_db.dart';
import 'package:scout_mobile/src/core/services/network_service.dart';

class AddObservationPage extends StatefulWidget {
  const AddObservationPage({super.key});

  @override
  State<AddObservationPage> createState() => _AddObservationPageState();
}

class _AddObservationPageState extends State<AddObservationPage> {
  File? _imageFile;
  Position? _currentPosition;
  bool _isLoadingLocation = false;
  bool _isSaving = false;
  bool _isPublic = true;
  bool _isAnonymous = false;
  bool _syncImmediately = false;
  final ImagePicker _picker = ImagePicker();
  
  bool _isOnline = true;
  StreamSubscription<bool>? _networkSub;

  @override
  void initState() {
    super.initState();
    _isOnline = NetworkService.instance.isOnline;
    _networkSub = NetworkService.instance.onConnectivityChanged.listen((isOnline) {
      if (mounted) {
        setState(() {
          _isOnline = isOnline;
          if (!isOnline) {
            _syncImmediately = false;
          }
        });
      }
    });
    _determinePosition();
  }

  @override
  void dispose() {
    _networkSub?.cancel();
    super.dispose();
  }

  Future<void> _determinePosition() async {
    setState(() {
      _isLoadingLocation = true;
    });

    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        throw Exception('Location services are disabled.');
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          throw Exception('Location permissions are denied');
        }
      }

      if (permission == LocationPermission.deniedForever) {
        throw Exception('Location permissions are permanently denied.');
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );

      if (mounted) {
        setState(() {
          _currentPosition = position;
          _isLoadingLocation = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingLocation = false;
        });
        _showSnackBar('Failed to get location: ${e.toString()}', isError: true);
      }
    }
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final pickedFile = await _picker.pickImage(
        source: source,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 85,
      );

      if (pickedFile != null && mounted) {
        final mimeType = lookupMimeType(pickedFile.path);
        if (mimeType != 'image/jpeg' && mimeType != 'image/jpg') {
          _showSnackBar('Only JPG/JPEG files are allowed.', isError: true);
          return;
        }

        setState(() {
          _imageFile = File(pickedFile.path);
        });
      }
    } catch (e) {
      _showSnackBar('Error choosing image: $e', isError: true);
    }
  }

  Future<void> _saveObservation() async {
    if (_imageFile == null) {
      _showSnackBar('Please take or select a photo first', isError: true);
      return;
    }

    if (_currentPosition == null) {
      _showSnackBar('Waiting for valid GPS coordinates...', isError: true);
      return;
    }

    setState(() {
      _isSaving = true;
    });

    try {
      // 1. Copy image to app's safe document directory so it is persistent
      final appDir = await getApplicationDocumentsDirectory();
      final uuid = const Uuid().v4();
      final extension = p.extension(_imageFile!.path);
      final localImagePath = p.join(appDir.path, 'obs_$uuid$extension');
      await _imageFile!.copy(localImagePath);

      // 2. Prepare local cache model
      final user = Supabase.instance.client.auth.currentUser;
      final cachedObs = CachedObservation(
        observationId: uuid,
        userId: user?.id,
        latitude: _currentPosition!.latitude,
        longitude: _currentPosition!.longitude,
        imagePath: localImagePath,
        observationTimestamp: DateTime.now(),
        syncStatus: 'PENDING',
        isPublic: _isPublic,
        isAnonymous: _isAnonymous,
      );

      // 3. Save to local DB
      await ObservationLocalDb.instance.insertObservation(cachedObs);

      if (mounted) {
        if (!_syncImmediately) {
          _showSnackBar(
            'Observation saved locally.',
            isError: false,
          );
        }
        Navigator.of(context).pop(_syncImmediately ? uuid : true);
      }
    } catch (e) {
      _showSnackBar('Failed to save observation: $e', isError: true);
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  void _showSnackBar(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red[800] : Colors.green[800],
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'New Observation',
          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        ),
        backgroundColor: Colors.green[700],
        foregroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Image Preview container
            GestureDetector(
              onTap: () {
                _pickImage(ImageSource.camera);
              },
              child: Container(
                height: 250,
                decoration: BoxDecoration(
                  color: Colors.green[50],
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.green[200]!, width: 2),
                ),
                child: _imageFile != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(18),
                        child: Image.file(_imageFile!, fit: BoxFit.cover),
                      )
                    : Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.camera_alt_outlined, size: 64, color: Colors.green[300]),
                          const SizedBox(height: 12),
                          Text(
                            'Tap to add Gall Rust photo',
                            style: TextStyle(
                              color: Colors.green[700],
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Camera Only',
                            style: TextStyle(color: Colors.green[400], fontSize: 13),
                          ),
                        ],
                      ),
              ),
            ),
            const SizedBox(height: 24),

            // Location Box
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.grey[50],
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.grey[200]!),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.green[50],
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.location_on, color: Colors.green[700]),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'GPS Coordinates',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                        ),
                        const SizedBox(height: 4),
                        if (_isLoadingLocation)
                          const Text('Acquiring location...', style: TextStyle(color: Colors.grey))
                        else if (_currentPosition != null)
                          Text(
                            'Lat: ${_currentPosition!.latitude.toStringAsFixed(6)}, Lng: ${_currentPosition!.longitude.toStringAsFixed(6)}',
                            style: const TextStyle(fontWeight: FontWeight.w500),
                          )
                        else
                          const Text('Location not available', style: TextStyle(color: Colors.red)),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    color: Colors.green[700],
                    onPressed: _isLoadingLocation ? null : _determinePosition,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // Settings
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.grey[200]!),
              ),
              child: Column(
                children: [
                  SwitchListTile(
                    title: const Text('Public Observation', style: TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: const Text('Allow others to view this observation', style: TextStyle(fontSize: 12)),
                    value: _isPublic,
                    activeTrackColor: Colors.green[700],
                    onChanged: (val) => setState(() => _isPublic = val),
                  ),
                  const Divider(height: 1),
                  SwitchListTile(
                    title: const Text('Submit Anonymously', style: TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: const Text('Hide your username from public view', style: TextStyle(fontSize: 12)),
                    value: _isAnonymous,
                    activeTrackColor: Colors.green[700],
                    onChanged: (val) => setState(() => _isAnonymous = val),
                  ),
                  if (_isOnline) ...[
                    const Divider(height: 1),
                    SwitchListTile(
                      title: const Text('Sync Immediately', style: TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: const Text('Upload to the system right after saving', style: TextStyle(fontSize: 12)),
                      value: _syncImmediately,
                      activeTrackColor: Colors.green[700],
                      onChanged: (val) => setState(() => _syncImmediately = val),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 40),

            // Submit Button
            ElevatedButton(
              onPressed: _isSaving || _isLoadingLocation ? null : _saveObservation,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green[700],
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                elevation: 2,
              ),
              child: _isSaving
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                    )
                  : const Text(
                      'Save Observation',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
