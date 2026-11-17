import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sidedeck/engine/auto_cue.dart';

const _cps = 150;

/// Silence for [leadSec], then sound to [durSec].
Uint8List _bands(double leadSec, double durSec) {
  final cols = (durSec * _cps).ceil();
  final b = Uint8List(cols * 3);
  for (var c = (leadSec * _cps).round(); c < cols; c++) {
    b[c * 3] = 90;
  }
  return b;
}

void main() {
  // 120 BPM: a beat every 0.5 s, grid anchored at 0.1 s.
  test('skips leading silence to the first beat at the sound', () {
    expect(autoCuePoint(_bands(2.1, 30), _cps, 120, 0.1, 30), closeTo(2.1, 1e-9));
  });

  test('a sound just after its beat cues that beat', () {
    expect(autoCuePoint(_bands(2.2, 30), _cps, 120, 0.1, 30), closeTo(2.1, 1e-9));
  });

  test('a sound well past a beat cues the next one', () {
    expect(autoCuePoint(_bands(2.4, 30), _cps, 120, 0.1, 30), closeTo(2.6, 1e-9));
  });

  test('music from the start cues the first beat', () {
    expect(autoCuePoint(_bands(0, 30), _cps, 120, 0.1, 30), closeTo(0.1, 1e-9));
  });

  test('without a grid, the first sound', () {
    expect(autoCuePoint(_bands(1.5, 30), _cps, 0, 0, 30), closeTo(1.5, 1e-9));
  });

  test('silence everywhere stays at 0', () {
    expect(autoCuePoint(Uint8List(300), _cps, 120, 0.1, 2), 0);
  });
}
