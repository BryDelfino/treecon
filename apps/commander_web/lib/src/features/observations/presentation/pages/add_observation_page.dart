import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:exif/exif.dart' as exif_lib;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_services/shared_services.dart';
import 'package:web/web.dart' as web;
import '../widgets/full_screen_image_viewer.dart';

/// Photos wider or taller than this (in either dimension) are downscaled
/// before upload, to avoid hitting storage payload limits while keeping
/// detail useful for review.
const int _maxUploadDimension = 1920;
const double _uploadJpegQuality = 0.85;

const LatLng _defaultPinPosition = LatLng(12.8797, 121.7740);
const double _defaultZoom = 6.0;

class AddObservationPage extends StatefulWidget {
  const AddObservationPage({super.key});

  @override
  State<AddObservationPage> createState() => _AddObservationPageState();
}

class _AddObservationPageState extends State<AddObservationPage> {
  Uint8List? _imageBytes;

  DateTime? _observationTimestamp;
  final _latController = TextEditingController();
  final _lngController = TextEditingController();

  final _mapController = MapController();
  LatLng _pinPosition = _defaultPinPosition;
  bool _isSatellite = false;
  double _currentZoom = _defaultZoom;
  bool _isUpdatingFromMap = false;

  bool _isPublic = true;
  bool _isAnonymous = false;

  bool _isSaving = false;
  bool _isExtractingExif = false;

  // Whether the current values were auto-filled from the photo's EXIF
  // metadata. When true, the corresponding field is locked from manual edits.
  bool _timestampFromExif = false;
  bool _coordinatesFromExif = false;

  @override
  void initState() {
    super.initState();
    _latController.addListener(_onLatLngFieldChanged);
    _lngController.addListener(_onLatLngFieldChanged);
  }

  @override
  void dispose() {
    _latController.dispose();
    _lngController.dispose();
    super.dispose();
  }

  void _onLatLngFieldChanged() {
    if (_isUpdatingFromMap) return;
    final lat = double.tryParse(_latController.text);
    final lng = double.tryParse(_lngController.text);
    if (lat == null || lng == null) return;
    if (lat < -90 || lat > 90 || lng < -180 || lng > 180) return;

    setState(() {
      _pinPosition = LatLng(lat, lng);
    });
    _mapController.move(_pinPosition, _currentZoom);
  }

  void _updatePinPosition(LatLng position) {
    _isUpdatingFromMap = true;
    setState(() {
      _pinPosition = position;
      _latController.text = position.latitude.toStringAsFixed(6);
      _lngController.text = position.longitude.toStringAsFixed(6);
    });
    _isUpdatingFromMap = false;
  }

  Future<void> _pickImage() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['jpg', 'jpeg'],
        withData: true,
      );

      if (result == null || result.files.isEmpty) return;
      final file = result.files.first;
      final rawBytes = file.bytes;
      if (rawBytes == null) {
        _showSnackBar('Could not read the selected file.', isError: true);
        return;
      }

      setState(() => _isExtractingExif = true);
      final processedBytes = await _downscaleImage(rawBytes);

      setState(() {
        _imageBytes = processedBytes;
        // Clear previous fields and re-evaluate lock state fresh, so a
        // replacement photo without metadata doesn't inherit the old
        // photo's timestamp/coordinates.
        _timestampFromExif = false;
        _coordinatesFromExif = false;
        _observationTimestamp = null;
        _latController.clear();
        _lngController.clear();
        _pinPosition = _defaultPinPosition;
        _currentZoom = _defaultZoom;
      });
      _mapController.move(_pinPosition, _currentZoom);

      // Extract our own fields from the original bytes, before any re-encoding.
      await _extractExifData(rawBytes);
    } catch (e) {
      _showSnackBar('Error choosing image: $e', isError: true);
    } finally {
      if (mounted) setState(() => _isExtractingExif = false);
    }
  }

  /// Downscales the image to [_maxUploadDimension] on its longest side when
  /// needed, using the browser's own `createImageBitmap`/`<canvas>` APIs so
  /// the work runs asynchronously in the browser instead of blocking the
  /// Dart UI thread. Canvas export strips all metadata, so the original
  /// EXIF/APP1 segment (timestamp, GPS, orientation) is manually spliced
  /// back into the re-encoded JPEG bytes afterward.
  Future<Uint8List> _downscaleImage(Uint8List bytes) async {
    final blob = web.Blob(
      <JSAny>[bytes.toJS].toJS,
      web.BlobPropertyBag(type: 'image/jpeg'),
    );

    final bitmap = await web.window
        .createImageBitmap(blob, web.ImageBitmapOptions(imageOrientation: 'none'))
        .toDart;

    if (bitmap.width <= _maxUploadDimension && bitmap.height <= _maxUploadDimension) {
      bitmap.close();
      return bytes;
    }

    final longestSide = bitmap.width >= bitmap.height ? bitmap.width : bitmap.height;
    final scale = _maxUploadDimension / longestSide;
    final targetWidth = (bitmap.width * scale).round();
    final targetHeight = (bitmap.height * scale).round();

    final canvas = web.HTMLCanvasElement()
      ..width = targetWidth
      ..height = targetHeight;
    final ctx = canvas.getContext('2d') as web.CanvasRenderingContext2D;
    ctx.drawImage(bitmap, 0, 0, targetWidth, targetHeight);
    bitmap.close();

    final outBlob = await _canvasToBlob(canvas, 'image/jpeg', _uploadJpegQuality);
    final buffer = await outBlob.arrayBuffer().toDart;
    final resizedBytes = buffer.toDart.asUint8List();

    final exifSegment = _extractExifSegment(bytes);
    if (exifSegment == null) return resizedBytes;
    return _spliceExifSegment(resizedBytes, exifSegment);
  }

  Future<web.Blob> _canvasToBlob(web.HTMLCanvasElement canvas, String type, double quality) {
    final completer = Completer<web.Blob>();
    void onBlob(web.Blob? blob) {
      if (blob != null) {
        completer.complete(blob);
      } else {
        completer.completeError(Exception('Canvas export to blob failed.'));
      }
    }

    canvas.toBlob(onBlob.toJS, type, quality.toJS);
    return completer.future;
  }

  /// Locates the EXIF (APP1, marker 0xFFE1, "Exif\0\0") segment in a JPEG
  /// byte stream and returns it (marker + length + data), or null if absent.
  Uint8List? _extractExifSegment(Uint8List bytes) {
    if (bytes.length < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8) return null;

    var offset = 2;
    while (offset + 4 <= bytes.length) {
      if (bytes[offset] != 0xFF) break;
      final marker = bytes[offset + 1];
      if (marker == 0xDA) break; // Start of scan: no more metadata segments follow.

      final segmentLength = (bytes[offset + 2] << 8) | bytes[offset + 3];
      final isExif = marker == 0xE1 &&
          offset + 10 <= bytes.length &&
          bytes[offset + 4] == 0x45 && // E
          bytes[offset + 5] == 0x78 && // x
          bytes[offset + 6] == 0x69 && // i
          bytes[offset + 7] == 0x66 && // f
          bytes[offset + 8] == 0x00 &&
          bytes[offset + 9] == 0x00;

      final segmentEnd = offset + 2 + segmentLength;
      if (segmentEnd > bytes.length) return null;
      if (isExif) return bytes.sublist(offset, segmentEnd);

      offset = segmentEnd;
    }
    return null;
  }

  /// Inserts an EXIF (APP1) segment right after the SOI marker of [jpegBytes].
  Uint8List _spliceExifSegment(Uint8List jpegBytes, Uint8List exifSegment) {
    if (jpegBytes.length < 2 || jpegBytes[0] != 0xFF || jpegBytes[1] != 0xD8) {
      return jpegBytes;
    }
    final builder = BytesBuilder(copy: false)
      ..add(jpegBytes.sublist(0, 2))
      ..add(exifSegment)
      ..add(jpegBytes.sublist(2));
    return builder.toBytes();
  }

  Future<void> _extractExifData(Uint8List bytes) async {
    setState(() => _isExtractingExif = true);
    try {
      final tags = await exif_lib.readExifFromBytes(bytes);

      DateTime? extractedTimestamp;
      final dateTag = tags['EXIF DateTimeOriginal'] ?? tags['Image DateTime'];
      if (dateTag != null) {
        // EXIF datetime format: "yyyy:MM:dd HH:mm:ss"
        final raw = dateTag.printable.trim();
        final normalized = raw.replaceFirst(':', '-').replaceFirst(':', '-');
        extractedTimestamp = DateTime.tryParse(normalized);
      }

      double? extractedLat;
      double? extractedLng;
      final gpsLat = tags['GPS GPSLatitude'];
      final gpsLatRef = tags['GPS GPSLatitudeRef'];
      final gpsLng = tags['GPS GPSLongitude'];
      final gpsLngRef = tags['GPS GPSLongitudeRef'];
      if (gpsLat != null && gpsLng != null) {
        final lat = _dmsToDecimal(gpsLat.values);
        final lng = _dmsToDecimal(gpsLng.values);
        if (lat != null && lng != null) {
          extractedLat = gpsLatRef?.printable.trim() == 'S' ? -lat : lat;
          extractedLng = gpsLngRef?.printable.trim() == 'W' ? -lng : lng;
        }
      }

      if (!mounted) return;

      final foundTimestamp = extractedTimestamp != null;
      final foundCoordinates = extractedLat != null && extractedLng != null;

      setState(() {
        if (foundTimestamp) {
          _observationTimestamp = extractedTimestamp;
          _timestampFromExif = true;
        }
        if (foundCoordinates) {
          _updatePinPosition(LatLng(extractedLat!, extractedLng!));
          _mapController.move(_pinPosition, 15);
          _currentZoom = 15;
          _coordinatesFromExif = true;
        }
      });

      if (!foundTimestamp && !foundCoordinates) {
        _showSnackBar('No timestamp or coordinate metadata found in this image.', isError: false);
      } else if (!foundTimestamp) {
        _showSnackBar('Coordinates extracted from image metadata. No timestamp found.', isError: false);
      } else if (!foundCoordinates) {
        _showSnackBar('Timestamp extracted from image metadata. No coordinates found.', isError: false);
      } else {
        _showSnackBar('Timestamp and coordinates extracted from image metadata.', isError: false);
      }
    } catch (e) {
      _showSnackBar('Failed to read image metadata: $e', isError: true);
    } finally {
      if (mounted) setState(() => _isExtractingExif = false);
    }
  }

  double? _dmsToDecimal(exif_lib.IfdValues values) {
    if (values is! exif_lib.IfdRatios || values.ratios.length < 3) return null;
    final degrees = values.ratios[0].toDouble();
    final minutes = values.ratios[1].toDouble();
    final seconds = values.ratios[2].toDouble();
    return degrees + (minutes / 60) + (seconds / 3600);
  }

  Future<void> _pickDateTime() async {
    final initialDate = _observationTimestamp ?? DateTime.now();
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );
    if (pickedDate == null || !mounted) return;

    final pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initialDate),
    );
    if (pickedTime == null) return;

    setState(() {
      _observationTimestamp = DateTime(
        pickedDate.year,
        pickedDate.month,
        pickedDate.day,
        pickedTime.hour,
        pickedTime.minute,
      );
    });
  }

  Future<void> _saveObservation() async {
    if (_imageBytes == null) {
      _showSnackBar('Please upload a JPG/JPEG photo first.', isError: true);
      return;
    }
    if (_observationTimestamp == null) {
      _showSnackBar('Please set the observation timestamp.', isError: true);
      return;
    }
    final lat = double.tryParse(_latController.text);
    final lng = double.tryParse(_lngController.text);
    if (lat == null || lng == null) {
      _showSnackBar('Please set valid coordinates.', isError: true);
      return;
    }

    setState(() => _isSaving = true);

    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      final id = DateTime.now().microsecondsSinceEpoch.toString();
      final fileName = '${user.id}/$id.jpg';

      await Supabase.instance.client.storage.from('observations').uploadBinary(
            fileName,
            _imageBytes!,
            fileOptions: const FileOptions(cacheControl: '3600', contentType: 'image/jpeg'),
          );
      final imageUrl = Supabase.instance.client.storage.from('observations').getPublicUrl(fileName);

      await Supabase.instance.client.from('observations').insert({
        'user_id': user.id,
        'coordinates': 'POINT($lng $lat)',
        'image_url': imageUrl,
        'observation_timestamp': _observationTimestamp!.toUtc().toIso8601String(),
        'upload_timestamp': DateTime.now().toUtc().toIso8601String(),
        'source': 'WEB',
        'sync_status': 'UPLOADED',
        'is_public': _isPublic,
        'is_anonymous': _isAnonymous,
      });

      if (mounted) {
        _showSnackBar('Observation saved successfully.', isError: false);
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      _showSnackBar('Failed to save observation: $e', isError: true);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  void _showSnackBar(String message, {bool isError = false}) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();

    final screenWidth = MediaQuery.of(context).size.width;
    final leftMargin = screenWidth > 400 ? screenWidth - 360.0 : 16.0;

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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10.0)),
        margin: EdgeInsets.only(
          bottom: 24,
          right: 16,
          left: leftMargin,
        ),
      ),
    );
  }

  bool get _hasUnsavedChanges {
    return _imageBytes != null ||
        _observationTimestamp != null ||
        _latController.text.isNotEmpty ||
        _lngController.text.isNotEmpty;
  }

  Future<bool> _confirmDiscardChanges() async {
    if (!_hasUnsavedChanges) return true;

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Discard Observation?'),
        content: const Text('You have unsaved changes. If you leave now, they will be lost.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep Editing', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Discard', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final dateStr = _observationTimestamp != null
        ? DateFormat.yMMMd().add_jm().format(_observationTimestamp!)
        : 'Not set';

    return PopScope(
      canPop: !_hasUnsavedChanges,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final navigator = Navigator.of(context);
        if (await _confirmDiscardChanges() && mounted) {
          navigator.pop();
        }
      },
      child: Scaffold(
      backgroundColor: Colors.grey[50],
      appBar: AppBar(
        title: const Text('Add Observation', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black87)),
        backgroundColor: Colors.white,
        elevation: 1,
        iconTheme: const IconThemeData(color: Colors.black87),
      ),
      body: Stack(
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: ListView(
                padding: const EdgeInsets.all(24.0),
                children: [
                  _buildSectionCard(
                    title: 'Photo',
                    child: _buildImagePicker(),
                  ),
                  const SizedBox(height: 20),
                  IgnorePointer(
                    ignoring: _imageBytes == null,
                    child: AnimatedOpacity(
                      opacity: _imageBytes == null ? 0.4 : 1.0,
                      duration: const Duration(milliseconds: 200),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                  _buildSectionCard(
                    title: 'Observation Timestamp',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(dateStr, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                            ),
                            if (_timestampFromExif)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                decoration: BoxDecoration(
                                  color: Colors.grey[100],
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: Colors.grey[300]!),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.lock_outline, size: 16, color: Colors.grey[600]),
                                    const SizedBox(width: 6),
                                    Text('From photo metadata', style: TextStyle(fontSize: 12, color: Colors.grey[600], fontWeight: FontWeight.w600)),
                                  ],
                                ),
                              )
                            else
                              OutlinedButton.icon(
                                onPressed: _pickDateTime,
                                icon: const Icon(Icons.edit_calendar_outlined, size: 18),
                                label: const Text('Set Date & Time'),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.green[700],
                                  side: BorderSide(color: Colors.green[700]!),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _timestampFromExif
                              ? 'Extracted from the photo\'s metadata and locked from manual edits.'
                              : 'Automatically filled from photo metadata when available, or set manually.',
                          style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  _buildSectionCard(
                    title: 'Coordinates',
                    child: _buildCoordinatesPicker(),
                  ),
                  const SizedBox(height: 20),
                  _buildSectionCard(
                    title: 'Privacy Settings',
                    child: Column(
                      children: [
                        CheckboxListTile(
                          controlAffinity: ListTileControlAffinity.trailing,
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Public Observation', style: TextStyle(fontWeight: FontWeight.w600)),
                          subtitle: const Text('Allow others to view this observation', style: TextStyle(fontSize: 12)),
                          value: _isPublic,
                          activeColor: Colors.green[700],
                          onChanged: (val) => setState(() => _isPublic = val ?? false),
                        ),
                        const Divider(height: 1),
                        CheckboxListTile(
                          controlAffinity: ListTileControlAffinity.trailing,
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Submit Anonymously', style: TextStyle(fontWeight: FontWeight.w600)),
                          subtitle: const Text('Hide your username from public view', style: TextStyle(fontSize: 12)),
                          value: _isAnonymous,
                          activeColor: Colors.green[700],
                          onChanged: (val) => setState(() => _isAnonymous = val ?? false),
                        ),
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          decoration: BoxDecoration(
                            color: Colors.blue[50],
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.blue[100]!),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.info_outline, color: Colors.blue[800]),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  'Privacy settings can be modified later from the observation\'s details page.',
                                  style: TextStyle(color: Colors.blue[900], fontSize: 13, fontWeight: FontWeight.w500),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 28),
                  ElevatedButton(
                    onPressed: _imageBytes == null || _isSaving ? null : _saveObservation,
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
                        : const Text('Save Observation', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ],
      ),
      ),
    );
  }

  Widget _buildSectionCard({required String title, required Widget child}) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const Divider(height: 24),
            child,
          ],
        ),
      ),
    );
  }

  Widget _buildImagePicker() {
    return Container(
      height: 250,
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.green[50],
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.green[200]!, width: 2),
      ),
      child: _isExtractingExif
          ? Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  width: 180,
                  child: LinearProgressIndicator(
                    color: Colors.green[700],
                    backgroundColor: Colors.green[100],
                    minHeight: 6,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Processing photo...',
                  style: TextStyle(color: Colors.green[700], fontWeight: FontWeight.bold, fontSize: 14),
                ),
              ],
            )
          : _imageBytes != null
              ? Stack(
                  fit: StackFit.expand,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(18),
                      child: GestureDetector(
                        onTap: () => FullScreenImageViewer.show(context, null, imageBytes: _imageBytes),
                        child: Image.memory(_imageBytes!, fit: BoxFit.cover),
                      ),
                    ),
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Container(
                        decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
                        child: IconButton(
                          icon: const Icon(Icons.refresh, color: Colors.white),
                          tooltip: 'Replace photo',
                          onPressed: _pickImage,
                        ),
                      ),
                    ),
                  ],
                )
              : GestureDetector(
                  onTap: _pickImage,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.upload_file_outlined, size: 64, color: Colors.green[300]),
                      const SizedBox(height: 12),
                      Text(
                        'Click to upload a Gall Rust photo',
                        style: TextStyle(color: Colors.green[700], fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'JPG / JPEG only',
                        style: TextStyle(color: Colors.green[400], fontSize: 13),
                      ),
                    ],
                  ),
                ),
    );
  }

  Widget _buildCoordinatesPicker() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_coordinatesFromExif)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.grey[100],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey[300]!),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.lock_outline, size: 16, color: Colors.grey[600]),
                  const SizedBox(width: 6),
                  Text('From photo metadata', style: TextStyle(fontSize: 12, color: Colors.grey[600], fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _latController,
                enabled: !_coordinatesFromExif,
                keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^-?\d*\.?\d*'))],
                decoration: InputDecoration(
                  labelText: 'Latitude',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _lngController,
                enabled: !_coordinatesFromExif,
                keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^-?\d*\.?\d*'))],
                decoration: InputDecoration(
                  labelText: 'Longitude',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  isDense: true,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: SizedBox(
            height: 320,
            child: Stack(
              children: [
                FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: _pinPosition,
                    initialZoom: _currentZoom,
                    minZoom: 2,
                    maxZoom: 18,
                    onTap: _coordinatesFromExif ? null : (tapPos, latlng) => _updatePinPosition(latlng),
                    onPositionChanged: (camera, hasGesture) {
                      _currentZoom = camera.zoom;
                    },
                  ),
                  children: [
                    TileLayer(
                      urlTemplate: _isSatellite
                          ? 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}'
                          : 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Topo_Map/MapServer/tile/{z}/{y}/{x}',
                      userAgentPackageName: 'com.treecon.commander',
                    ),
                    MarkerLayer(
                      markers: [
                        Marker(
                          point: _pinPosition,
                          width: 40,
                          height: 40,
                          child: Icon(Icons.location_pin, color: Colors.red[700], size: 40),
                        ),
                      ],
                    ),
                  ],
                ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: Column(
                    children: [
                      Container(
                        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(4), boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)]),
                        child: IconButton(
                          tooltip: _isSatellite ? 'Map View' : 'Satellite View',
                          icon: Icon(_isSatellite ? Icons.map : Icons.satellite_alt, size: 20),
                          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                          padding: EdgeInsets.zero,
                          onPressed: () => setState(() => _isSatellite = !_isSatellite),
                        ),
                      ),
                    ],
                  ),
                ),
                Positioned(
                  bottom: 8,
                  right: 8,
                  child: Column(
                    children: [
                      Container(
                        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(4), boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)]),
                        child: IconButton(
                          tooltip: 'Zoom in',
                          icon: const Icon(Icons.add, size: 20),
                          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                          padding: EdgeInsets.zero,
                          onPressed: () {
                            _currentZoom = (_currentZoom + 1).clamp(2, 18);
                            _mapController.move(_mapController.camera.center, _currentZoom);
                          },
                        ),
                      ),
                      const SizedBox(height: 4),
                      Container(
                        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(4), boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)]),
                        child: IconButton(
                          tooltip: 'Zoom out',
                          icon: const Icon(Icons.remove, size: 20),
                          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                          padding: EdgeInsets.zero,
                          onPressed: () {
                            _currentZoom = (_currentZoom - 1).clamp(2, 18);
                            _mapController.move(_mapController.camera.center, _currentZoom);
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          _coordinatesFromExif
              ? 'Extracted from the photo\'s metadata and locked from manual edits.'
              : 'Tap the map to move the pin, or edit the coordinate fields directly.',
          style: TextStyle(fontSize: 12, color: Colors.grey[600]),
        ),
      ],
    );
  }
}
