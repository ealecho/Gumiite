import 'dart:math' as math;
import 'dart:typed_data';

/// CDJ "Auto Cue": where to park the cue on load. The first grid beat at the
/// first sound, so leading silence is skipped and CUE starts on the beat.
///
/// The first sound is the first band column with any band at or above
/// [threshold] (bands are 0..127). A beat up to a quarter beat before it still
/// counts, as a soft attack can rise just after its beat. Without a grid it is
/// the first sound itself; with no sound at all, 0.
double autoCuePoint(
  Uint8List bands,
  int columnsPerSec,
  double bpm,
  double beatOffset,
  double duration, {
  int threshold = 8,
}) {
  final cols = bands.length ~/ 3;
  if (cols == 0 || columnsPerSec <= 0 || duration <= 0) return 0;
  var first = -1;
  for (var c = 0; c < cols; c++) {
    if (bands[c * 3] >= threshold || bands[c * 3 + 1] >= threshold || bands[c * 3 + 2] >= threshold) {
      first = c;
      break;
    }
  }
  if (first < 0) return 0;
  final sound = first / columnsPerSec;
  if (bpm < 40) return math.min(sound, duration);
  final beat = 60.0 / bpm;
  final k = ((sound - beatOffset - beat / 4) / beat).ceil();
  final t = beatOffset + k * beat;
  return t < 0 ? 0 : math.min(t, duration);
}
