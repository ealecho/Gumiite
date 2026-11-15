import 'package:flutter_test/flutter_test.dart';
import 'package:sidedeck/engine/music_utils.dart';
import 'package:sidedeck/subsonic/subsonic_client.dart';

void main() {
  test('formatDuration', () {
    expect(formatDuration(65), '1:05');
    expect(formatDuration(0), '0:00');
  });

  test('formatKey', () {
    expect(formatKey(-1), '—');
    final before = keyNotation;
    try {
      keyNotation = KeyNotation.camelot; // the default
      expect(formatKey(0), '8B');
      expect(formatKey(21), '8A');
      keyNotation = KeyNotation.musical;
      expect(formatKey(0), 'C');
      expect(formatKey(21), 'Am');
      keyNotation = KeyNotation.both;
      expect(formatKey(21), 'Am / 8A');
    } finally {
      keyNotation = before;
    }
  });

  test('Subsonic jsonMaps unwraps a single object', () {
    expect(SubsonicClient.jsonMaps(null), isEmpty);
    expect(
      SubsonicClient.jsonMaps({'id': '1', 'name': 'Sets'}),
      [
        {'id': '1', 'name': 'Sets'},
      ],
    );
    expect(
      SubsonicClient.jsonMaps([
        {'id': '1'},
        {'id': '2'},
      ]),
      [
        {'id': '1'},
        {'id': '2'},
      ],
    );
  });

  test('Subsonic playlist and track JSON', () {
    final pl = SubsonicPlaylist.fromJson({
      'id': 12,
      'name': 'Warmup',
      'owner': 'dj',
      'songCount': 8,
      'duration': 1800,
    });
    expect(pl.id, '12');
    expect(pl.name, 'Warmup');
    expect(pl.songCount, 8);

    final track = SubsonicTrack.fromJson({
      'id': 'song-1',
      'title': 'Track',
      'artist': 'Artist',
      'album': 'LP',
      'duration': 200,
      'suffix': 'mp3',
    });
    expect(track.id, 'song-1');
    expect(track.suffix, 'mp3');
  });
}

