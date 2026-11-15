import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:sidedeck/engine/native_lib.dart';

class TrackAnalysis {
  const TrackAnalysis({
    required this.bpm,
    required this.key,
    required this.beatOffset,
    this.gridConfidence = -1,
  });

  final double bpm;
  final int key;
  final double beatOffset;
  /// Share of kicks on the grid (0..1), or negative when unknown.
  final double gridConfidence;

  /// Below this share of 16-bar windows that agree with the grid, the track is
  /// flagged "check grid". Provisional; to be calibrated on real grids.
  static const unsureBelow = 0.6;
  bool get gridUnsure => gridConfidence >= 0 && gridConfidence < unsureBelow;
}

typedef _AnalyzeC = Int32 Function(
  Pointer<Utf8>,
  Pointer<Float>,
  Pointer<Int32>,
  Pointer<Float>,
  Pointer<Float>,
);

DynamicLibrary _openLib() => openDjEngine();

/// Decode + BPM/key. No deck involved. Safe to call from a worker isolate.
TrackAnalysis? analyzeTrackFile(String path) {
  final lib = _openLib();
  final fn = lib.lookupFunction<_AnalyzeC, int Function(
    Pointer<Utf8>,
    Pointer<Float>,
    Pointer<Int32>,
    Pointer<Float>,
    Pointer<Float>,
  )>('dj_analyze_file');
  final p = path.toNativeUtf8();
  final bpm = malloc<Float>();
  final key = malloc<Int32>();
  final offset = malloc<Float>();
  final confidence = malloc<Float>();
  try {
    if (fn(p, bpm, key, offset, confidence) != 1) {
      return null;
    }
    return TrackAnalysis(
      bpm: bpm.value,
      key: key.value,
      beatOffset: offset.value,
      gridConfidence: confidence.value,
    );
  } finally {
    malloc.free(p);
    malloc.free(bpm);
    malloc.free(key);
    malloc.free(offset);
    malloc.free(confidence);
  }
}

Future<TrackAnalysis?> analyzeTrackFileOffUi(String path) async {
  try {
    return await Isolate.run(() => analyzeTrackFile(path));
  } catch (_) {
    return analyzeTrackFile(path);
  }
}

double fileDurationSec(String path) {
  final lib = _openLib();
  final fn = lib.lookupFunction<Double Function(Pointer<Utf8>), double Function(Pointer<Utf8>)>(
    'dj_file_duration',
  );
  final p = path.toNativeUtf8();
  try {
    return fn(p);
  } finally {
    malloc.free(p);
  }
}
