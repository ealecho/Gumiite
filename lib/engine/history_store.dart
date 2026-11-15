import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// One track played out: logged once it has been audible for a while.
class PlayedTrack {
  const PlayedTrack({
    required this.path,
    required this.title,
    required this.artist,
    required this.bpm,
    required this.key,
    required this.deck,
    required this.playedAt,
  });

  final String path;
  final String title;
  final String artist;
  final double bpm;
  final int key;
  final int deck;
  final DateTime playedAt;
}

/// Plays logged one after another with gaps under [HistoryStore.sessionGap].
class PlaySession {
  PlaySession(this.tracks);

  /// Oldest first.
  final List<PlayedTrack> tracks;

  DateTime get start => tracks.first.playedAt;
  DateTime get end => tracks.last.playedAt;
}

/// Play history, kept in its own database (like CueStore) so analysis cache
/// upgrades never touch it.
class HistoryStore {
  HistoryStore._();
  static final instance = HistoryStore._();

  /// A longer pause than this between plays starts a new session.
  static const sessionGap = Duration(hours: 3);

  Database? _db;

  Future<Database> _open() async {
    if (_db != null) return _db!;
    final dbPath = await getDatabasesPath();
    _db = await openDatabase(
      p.join(dbPath, 'sidedeck_history.db'),
      version: 1,
      onCreate: (db, version) => db.execute('''
        CREATE TABLE history (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          path TEXT NOT NULL,
          title TEXT NOT NULL,
          artist TEXT NOT NULL,
          bpm REAL NOT NULL,
          key INTEGER NOT NULL,
          deck INTEGER NOT NULL,
          played_at INTEGER NOT NULL
        )
      '''),
    );
    return _db!;
  }

  Future<void> add(PlayedTrack t) async {
    final db = await _open();
    await db.insert('history', {
      'path': t.path,
      'title': t.title,
      'artist': t.artist,
      'bpm': t.bpm,
      'key': t.key,
      'deck': t.deck,
      'played_at': t.playedAt.millisecondsSinceEpoch,
    });
  }

  /// The most recent plays, oldest first.
  Future<List<PlayedTrack>> recent({int limit = 1000}) async {
    final db = await _open();
    final rows = await db.query('history', orderBy: 'played_at DESC, id DESC', limit: limit);
    return [
      for (final r in rows.reversed)
        PlayedTrack(
          path: r['path'] as String,
          title: r['title'] as String,
          artist: r['artist'] as String,
          bpm: (r['bpm'] as num).toDouble(),
          key: r['key'] as int,
          deck: r['deck'] as int,
          playedAt: DateTime.fromMillisecondsSinceEpoch(r['played_at'] as int),
        ),
    ];
  }

  Future<void> clear() async {
    final db = await _open();
    await db.delete('history');
  }

  /// Splits plays (oldest first) into sessions, newest session first.
  static List<PlaySession> sessions(List<PlayedTrack> plays) {
    final out = <PlaySession>[];
    var current = <PlayedTrack>[];
    for (final t in plays) {
      if (current.isNotEmpty && t.playedAt.difference(current.last.playedAt) > sessionGap) {
        out.add(PlaySession(current));
        current = [];
      }
      current.add(t);
    }
    if (current.isNotEmpty) out.add(PlaySession(current));
    return out.reversed.toList();
  }

  /// The session still going at [now], if any: its last play is recent enough.
  static PlaySession? currentSession(List<PlayedTrack> plays, DateTime now) {
    final all = sessions(plays);
    if (all.isEmpty) return null;
    final latest = all.first;
    return now.difference(latest.end) <= sessionGap ? latest : null;
  }
}
