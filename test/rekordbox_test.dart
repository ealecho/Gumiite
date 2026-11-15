import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sidedeck/rekordbox/anlz_reader.dart';
import 'package:sidedeck/rekordbox/pdb_reader.dart';
import 'package:sidedeck/rekordbox/rekordbox_import.dart';

// Synthetic files laid out per Deep Symmetry's export analysis and rbxport's
// reader. They check the readers against that layout; a real rekordbox stick
// is still the final word.

class _Be {
  final _b = BytesBuilder();
  void u8(int v) => _b.addByte(v & 0xFF);
  void u16(int v) => _b.add([(v >> 8) & 0xFF, v & 0xFF]);
  void u32(int v) => _b.add([(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF]);
  void tag(String s) => _b.add(s.codeUnits);
  void zeros(int n) => _b.add(List.filled(n, 0));
  int get length => _b.length;
  Uint8List bytes() => _b.toBytes();
}

Uint8List _anlz({required List<(int, int, int)> beats, required List<(int, int, int, int)> cues}) {
  final body = _Be();
  // PQTZ: frame (12) + u32 0 + u32 unknown + u32 count = header 24.
  body.tag('PQTZ');
  body.u32(24);
  body.u32(24 + 8 * beats.length);
  body.u32(0);
  body.u32(0x00800000);
  body.u32(beats.length);
  for (final (n, tempo, ms) in beats) {
    body.u16(n);
    body.u16(tempo);
    body.u32(ms);
  }
  // PCO2 with PCP2 entries of 0x2C bytes (no comment).
  const entry = 0x2C;
  body.tag('PCO2');
  body.u32(20);
  body.u32(20 + entry * cues.length);
  body.u32(1);
  body.u16(cues.length);
  body.u16(0);
  for (final (hot, kind, ms, loopEnd) in cues) {
    final start = body.length;
    body.tag('PCP2');
    body.u32(0x10);
    body.u32(entry);
    body.u32(hot);
    body.u8(kind);
    body.zeros(3);
    body.u32(ms);
    body.u32(loopEnd);
    body.zeros(entry - (body.length - start));
  }
  final file = _Be();
  file.tag('PMAI');
  file.u32(28);
  file.u32(28 + body.length);
  file.zeros(16);
  final out = BytesBuilder()
    ..add(file.bytes())
    ..add(body.bytes());
  return out.toBytes();
}

void main() {
  test('ANLZ: beat grid and extended cues', () {
    final f = AnlzReader(_anlz(
      beats: [(1, 12000, 500), (2, 12000, 1000), (3, 12000, 1500)],
      cues: [(0, 1, 2000, 0xFFFFFFFF), (1, 1, 4000, 0xFFFFFFFF), (2, 2, 8000, 10000)],
    )).read()!;
    expect(f.beats.length, 3);
    expect(f.beats.first.beatInBar, 1);
    expect(f.beats.first.tempo, 120.0);
    expect(f.beats[1].timeSec, 1.0);
    expect(f.extendedCues, isTrue);
    expect(f.cues.map((c) => c.hotCue), [0, 1, 2]);
    expect(f.cues[0].isLoop, isFalse);
    expect(f.cues[2].loopEndSec, 10.0);
  });

  test('ANLZ: not an analysis file', () {
    expect(AnlzReader(Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12])).read(), isNull);
  });

  List<AnlzBeat> grid(double bpm, double first, int n, {int startBeat = 1}) => [
    for (var i = 0; i < n; i++)
      AnlzBeat((startBeat - 1 + i) % 4 + 1, bpm, ((first + i * 60 / bpm) * 1000).round() / 1000),
  ];

  test('grid: constant rekordbox grid keeps its stated tempo', () {
    final g = gridFromBeats(grid(124.0, 0.123, 400))!;
    expect(g.constant, isTrue);
    expect(g.bpm, 124.0);
    expect(g.beatOffset, closeTo(0.123, 0.002));
  });

  test('grid: offset lands on a downbeat, not the first beat', () {
    final g = gridFromBeats(grid(120.0, 0.25, 64, startBeat: 3))!;
    // Beats: 0.25 (3), 0.75 (4), 1.25 (1) -> downbeat 1.25, minus one 2 s bar
    // is negative, so 1.25 stays.
    expect(g.beatOffset, closeTo(1.25, 0.002));
  });

  test('grid: a tempo change is not constant', () {
    final beats = [...grid(120.0, 0.0, 64), ...grid(126.0, 32.0, 64)];
    final g = gridFromBeats(beats)!;
    expect(g.constant, isFalse);
    expect(g.bpm, closeTo(120.0, 0.01));
  });

  test('keys: names, Camelot and Open Key', () {
    expect(keyFromName('C'), 0);
    expect(keyFromName('Am'), 21);
    expect(keyFromName('F#m'), 18);
    expect(keyFromName('Ebm'), 15);
    expect(keyFromName('8A'), 21); // A minor
    expect(keyFromName('8B'), 0); // C major
    expect(keyFromName('1d'), 0); // Open Key 1d = C major
    expect(keyFromName('1m'), 21); // Open Key 1m = A minor
    expect(keyFromName(''), -1);
  });

  test('PDB: one track, one key, one artist', () {
    const pageSize = 4096;
    final file = Uint8List(pageSize * 4);
    final b = ByteData.sublistView(file);
    void u32(int at, int v) => b.setUint32(at, v, Endian.little);
    void u16(int at, int v) => b.setUint16(at, v, Endian.little);

    u32(0x04, pageSize);
    u32(0x08, 3);
    // Tables: tracks (0) on page 1, artists (2) on page 2, keys (5) on page 3.
    for (final (i, type, page) in [(0, 0, 1), (1, 2, 2), (2, 5, 3)]) {
      u32(0x1C + i * 16, type);
      u32(0x1C + i * 16 + 8, page);
      u32(0x1C + i * 16 + 12, page);
    }

    // A data page with one row at offset 0 (relative to page + 0x28).
    void onePage(int page, void Function(int row) write) {
      final at = page * pageSize;
      file[at + 0x18] = 1; // one row index entry
      file[at + 0x1B] = 0x24; // data page
      final base = at + pageSize;
      u16(base - 4, 1); // row 0 present
      u16(base - 6, 0); // row 0 at offset 0
      write(at + 0x28);
    }

    void shortAscii(int at, String s) {
      file[at] = ((s.length + 1) << 1) | 1;
      for (var i = 0; i < s.length; i++) {
        file[at + 1 + i] = s.codeUnitAt(i);
      }
    }

    onePage(1, (r) {
      u32(r + 0x20, 7); // key id
      u32(r + 0x38, 12345); // 123.45 BPM
      u32(r + 0x44, 3); // artist id
      u32(r + 0x48, 42); // track id
      u16(r + 0x54, 321); // seconds
      // Strings after the 21 offsets (0x5E + 42 = 0x88).
      const title = 0x90, path = 0xA0, anlz = 0xC0;
      for (var i = 0; i < 21; i++) {
        u16(r + 0x5E + 2 * i, 0x88); // empty string by default
      }
      file[r + 0x88] = 0x03; // empty short ASCII
      u16(r + 0x5E + 2 * 17, title);
      u16(r + 0x5E + 2 * 20, path);
      u16(r + 0x5E + 2 * 14, anlz);
      shortAscii(r + title, 'Apollo');
      shortAscii(r + path, '/Contents/A/apollo.mp3');
      shortAscii(r + anlz, '/PIONEER/USBANLZ/P001/0000/ANLZ0000.DAT');
    });
    onePage(2, (r) {
      u16(r, 0x60); // subtype: u8 name offset at +9
      u32(r + 4, 3);
      file[r + 9] = 0x10;
      shortAscii(r + 0x10, 'Sooks');
    });
    onePage(3, (r) {
      u32(r, 7);
      shortAscii(r + 8, 'Fm');
    });

    final lib = PdbReader(file).read();
    expect(lib.tracks.length, 1);
    final t = lib.tracks.single;
    expect(t.id, 42);
    expect(t.title, 'Apollo');
    expect(t.tempo, 123.45);
    expect(t.durationSec, 321);
    expect(t.filePath, '/Contents/A/apollo.mp3');
    expect(t.analyzePath, '/PIONEER/USBANLZ/P001/0000/ANLZ0000.DAT');
    expect(lib.artists[t.artistId], 'Sooks');
    expect(lib.keys[t.keyId], 'Fm');
  });
}
