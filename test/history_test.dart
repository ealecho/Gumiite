import 'package:flutter_test/flutter_test.dart';
import 'package:sidedeck/engine/history_store.dart';

PlayedTrack _play(String path, DateTime at) => PlayedTrack(
  path: path,
  title: path,
  artist: '',
  bpm: 120,
  key: 0,
  deck: 0,
  playedAt: at,
);

void main() {
  final t0 = DateTime(2026, 11, 14, 21);

  test('plays under the gap form one session; a longer pause starts another', () {
    final plays = [
      _play('a', t0),
      _play('b', t0.add(const Duration(minutes: 6))),
      _play('c', t0.add(const Duration(hours: 2, minutes: 50))),
      _play('d', t0.add(const Duration(hours: 9))), // next morning-ish
    ];
    final sessions = HistoryStore.sessions(plays);
    expect(sessions.length, 2);
    expect(sessions.first.tracks.map((t) => t.path), ['d']); // newest first
    expect(sessions.last.tracks.map((t) => t.path), ['a', 'b', 'c']);
  });

  test('current session is the latest one only while it is recent', () {
    final plays = [_play('a', t0), _play('b', t0.add(const Duration(minutes: 7)))];
    final soon = t0.add(const Duration(hours: 1));
    final later = t0.add(const Duration(hours: 4));
    expect(HistoryStore.currentSession(plays, soon)?.tracks.length, 2);
    expect(HistoryStore.currentSession(plays, later), isNull);
    expect(HistoryStore.currentSession(const [], soon), isNull);
  });
}
