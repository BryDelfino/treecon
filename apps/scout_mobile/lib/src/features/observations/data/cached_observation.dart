class CachedObservation {
  final String observationId;
  final String? userId;
  final double latitude;
  final double longitude;
  final String? imagePath;
  final DateTime observationTimestamp;
  final String source;
  final String syncStatus;

  CachedObservation({
    required this.observationId,
    this.userId,
    required this.latitude,
    required this.longitude,
    this.imagePath,
    required this.observationTimestamp,
    this.source = 'MOBILE',
    this.syncStatus = 'PENDING',
  });

  Map<String, dynamic> toMap() {
    return {
      'observation_id': observationId,
      'user_id': userId,
      'latitude': latitude,
      'longitude': longitude,
      'image_path': imagePath,
      'observation_timestamp': observationTimestamp.toIso8601String(),
      'source': source,
      'sync_status': syncStatus,
    };
  }

  factory CachedObservation.fromMap(Map<String, dynamic> map) {
    return CachedObservation(
      observationId: map['observation_id'] as String,
      userId: map['user_id'] as String?,
      latitude: map['latitude'] as double,
      longitude: map['longitude'] as double,
      imagePath: map['image_path'] as String?,
      observationTimestamp: DateTime.parse(map['observation_timestamp'] as String),
      source: map['source'] as String? ?? 'mobile',
      syncStatus: map['sync_status'] as String? ?? 'PENDING',
    );
  }
}
