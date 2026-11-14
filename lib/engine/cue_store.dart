import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// Main cue and hot cues saved for one track, in seconds; negative = unset.
class TrackCues {
  const TrackCues({required this.cue, required this.hotCues});

  final double cue;
  final List<double> hotCues;
}

/// Per-track cue points, keyed by file path. Kept apart from the analysis
/// cache, whose schema upgrades drop its table: cues are the user's work.
class CueStore {
  CueStore._();
  static final instance = CueStore._();

  Database? _db;

  Future<Database> _open() async {
    if (_db != null) return _db!;
    final dbPath = await getDatabasesPath();
    _db = await openDatabase(
      p.join(dbPath, 'sidedeck_cues.db'),
      version: 1,
      onCreate: (db, version) => db.execute('''
        CREATE TABLE cues (
          path TEXT PRIMARY KEY NOT NULL,
          cue REAL NOT NULL,
          hot_cues TEXT NOT NULL
        )
      '''),
    );
    return _db!;
  }

  Future<TrackCues?> get(String path) async {
    final db = await _open();
    final rows = await db.query('cues', where: 'path = ?', whereArgs: [path], limit: 1);
    if (rows.isEmpty) return null;
    final row = rows.first;
    // Hot cues are a comma list so the slot count can grow without a migration.
    final hot = (row['hot_cues'] as String? ?? '')
        .split(',')
        .where((s) => s.isNotEmpty)
        .map((s) => double.tryParse(s) ?? -1)
        .toList();
    return TrackCues(cue: (row['cue'] as num?)?.toDouble() ?? -1, hotCues: hot);
  }

  Future<void> put(String path, TrackCues cues) async {
    final db = await _open();
    await db.insert('cues', {
      'path': path,
      'cue': cues.cue,
      'hot_cues': cues.hotCues.join(','),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
}
