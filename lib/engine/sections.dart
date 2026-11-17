import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// What a stretch of the track is doing, from the low band (kick + bass).
enum SectionKind {
  /// Before the bass first comes in.
  intro('INTRO'),

  /// The first stretch with the full low end (when there is an intro).
  main('MAIN'),

  /// The bass back in after a breakdown.
  drop('DROP'),

  /// The low end pulled out mid-track.
  breakdown('BREAK'),

  /// From the last time the bass goes to the end.
  outro('OUTRO');

  const SectionKind(this.label);
  final String label;

  bool get hasBass => this == main || this == drop;
}

class TrackSection {
  const TrackSection(this.kind, this.start, this.end, this.startBar, this.bars);

  final SectionKind kind;

  /// Seconds into the file, on a downbeat of the grid.
  final double start;
  final double end;

  /// Bar index on the grid (0 = the grid's bar 1, as the bar counter shows it).
  final int startBar;
  final int bars;

  @override
  String toString() => '${kind.label}@${startBar + 1}x$bars';
}

/// Sections found from the band waveform and the beat grid.
///
/// Each bar gets the mean of its low band. Bars at or above [bassShare] of the
/// track's typical loud bar (its [refPercentile]) have the bass in. Runs of
/// fewer than [minBars] are fills or kick drops and fold into their
/// neighbours, and a change within a bar of a 4-bar line moves onto it, as
/// house tracks change on phrase lines and a fill just before one would pull
/// the change early. So it is only as right as the grid: a wrong downbeat
/// moves every boundary with it.
List<TrackSection> detectSections(
  Uint8List bands,
  int columnsPerSec,
  double bpm,
  double beatOffset,
  double duration, {
  double bassShare = 0.55,
  double refPercentile = 0.8,
  int minBars = 4,
}) {
  final cols = bands.length ~/ 3;
  if (cols == 0 || columnsPerSec <= 0 || bpm < 40 || duration <= 0) return const [];
  final barSec = 240.0 / bpm;
  // Bar 0 is the grid's bar 1; earlier (negative) bars cover any lead-in.
  final first = -(beatOffset / barSec).ceil();
  final last = ((duration - beatOffset) / barSec).ceil() - 1;
  final n = last - first + 1;
  if (n < minBars * 2) return const [];

  final low = Float64List(n);
  for (var i = 0; i < n; i++) {
    final t0 = beatOffset + (first + i) * barSec;
    final c0 = (math.max(t0, 0.0) * columnsPerSec).floor().clamp(0, cols);
    final c1 = ((t0 + barSec) * columnsPerSec).floor().clamp(0, cols);
    if (c1 <= c0) continue;
    var sum = 0;
    for (var c = c0; c < c1; c++) {
      sum += bands[c * 3];
    }
    low[i] = sum / (c1 - c0);
  }

  final sorted = Float64List.fromList(low)..sort();
  final ref = sorted[((n - 1) * refPercentile).round()];
  if (ref <= 0) return const [];
  final bass = [for (final v in low) v >= ref * bassShare];

  // Runs of (hasBass, length), shortest short run folded first.
  final runs = <List<Object>>[];
  for (final b in bass) {
    if (runs.isNotEmpty && runs.last[0] == b) {
      runs.last[1] = (runs.last[1] as int) + 1;
    } else {
      runs.add([b, 1]);
    }
  }
  while (runs.length > 1) {
    var shortest = -1;
    for (var i = 0; i < runs.length; i++) {
      final len = runs[i][1] as int;
      if (len < minBars && (shortest < 0 || len < (runs[shortest][1] as int))) shortest = i;
    }
    if (shortest < 0) break;
    runs[shortest][0] = !(runs[shortest][0] as bool);
    // Merge with whichever neighbours now match.
    for (var i = runs.length - 1; i > 0; i--) {
      if (runs[i][0] == runs[i - 1][0]) {
        runs[i - 1][1] = (runs[i - 1][1] as int) + (runs[i][1] as int);
        runs.removeAt(i);
      }
    }
  }

  // Boundaries as bar indices, snapped to the 4-bar lines when within a bar.
  final bounds = <int>[0];
  var at = 0;
  for (final r in runs) {
    at += r[1] as int;
    bounds.add(at);
  }
  for (var i = 1; i < bounds.length - 1; i++) {
    final bar = first + bounds[i];
    final snapped = (bar / 4).round() * 4;
    final moved = snapped - first;
    if ((snapped - bar).abs() <= 1 && moved > bounds[i - 1] && moved < bounds[i + 1]) {
      bounds[i] = moved;
    }
  }

  final out = <TrackSection>[];
  var afterBreak = false;
  for (var i = 0; i < runs.length; i++) {
    final hasBass = runs[i][0] as bool;
    final SectionKind kind;
    if (hasBass) {
      kind = afterBreak ? SectionKind.drop : SectionKind.main;
    } else if (i == 0) {
      kind = SectionKind.intro;
    } else if (i == runs.length - 1) {
      kind = SectionKind.outro;
    } else {
      kind = SectionKind.breakdown;
    }
    if (!hasBass && i > 0) afterBreak = true;
    final b0 = first + bounds[i];
    final b1 = first + bounds[i + 1];
    out.add(
      TrackSection(
        kind,
        math.max(0.0, beatOffset + b0 * barSec),
        math.min(duration, beatOffset + b1 * barSec),
        b0,
        b1 - b0,
      ),
    );
  }
  // A track that has the bass all the way through has nothing to mark.
  if (out.length == 1) return const [];
  return out;
}

class _Memo {
  _Memo(this.bpm, this.beatOffset, this.duration, this.sections);
  final double bpm;
  final double beatOffset;
  final double duration;
  final List<TrackSection> sections;
}

final _memo = Expando<_Memo>('sections');

/// [detectSections] for a deck's band waveform, recomputed only when the
/// waveform or the grid changes (so a grid fix moves the sections with it).
List<TrackSection> sectionsFor(
  Uint8List bands,
  int columnsPerSec,
  double bpm,
  double beatOffset,
  double duration,
) {
  if (bands.isEmpty) return const [];
  final m = _memo[bands];
  if (m != null && m.bpm == bpm && m.beatOffset == beatOffset && m.duration == duration) {
    return m.sections;
  }
  final s = detectSections(bands, columnsPerSec, bpm, beatOffset, duration);
  _memo[bands] = _Memo(bpm, beatOffset, duration, s);
  if (kDebugMode) debugPrint('sidedeck sections bpm=${bpm.toStringAsFixed(2)} $s');
  return s;
}
