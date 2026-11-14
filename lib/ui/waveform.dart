import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

/// 3-band DJ waveform after rbxport (https://github.com/chrisle/rbxport,
/// GPL-2.0-or-later): overview strip plus a scrolling detail with the playhead
/// pinned center. Bands are low/mid/high bytes (0..127) per column.
///
/// With [hangDown] false (deck A) the overview sits on top and the detail rises
/// from the bottom edge; with [hangDown] true (deck B) the overview moves to the
/// bottom and the detail hangs from the top edge, so two decks stacked on top of
/// each other meet at a shared center line.
class WaveformPainter extends CustomPainter {
  WaveformPainter({
    required this.detail,
    required this.overview,
    required this.columnsPerSec,
    required this.position,
    required this.duration,
    required this.beatOffset,
    required this.bpm,
    this.hangDown = false,
    this.rate = 1,
    this.loopEnabled = false,
    this.loopStart = 0,
    this.loopEnd = 0,
    this.zoomWindowSec = 8,
    this.showJumpZone = false,
  });

  final Uint8List detail;
  final Uint8List overview;
  final int columnsPerSec;
  final double position;
  final double duration;
  final double beatOffset;
  final double bpm;
  final bool hangDown;
  /// Playback rate (file seconds per heard second). Zooms the scrolling
  /// waveform in heard-time so synced decks share a beat grid.
  final double rate;
  final bool loopEnabled;
  final double loopStart;
  final double loopEnd;
  final double zoomWindowSec;
  final bool showJumpZone;

  static const overviewH = 26.0;
  static const _overviewWaveH = 19.0;
  static const _positionBarH = 3.0;

  // Colour per combination of bands reaching a pixel (bit 1 low, 2 mid, 4 high).
  static const _bandColours = <int, Color>{
    1: Color(0xFF0055E1),
    2: Color(0xFFFFA600),
    4: Color(0xFFFFFFFF),
    3: Color(0xFFB4690A),
    5: Color(0xFFD2DCFA),
    6: Color(0xFFFFF0D7),
    7: Color(0xFFF5EBD7),
  };
  static const _silence = Color(0xFFD2DCFA);
  static const _bg = Color(0xFF000000);
  static const _playhead = Color(0xFFE0E0E0);
  static const _beat = Color(0xFF4C4C4C);
  static const _beatHead = Color(0xFF7C7C7C);
  static const _downbeat = Color(0xFFFFFFFF);
  static const _downbeatHead = Color(0xFFEA3323);
  static const _loop = Color(0xFF3571E3);
  static const _barRim = Color(0xFF6B6B6B);
  static const _barPlayed = Color(0xFFC8C8C8);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = _bg);
    if (duration <= 0 || size.width <= 1 || size.height <= overviewH + 2) {
      return;
    }
    final overviewTop = hangDown ? size.height - overviewH : 0.0;
    final detailTop = hangDown ? 0.0 : overviewH;
    final detailBottom = hangDown ? size.height - overviewH : size.height;
    _paintOverview(canvas, size.width, overviewTop);
    _paintDetail(canvas, size.width, detailTop, detailBottom);
  }

  void _paintOverview(Canvas canvas, double width, double top) {
    final waveTop = top + 2;
    final base = waveTop + _overviewWaveH;
    final cols = overview.length ~/ 3;
    if (cols > 0) {
      // Overview means run low on long tracks; scale so the loudest column fills the strip.
      var norm = 0.0;
      for (var c = 0; c < cols; c++) {
        norm = math.max(norm, overview[c * 3] / 128);
        norm = math.max(norm, overview[c * 3 + 1] / 256);
        norm = math.max(norm, overview[c * 3 + 2] / 128);
      }
      final fill = norm > 0 ? 1 / norm : 1.0;
      final low = Path(), mid = Path(), high = Path();
      for (var px = 0; px < width; px++) {
        // Max over the columns under this pixel so transients survive.
        final c0 = (px * cols / width).floor();
        final c1 = math.max(c0 + 1, ((px + 1) * cols / width).floor()).clamp(0, cols);
        var l = 0, m = 0, h = 0;
        for (var c = c0; c < c1; c++) {
          l = math.max(l, overview[c * 3]);
          m = math.max(m, overview[c * 3 + 1]);
          h = math.max(h, overview[c * 3 + 2]);
        }
        // Stacked from the baseline; mid draws at half weight, as in rbxport.
        void bar(Path p, int v, double scale) {
          if (v == 0) return;
          final hh = math.min(v / scale * fill, 1.0) * _overviewWaveH;
          p.addRect(Rect.fromLTRB(px.toDouble(), base - hh, px + 1.0, base));
        }

        bar(low, l, 128);
        bar(mid, m, 256);
        bar(high, h, 128);
      }
      canvas.drawPath(low, Paint()..color = _bandColours[1]!);
      canvas.drawPath(mid, Paint()..color = _bandColours[2]!);
      canvas.drawPath(high, Paint()..color = _bandColours[7]!);
    }

    if (loopEnabled && loopEnd > loopStart) {
      final x0 = (loopStart / duration * width).clamp(0.0, width);
      final x1 = (loopEnd / duration * width).clamp(0.0, width);
      canvas.drawRect(
        Rect.fromLTRB(x0, waveTop, x1, base),
        Paint()..color = _loop.withValues(alpha: 0.38),
      );
    }

    // Position bar: hollow rim, played part filled.
    final barTop = base + 2;
    final progress = (position / duration).clamp(0.0, 1.0);
    final rim = Paint()..color = _barRim;
    canvas.drawRect(Rect.fromLTWH(0, barTop, width, 1), rim);
    canvas.drawRect(Rect.fromLTWH(0, barTop + _positionBarH - 1, width, 1), rim);
    canvas.drawRect(
      Rect.fromLTWH(0, barTop, width * progress, _positionBarH),
      Paint()..color = _barPlayed,
    );

    final x = width * progress;
    canvas.drawRect(
      Rect.fromLTWH(x - 1, top, 2, overviewH),
      Paint()..color = _playhead,
    );
  }

  void _paintDetail(Canvas canvas, double width, double top, double bottom) {
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(0, top, width, bottom));

    final playRate = rate.clamp(0.5, 2.0);
    // Heard-time window mapped back to file seconds: rate > 1 compresses the wave.
    final viewDur = zoomWindowSec * playRate;
    final viewStart = position - viewDur / 2;
    double xForTime(double t) => (t - viewStart) / viewDur * width;

    final full = bottom - top - 1;
    // Deck A grows up from the bottom edge, deck B hangs down from the top edge.
    final base = hangDown ? top : bottom;
    final dir = hangDown ? 1.0 : -1.0;

    final cols = detail.length ~/ 3;
    if (cols > 0) {
      final paths = <int, Path>{for (final k in _bandColours.keys) k: Path()};
      final silence = Path();
      final colsPerPx = viewDur * columnsPerSec / width;
      for (var px = 0; px < width; px++) {
        final t = viewStart + px / width * viewDur;
        if (t < 0 || t >= duration) continue;
        final v = colsPerPx >= 1
            ? _maxOver(t * columnsPerSec, colsPerPx, cols)
            : _interpolate(t * columnsPerSec, cols);
        if (v.$1 == 0 && v.$2 == 0 && v.$3 == 0) {
          silence.addRect(_span(px, base, dir, 0, 1));
          continue;
        }
        _addSegments(paths, px, base, dir, full, v.$1, v.$2, v.$3);
      }
      canvas.drawPath(silence, Paint()..color = _silence);
      for (final e in paths.entries) {
        canvas.drawPath(e.value, Paint()..color = _bandColours[e.key]!);
      }
    }

    if (loopEnabled && loopEnd > loopStart) {
      final x0 = xForTime(loopStart).clamp(0.0, width);
      final x1 = xForTime(loopEnd).clamp(0.0, width);
      if (x1 > x0) {
        canvas.drawRect(
          Rect.fromLTRB(x0, top, x1, bottom),
          Paint()..color = _loop.withValues(alpha: 0.38),
        );
      }
    }

    _paintGrid(canvas, width, top, bottom, viewStart, viewDur, xForTime);

    if (showJumpZone) {
      _drawJumpZone(canvas, width, top, bottom);
    }

    canvas.drawRect(
      Rect.fromLTWH(width / 2 - 0.75, top, 1.5, bottom - top),
      Paint()..color = _playhead,
    );
    canvas.restore();
  }

  /// Per-band maximum over the columns covered by one pixel.
  (int, int, int) _maxOver(double c, double span, int cols) {
    final c0 = c.floor().clamp(0, cols - 1);
    final c1 = (c + span).ceil().clamp(c0 + 1, cols);
    var l = 0, m = 0, h = 0;
    for (var i = c0; i < c1; i++) {
      l = math.max(l, detail[i * 3]);
      m = math.max(m, detail[i * 3 + 1]);
      h = math.max(h, detail[i * 3 + 2]);
    }
    return (l, m, h);
  }

  /// Linear between columns, except a sharp attack holds the earlier value so
  /// kicks stay vertical.
  (int, int, int) _interpolate(double c, int cols) {
    final i = c.floor().clamp(0, cols - 1);
    final j = math.min(i + 1, cols - 1);
    final f = c - c.floor();
    int band(int b) {
      final a = detail[i * 3 + b];
      final n = detail[j * 3 + b];
      if ((a == 0 && n > 0) || (n - a >= 16 && n >= 2 * a)) return a;
      return (a + (n - a) * f).round();
    }

    return (band(0), band(1), band(2));
  }

  /// Draw the reached stretches outermost first, so the inner core carries the
  /// colour of every band that reaches it.
  void _addSegments(
    Map<int, Path> paths,
    int px,
    double base,
    double dir,
    double full,
    int low,
    int mid,
    int high,
  ) {
    double reach(int v) => v == 0 ? 0 : math.max(0.5, v / 127 * full);
    final bands = [(1, reach(low)), (2, reach(mid)), (4, reach(high))]
      ..sort((a, b) => b.$2.compareTo(a.$2));
    var mask = 0;
    for (var k = 0; k < 3; k++) {
      final outer = bands[k].$2;
      if (outer <= 0) break;
      mask |= bands[k].$1;
      final inner = k + 1 < 3 ? bands[k + 1].$2 : 0.0;
      if (outer > inner) {
        paths[mask]!.addRect(_span(px, base, dir, inner, outer));
      }
    }
  }

  Rect _span(int px, double base, double dir, double from, double to) {
    final y0 = base + dir * from;
    final y1 = base + dir * to;
    return Rect.fromLTRB(px.toDouble(), math.min(y0, y1), px + 1.0, math.max(y0, y1));
  }

  void _paintGrid(
    Canvas canvas,
    double width,
    double top,
    double bottom,
    double viewStart,
    double viewDur,
    double Function(double) xForTime,
  ) {
    final beatSec = bpm > 1 ? 60.0 / bpm : 0.0;
    if (beatSec <= 0.05) return;
    final viewEnd = viewStart + viewDur;
    var idx = ((viewStart - beatOffset) / beatSec).ceil();
    const headW = 6.0, headH = 4.0;
    final beatLine = Paint()..color = _beat;
    final downLine = Paint()..color = _downbeat;
    final beatHeads = Path(), downHeads = Path();
    for (var t = beatOffset + idx * beatSec; t <= viewEnd; t += beatSec, idx++) {
      if (t < 0 || t > duration) continue;
      final down = idx % 4 == 0;
      final x = xForTime(t).roundToDouble();
      canvas.drawRect(
        Rect.fromLTRB(x, top + headH, x + 1, bottom - headH),
        down ? downLine : beatLine,
      );
      final heads = down ? downHeads : beatHeads;
      final cx = x + 0.5;
      heads
        ..moveTo(cx - headW / 2, top)
        ..lineTo(cx + headW / 2, top)
        ..lineTo(cx, top + headH)
        ..close()
        ..moveTo(cx - headW / 2, bottom)
        ..lineTo(cx + headW / 2, bottom)
        ..lineTo(cx, bottom - headH)
        ..close();
    }
    canvas.drawPath(beatHeads, Paint()..color = _beatHead);
    canvas.drawPath(downHeads, Paint()..color = _downbeatHead);
  }

  static const jumpHalf = 0.14;

  /// Left edge of the beat-jump hit rect; same math as [_drawJumpZone].
  static double jumpZoneLeft(double width) => width * (0.5 - jumpHalf);

  /// Right edge of the beat-jump hit rect.
  static double jumpZoneRight(double width) => width * (0.5 + jumpHalf);

  void _drawJumpZone(Canvas canvas, double width, double top, double bottom) {
    final cx = width / 2;
    final half = width * jumpHalf;
    final cy = (top + bottom) / 2;
    _chevron(canvas, Offset(cx - half * 0.55, cy), left: true);
    _chevron(canvas, Offset(cx + half * 0.55, cy), left: false);
    _jumpLabel(canvas, Offset(cx - half * 0.55 + 10, cy - 7), '4');
    _jumpLabel(canvas, Offset(cx + half * 0.55 - 18, cy - 7), '4');
  }

  void _chevron(Canvas canvas, Offset c, {required bool left}) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeJoin = StrokeJoin.round;
    final dx = left ? -6.0 : 6.0;
    final path = Path()
      ..moveTo(c.dx - dx, c.dy - 8)
      ..lineTo(c.dx + dx, c.dy)
      ..lineTo(c.dx - dx, c.dy + 8);
    canvas.drawPath(path, paint);
  }

  void _jumpLabel(Canvas canvas, Offset o, String s) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.35),
          fontSize: 10,
          fontWeight: FontWeight.w800,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, o);
  }

  @override
  bool shouldRepaint(covariant WaveformPainter oldDelegate) {
    return oldDelegate.position != position ||
        oldDelegate.duration != duration ||
        oldDelegate.detail != detail ||
        oldDelegate.overview != overview ||
        oldDelegate.beatOffset != beatOffset ||
        oldDelegate.bpm != bpm ||
        oldDelegate.rate != rate ||
        oldDelegate.hangDown != hangDown ||
        oldDelegate.loopEnabled != loopEnabled ||
        oldDelegate.loopStart != loopStart ||
        oldDelegate.loopEnd != loopEnd ||
        oldDelegate.showJumpZone != showJumpZone;
  }
}

class WaveformView extends StatelessWidget {
  const WaveformView({
    super.key,
    required this.detail,
    required this.overview,
    required this.columnsPerSec,
    required this.position,
    required this.duration,
    this.hangDown = false,
    this.beatOffset = 0,
    this.bpm = 0,
    this.rate = 1,
    this.loopEnabled = false,
    this.loopStart = 0,
    this.loopEnd = 0,
    this.onSeek,
    this.onOverviewSeek,
  });

  final Uint8List detail;
  final Uint8List overview;
  final int columnsPerSec;
  final double position;
  final double duration;
  final bool hangDown;
  final double beatOffset;
  final double bpm;
  final double rate;
  final bool loopEnabled;
  final double loopStart;
  final double loopEnd;
  /// Zoomed jump-zone tap (typically ±4 beat jump toward the tap).
  final ValueChanged<double>? onSeek;
  /// Full-track overview strip tap → absolute position in seconds.
  final ValueChanged<double>? onOverviewSeek;

  static const zoom = 8.0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth.isFinite ? constraints.maxWidth : 300.0;
        final h = constraints.maxHeight.isFinite && constraints.maxHeight > 0
            ? constraints.maxHeight
            : 88.0;
        final paint = CustomPaint(
          painter: WaveformPainter(
            detail: detail,
            overview: overview,
            columnsPerSec: columnsPerSec,
            position: position,
            duration: duration,
            hangDown: hangDown,
            beatOffset: beatOffset,
            bpm: bpm,
            rate: rate,
            loopEnabled: loopEnabled,
            loopStart: loopStart,
            loopEnd: loopEnd,
            zoomWindowSec: zoom,
            showJumpZone: onSeek != null,
          ),
          size: Size(w, h),
        );
        if ((onSeek == null && onOverviewSeek == null) || duration <= 0) {
          return paint;
        }
        return GestureDetector(
          onTapDown: (d) {
            final nx = (d.localPosition.dx / w).clamp(0.0, 1.0);
            final y = d.localPosition.dy;
            final inOverview = hangDown
                ? y > h - WaveformPainter.overviewH
                : y < WaveformPainter.overviewH;
            if (inOverview) {
              onOverviewSeek?.call(nx * duration);
              return;
            }
            if (onSeek == null) return;
            if ((nx - 0.5).abs() > WaveformPainter.jumpHalf) return;
            final playRate = rate.clamp(0.5, 2.0);
            final heard = (nx - 0.5) * zoom;
            final t = position + heard * playRate;
            onSeek!(t.clamp(0.0, duration).toDouble());
          },
          child: paint,
        );
      },
    );
  }
}
