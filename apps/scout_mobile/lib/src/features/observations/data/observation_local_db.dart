import 'dart:async';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'cached_observation.dart';

class ObservationLocalDb {
  ObservationLocalDb._internal();
  static final ObservationLocalDb instance = ObservationLocalDb._internal();

  Database? _database;
  final StreamController<int> _pendingCountController = StreamController<int>.broadcast();

  Stream<int> get pendingCountStream => _pendingCountController.stream;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDb();
    return _database!;
  }

  Future<Database> _initDb() async {
    final documentsDirectory = await getApplicationDocumentsDirectory();
    final path = join(documentsDirectory.path, 'treecon_scout.db');
    return await openDatabase(
      path,
      version: 2,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE cached_observations (
        observation_id TEXT PRIMARY KEY,
        user_id TEXT,
        latitude REAL NOT NULL,
        longitude REAL NOT NULL,
        image_path TEXT,
        observation_timestamp TEXT NOT NULL,
        source TEXT NOT NULL,
        sync_status TEXT NOT NULL,
        is_public INTEGER DEFAULT 1,
        is_anonymous INTEGER DEFAULT 0
      )
    ''');
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('ALTER TABLE cached_observations ADD COLUMN is_public INTEGER DEFAULT 1;');
      await db.execute('ALTER TABLE cached_observations ADD COLUMN is_anonymous INTEGER DEFAULT 0;');
    }
  }

  Future<void> open() async {
    await database;
    await updatePendingCount();
  }

  Future<int> insertObservation(CachedObservation observation) async {
    final db = await database;
    final res = await db.insert(
      'cached_observations',
      observation.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await updatePendingCount();
    return res;
  }

  Future<List<CachedObservation>> getAllLocal() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'cached_observations',
      orderBy: 'observation_timestamp DESC',
    );
    return List.generate(maps.length, (i) => CachedObservation.fromMap(maps[i]));
  }

  Future<List<CachedObservation>> getPending() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'cached_observations',
      where: 'sync_status != ?',
      whereArgs: ['UPLOADED'],
    );
    return List.generate(maps.length, (i) => CachedObservation.fromMap(maps[i]));
  }

  Future<CachedObservation?> getById(String observationId) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'cached_observations',
      where: 'observation_id = ?',
      whereArgs: [observationId],
    );
    if (maps.isEmpty) return null;
    return CachedObservation.fromMap(maps.first);
  }

  Future<void> deleteObservation(String observationId) async {
    final db = await database;
    await db.delete(
      'cached_observations',
      where: 'observation_id = ?',
      whereArgs: [observationId],
    );
    await updatePendingCount();
  }

  Future<void> updateObservationSettings(String observationId, bool isPublic, bool isAnonymous) async {
    final db = await database;
    await db.update(
      'cached_observations',
      {
        'is_public': isPublic ? 1 : 0,
        'is_anonymous': isAnonymous ? 1 : 0,
      },
      where: 'observation_id = ?',
      whereArgs: [observationId],
    );
  }

  Future<void> markFailed(String observationId) async {
    final db = await database;
    await db.update(
      'cached_observations',
      {'sync_status': 'FAILED'},
      where: 'observation_id = ?',
      whereArgs: [observationId],
    );
    await updatePendingCount();
  }

  Future<void> updatePendingCount() async {
    final db = await database;
    final result = await db.rawQuery(
      "SELECT COUNT(*) FROM cached_observations WHERE sync_status != 'UPLOADED'"
    );
    final count = Sqflite.firstIntValue(result) ?? 0;
    _pendingCountController.add(count);
  }
}
