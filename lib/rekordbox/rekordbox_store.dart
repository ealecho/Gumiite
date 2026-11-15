import 'package:path/path.dart' as p;
import 'package:sidedeck/engine/track_analyzer.dart';
import 'package:sqflite/sqflite.dart';

/// A track imported from a rekordbox USB stick.
class StickTrack {
  const StickTrack({
    required this.path,
    required this.relPath,
    required this.title,
    required this.artist,
    required this.album,
    required this.durationSec,
    required this.bpm,
    required this.key,
    required this.beatOffset,
    required this.gridConfidence,
  });

  /// Identity used by the decks, cues and analysis: the audio's filesystem
  /// path on the stick when Android exposes one, else `stick:<relPath>`.
  final String path;

  /// Audio path relative to the stick root, e.g. `/Contents/A/B/x.mp3`.
  final String relPath;
  final String title;
  final String artist;
  final String album;
  final int durationSec;
  final double bpm;
  final int key;
  final double beatOffset;
  final double gridConfidence;

  TrackAnalysis get analysis => TrackAnalysis(
    bpm: bpm,
    key: key,
    beatOffset: beatOffset,
    gridConfidence: gridConfidence,
  );
}

class StickPlaylist {
  const StickPlaylist({
    required this.id,
    required this.parentId,
    required this.name,
    required this.isFolder,
    required this.sortOrder,
    required this.trackPaths,
  });

  final int id;
  final int parentId;
  final String name;
  final bool isFolder;
  final int sortOrder;
  final List<String> trackPaths;
}

/// The last imported stick: where it is, its tracks and playlists. One stick
/// at a time; importing again replaces it. Analysis and cues taken from it are
/// kept here and in CueStore, so they survive the stick being unplugged.
class RekordboxStore {
  RekordboxStore._();
  static final instance = RekordboxStore._();

  Database? _db;

  Future<Database> _open() async {
    if (_db != null) return _db!;
    final dir = await getDatabasesPath();
    _db = await openDatabase(
      p.join(dir, 'sidedeck_rekordbox.db'),
      version: 1,
      onCreate: (db, version) async {
        await db.execute('CREATE TABLE stick (k INTEGER PRIMARY KEY, tree TEXT, base_path TEXT, imported INTEGER)');
        await db.execute('''
          CREATE TABLE tracks (
            path TEXT PRIMARY KEY NOT NULL, rel TEXT NOT NULL, title TEXT, artist TEXT,
            album TEXT, duration_sec INTEGER, bpm REAL, key_idx INTEGER,
            beat_offset REAL, grid_conf REAL, sort INTEGER
          )
        ''');
        await db.execute(
          'CREATE TABLE playlists (id INTEGER PRIMARY KEY, parent INTEGER, name TEXT, folder INTEGER, sort INTEGER)',
        );
        await db.execute('CREATE TABLE playlist_tracks (playlist INTEGER, idx INTEGER, path TEXT)');
      },
    );
    return _db!;
  }

  Future<void> replace({
    required String tree,
    required String basePath,
    required List<StickTrack> tracks,
    required List<StickPlaylist> playlists,
  }) async {
    final db = await _open();
    await db.transaction((tx) async {
      for (final t in ['stick', 'tracks', 'playlists', 'playlist_tracks']) {
        await tx.delete(t);
      }
      await tx.insert('stick', {
        'k': 1,
        'tree': tree,
        'base_path': basePath,
        'imported': DateTime.now().millisecondsSinceEpoch,
      });
      final batch = tx.batch();
      for (var i = 0; i < tracks.length; i++) {
        final t = tracks[i];
        batch.insert('tracks', {
          'path': t.path,
          'rel': t.relPath,
          'title': t.title,
          'artist': t.artist,
          'album': t.album,
          'duration_sec': t.durationSec,
          'bpm': t.bpm,
          'key_idx': t.key,
          'beat_offset': t.beatOffset,
          'grid_conf': t.gridConfidence,
          'sort': i,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final pl in playlists) {
        batch.insert('playlists', {
          'id': pl.id,
          'parent': pl.parentId,
          'name': pl.name,
          'folder': pl.isFolder ? 1 : 0,
          'sort': pl.sortOrder,
        });
        for (var i = 0; i < pl.trackPaths.length; i++) {
          batch.insert('playlist_tracks', {'playlist': pl.id, 'idx': i, 'path': pl.trackPaths[i]});
        }
      }
      await batch.commit(noResult: true);
    });
  }

  /// The stick's SAF tree and base path, or null if none was imported.
  Future<({String tree, String basePath})?> stick() async {
    final db = await _open();
    final rows = await db.query('stick', limit: 1);
    if (rows.isEmpty) return null;
    return (tree: rows.first['tree'] as String, basePath: rows.first['base_path'] as String? ?? '');
  }

  Future<List<StickTrack>> tracks() async {
    final db = await _open();
    final rows = await db.query('tracks', orderBy: 'sort');
    return [for (final r in rows) _track(r)];
  }

  Future<List<StickPlaylist>> playlists() async {
    final db = await _open();
    final lists = await db.query('playlists', orderBy: 'parent, sort');
    final entries = await db.query('playlist_tracks', orderBy: 'playlist, idx');
    final byList = <int, List<String>>{};
    for (final e in entries) {
      byList.putIfAbsent(e['playlist'] as int, () => []).add(e['path'] as String);
    }
    return [
      for (final r in lists)
        StickPlaylist(
          id: r['id'] as int,
          parentId: r['parent'] as int? ?? 0,
          name: r['name'] as String? ?? '',
          isFolder: (r['folder'] as int? ?? 0) != 0,
          sortOrder: r['sort'] as int? ?? 0,
          trackPaths: byList[r['id'] as int] ?? const [],
        ),
    ];
  }

  /// Imported analysis for a deck path, which takes precedence over
  /// SideDeck's own: it is what the user prepared in rekordbox.
  Future<StickTrack?> track(String path) async {
    final db = await _open();
    final rows = await db.query('tracks', where: 'path = ?', whereArgs: [path], limit: 1);
    return rows.isEmpty ? null : _track(rows.first);
  }

  /// A grid fixed by hand on the deck: keep it (and drop "check grid"). No-op
  /// for tracks that weren't imported.
  Future<void> updateGrid(String path, double beatOffset, {double? bpm}) async {
    final db = await _open();
    await db.update(
      'tracks',
      {'beat_offset': beatOffset, 'grid_conf': -1, 'bpm': ?bpm},
      where: 'path = ?',
      whereArgs: [path],
    );
  }

  StickTrack _track(Map<String, Object?> r) => StickTrack(
    path: r['path'] as String,
    relPath: r['rel'] as String,
    title: r['title'] as String? ?? '',
    artist: r['artist'] as String? ?? '',
    album: r['album'] as String? ?? '',
    durationSec: r['duration_sec'] as int? ?? 0,
    bpm: (r['bpm'] as num?)?.toDouble() ?? 0,
    key: r['key_idx'] as int? ?? -1,
    beatOffset: (r['beat_offset'] as num?)?.toDouble() ?? 0,
    gridConfidence: (r['grid_conf'] as num?)?.toDouble() ?? -1,
  );
}
