import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sidedeck/engine/sections.dart';

const _cps = 150;
const _bpm = 120.0; // 2 s bars

/// Bands for a track given as (bars, low level) stretches, after [lead] s.
(Uint8List, double) _track(List<(int, int)> parts, {double lead = 0}) {
  final bars = parts.fold(0, (n, p) => n + p.$1);
  final dur = lead + bars * 2.0;
  final cols = (dur * _cps).ceil();
  final b = Uint8List(cols * 3);
  var t = lead;
  for (final (n, level) in parts) {
    final c0 = (t * _cps).floor();
    final c1 = ((t + n * 2.0) * _cps).floor().clamp(0, cols);
    for (var c = c0; c < c1; c++) {
      b[c * 3] = level;
      b[c * 3 + 1] = 40;
    }
    t += n * 2.0;
  }
  return (b, dur);
}

void main() {
  test('intro, main, breakdown, drop, outro on bar lines', () {
    final (bands, dur) = _track([(16, 8), (31, 100), (1, 10), (16, 12), (32, 100), (16, 8)]);
    final s = detectSections(bands, _cps, _bpm, 0, dur);
    expect(s.map((x) => x.kind), [
      SectionKind.intro,
      SectionKind.main,
      SectionKind.breakdown,
      SectionKind.drop,
      SectionKind.outro,
    ]);
    // The one-bar fill before the breakdown moves onto the 4-bar line.
    expect(s.map((x) => x.startBar), [0, 16, 48, 64, 96]);
    expect(s[3].start, 128.0);
  });

  test('a short kick drop is not a breakdown', () {
    final (bands, dur) = _track([(16, 8), (14, 100), (2, 10), (32, 100), (16, 8)]);
    final s = detectSections(bands, _cps, _bpm, 0, dur);
    expect(s.map((x) => x.kind), [SectionKind.intro, SectionKind.main, SectionKind.outro]);
  });

  test('bass all the way through marks nothing', () {
    final (bands, dur) = _track([(64, 100)]);
    expect(detectSections(bands, _cps, _bpm, 0, dur), isEmpty);
  });

  test('follows the grid offset', () {
    final (bands, dur) = _track([(16, 8), (32, 100), (16, 8), (32, 100), (16, 8)], lead: 0.5);
    final s = detectSections(bands, _cps, _bpm, 0.5, dur);
    expect(s[1].start, closeTo(32.5, 1e-9));
    expect(s[3].kind, SectionKind.drop);
    expect(s[2].start, closeTo(96.5, 1e-9));
    expect(s[3].start, closeTo(128.5, 1e-9));
  });

  test('memo recomputes when the grid moves', () {
    final (bands, dur) = _track([(16, 8), (32, 100), (16, 8)]);
    final a = sectionsFor(bands, _cps, _bpm, 0, dur);
    expect(identical(a, sectionsFor(bands, _cps, _bpm, 0, dur)), isTrue);
    expect(identical(a, sectionsFor(bands, _cps, _bpm, 0.25, dur)), isFalse);
  });
}
