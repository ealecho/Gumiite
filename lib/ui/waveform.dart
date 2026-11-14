import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// 3-band DJ waveform after rbxport (https://github.com/chrisle/rbxport,
/// GPL-2.0-or-later): overview strip plus a scrolling detail with the playhead
/// pinned center. Bands are low/mid/high bytes (0..127) per column.
///
/// With [hangDown] false (deck A) the overview sits on top and the detail rises
/// from the bottom edge; with [hangDown] true (deck B) the overview moves to the
/// bottom and the detail hangs from the top edge, so two decks stacked on top of
/// each other meet at a shared center line.
/// Which parts of the waveform a [WaveformView] draws.
enum WavePart { both, overview, detail }

class WaveformPainter extends CustomPainter {
  WaveformPainter({
    this.part = WavePart.both,
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
    this.cuePoint = -1,
    this.hotCues = const [],
    this.zoomWindowSec = WaveformView.defaultZoom,
  });

  final WavePart part;
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
  /// Main cue point in seconds; negative hides the marker.
  final double cuePoint;
  /// Hot cue seconds per slot (A, B, C, ...); negative = empty slot.
  final List<double> hotCues;
  final double zoomWindowSec;

  /// rbxport's default "colorful" hot cue colours by slot (src/lib/hotCueColours.ts).
  static const hotCueColours = [
    Color(0xFFFF376F),
    Color(0xFF45ACDB),
    Color(0xFF7DC13D),
    Color(0xFFAA72FF),
    Color(0xFF30D26E),
    Color(0xFFE0641B),
    Color(0xFF305AFF),
    Color(0xFFC3AF04),
  ];
  static String hotCueLabel(int slot) => String.fromCharCode(0x41 + slot);

  static const overviewH = 26.0;
  static const _cue = Color(0xFFEA3323);
  static const _detailHeadroom = 0.82;
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
    if (duration <= 0 || size.width <= 1 || size.height <= 2) {
      return;
    }
    switch (part) {
      case WavePart.overview:
        _paintOverview(canvas, size.width, 0);
      case WavePart.detail:
        _paintDetail(canvas, size.width, 0, size.height);
      case WavePart.both:
        if (size.height <= overviewH + 2) return;
        final overviewTop = hangDown ? size.height - overviewH : 0.0;
        final detailTop = hangDown ? 0.0 : overviewH;
        final detailBottom = hangDown ? size.height - overviewH : size.height;
        _paintOverview(canvas, size.width, overviewTop);
        _paintDetail(canvas, size.width, detailTop, detailBottom);
    }
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
        norm = math.max(norm, overview[c * 3 + 2] / 256);
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
        // Stacked from the baseline. rbxport draws mid at half weight; highs are
        // halved too here, or the cream layer hides the low/mid layers.
        void bar(Path p, int v, double scale) {
          if (v == 0) return;
          final hh = math.min(v / scale * fill, 1.0) * _overviewWaveH;
          p.addRect(Rect.fromLTRB(px.toDouble(), base - hh, px + 1.0, base));
        }

        bar(low, l, 128);
        bar(mid, m, 256);
        bar(high, h, 256);
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

    for (var i = 0; i < hotCues.length; i++) {
      if (hotCues[i] < 0) continue;
      final hx = (hotCues[i] / duration * width).clamp(0.0, width);
      canvas.drawRect(
        Rect.fromLTWH(hx, top, 7, 7),
        Paint()..color = hotCueColours[i % hotCueColours.length],
      );
    }

    if (cuePoint >= 0) {
      final cx = (cuePoint / duration * width).clamp(0.0, width);
      canvas.drawPath(
        Path()
          ..moveTo(cx - 5, top)
          ..lineTo(cx + 5, top)
          ..lineTo(cx, top + 7)
          ..close(),
        Paint()..color = _cue,
      );
    }

    final x = width * progress;
    canvas.drawRect(
      Rect.fromLTWH(x - 1, top, 2, overviewH),
      Paint()..color = _playhead,
    );
  }

  /// Hot cue marker on the detail: a faint line in the slot colour and a
  /// lettered square badge on the deck's outer edge (rbxport's badge style).
  void _paintHotCue(Canvas canvas, double width, double top, double bottom, double x, int slot) {
    const size = 13.0;
    if (x < -size || x > width + size) return;
    final colour = hotCueColours[slot % hotCueColours.length];
    canvas.drawRect(
      Rect.fromLTRB(x - 0.5, top, x + 0.5, bottom),
      Paint()..color = colour.withValues(alpha: 0.6),
    );
    final badgeTop = hangDown ? bottom - size - 3 : top + 3;
    final badge = Rect.fromLTWH(x - size / 2, badgeTop, size, size);
    canvas.drawRRect(
      RRect.fromRectAndRadius(badge, const Radius.circular(2)),
      Paint()..color = colour,
    );
    final tp = TextPainter(
      text: TextSpan(
        text: hotCueLabel(slot),
        style: const TextStyle(color: Colors.black, fontSize: 10, fontWeight: FontWeight.w800, height: 1),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, badge.center - Offset(tp.width / 2, tp.height / 2));
  }

  /// Cue marker on the detail: a line plus a triangle on the deck's outer
  /// edge (top for deck A, bottom for deck B), pointing into the wave.
  void _paintCue(Canvas canvas, double width, double top, double bottom, double x) {
    if (x < -8 || x > width + 8) return;
    canvas.drawRect(
      Rect.fromLTRB(x - 0.75, top, x + 0.75, bottom),
      Paint()..color = _cue.withValues(alpha: 0.85),
    );
    final edge = hangDown ? bottom : top;
    final tip = hangDown ? bottom - 11 : top + 11;
    canvas.drawPath(
      Path()
        ..moveTo(x - 8, edge)
        ..lineTo(x + 8, edge)
        ..lineTo(x, tip)
        ..close(),
      Paint()..color = _cue,
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
    for (var i = 0; i < hotCues.length; i++) {
      if (hotCues[i] >= 0) _paintHotCue(canvas, width, top, bottom, xForTime(hotCues[i]), i);
    }
    if (cuePoint >= 0) _paintCue(canvas, width, top, bottom, xForTime(cuePoint));

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
    // Leave headroom so loud passages don't all read as full scale.
    double reach(int v) => v == 0 ? 0 : math.max(0.5, v / 127 * full * _detailHeadroom);
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
    // Zoomed far out, beats crowd together: keep only the downbeats.
    final barsOnly = beatSec / viewDur * width < 8;
    for (var t = beatOffset + idx * beatSec; t <= viewEnd; t += beatSec, idx++) {
      if (t < 0 || t > duration) continue;
      final down = idx % 4 == 0;
      if (barsOnly && !down) continue;
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

  @override
  bool shouldRepaint(covariant WaveformPainter oldDelegate) {
    return oldDelegate.part != part ||
        oldDelegate.position != position ||
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
        oldDelegate.cuePoint != cuePoint ||
        !listEquals(oldDelegate.hotCues, hotCues) ||
        oldDelegate.zoomWindowSec != zoomWindowSec;
  }
}

class WaveformView extends StatefulWidget {
  const WaveformView({
    super.key,
    this.part = WavePart.both,
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
    this.cuePoint = -1,
    this.hotCues = const [],
    this.playing = false,
    this.zoom = defaultZoom,
    this.onOverviewSeek,
    this.onScrub,
    this.onZoom,
  });

  final WavePart part;
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
  final double cuePoint;
  final List<double> hotCues;
  /// While true the view animates [position] forward between updates.
  final bool playing;
  /// Heard seconds across the detail; see [defaultZoom], [minZoom], [maxZoom].
  final double zoom;
  /// Full-track overview strip tap or drag → absolute position in seconds.
  final ValueChanged<double>? onOverviewSeek;
  /// One-finger detail drag → absolute position in seconds, moving the track
  /// with the finger like a record.
  final ValueChanged<double>? onScrub;
  /// Two-finger pinch on the detail (and double-tap to reset) → new [zoom].
  final ValueChanged<double>? onZoom;

  static const defaultZoom = 4.0;
  static const minZoom = 1.5;
  static const maxZoom = 32.0;

  @override
  State<WaveformView> createState() => _WaveformViewState();
}

class _WaveformViewState extends State<WaveformView> with SingleTickerProviderStateMixin {
  // Smooth playback motion: the controller only reports positions every 50 ms,
  // so while playing we redraw every frame, extrapolating at the playback rate
  // and easing out the error whenever a fresh position arrives.
  late final Ticker _ticker = createTicker(_onFrame);
  double _base = 0; // last reported position
  Duration _baseAt = Duration.zero; // ticker time it arrived
  double _error = 0; // shown − reported at that moment, eased to 0
  double _shown = 0;
  Duration _now = Duration.zero;

  static const _snapSec = 0.25; // bigger jumps (seek, scrub, cue) snap
  static const _easeSec = 0.1;

  @override
  void initState() {
    super.initState();
    _base = _shown = widget.position;
    _syncTicker();
  }

  @override
  void didUpdateWidget(WaveformView old) {
    super.didUpdateWidget(old);
    if (widget.position != old.position || widget.playing != old.playing) {
      final err = _shown - widget.position;
      _error = widget.playing && err.abs() < _snapSec ? err : 0;
      _base = widget.position;
      _baseAt = _now;
      if (!widget.playing) _shown = widget.position;
    }
    _syncTicker();
  }

  void _syncTicker() {
    if (widget.playing && !_ticker.isActive) {
      _now = _baseAt = Duration.zero; // elapsed restarts from zero
      _ticker.start();
    } else if (!widget.playing && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _onFrame(Duration elapsed) {
    _now = elapsed;
    final dt = (elapsed - _baseAt).inMicroseconds / 1e6;
    final ease = math.exp(-dt / _easeSec);
    var t = _base + dt * widget.rate + _error * ease;
    // A looping deck wraps at the loop end like the engine does, rather than
    // running past it until the next reported position.
    final w = widget;
    final loopLen = w.loopEnd - w.loopStart;
    if (w.loopEnabled && loopLen > 0 && _base <= w.loopEnd && t > w.loopEnd) {
      t = w.loopStart + (t - w.loopEnd) % loopLen;
    }
    setState(() => _shown = t.clamp(0.0, w.duration).toDouble());
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  // Gesture state lives here, not in the builder: the view rebuilds every
  // tick while a finger is down.
  double _dragFrom = 0;
  double _dragDx = 0;
  double _zoomFrom = WaveformView.defaultZoom;
  bool _dragOverview = false;
  bool _pinching = false;

  bool _inOverview(double y, double h) => switch (widget.part) {
    WavePart.overview => true,
    WavePart.detail => false,
    WavePart.both =>
      widget.hangDown ? y > h - WaveformPainter.overviewH : y < WaveformPainter.overviewH,
  };

  @override
  Widget build(BuildContext context) {
    final w0 = widget;
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth.isFinite ? constraints.maxWidth : 300.0;
        final h = constraints.maxHeight.isFinite && constraints.maxHeight > 0
            ? constraints.maxHeight
            : 88.0;
        final paint = CustomPaint(
          painter: WaveformPainter(
            part: w0.part,
            detail: w0.detail,
            overview: w0.overview,
            columnsPerSec: w0.columnsPerSec,
            position: w0.playing ? _shown : w0.position,
            duration: w0.duration,
            hangDown: w0.hangDown,
            beatOffset: w0.beatOffset,
            bpm: w0.bpm,
            rate: w0.rate,
            loopEnabled: w0.loopEnabled,
            loopStart: w0.loopStart,
            loopEnd: w0.loopEnd,
            cuePoint: w0.cuePoint,
            hotCues: w0.hotCues,
            zoomWindowSec: w0.zoom,
          ),
          size: Size(w, h),
        );
        final interactive = w0.onOverviewSeek != null || w0.onScrub != null || w0.onZoom != null;
        if (!interactive || w0.duration <= 0) {
          return paint;
        }
        final playRate = w0.rate.clamp(0.5, 2.0);
        double clampT(double t) => t.clamp(0.0, w0.duration).toDouble();
        void overviewSeek(Offset p) =>
            w0.onOverviewSeek?.call((p.dx / w).clamp(0.0, 1.0) * w0.duration);
        final canResetZoom = w0.onZoom != null && w0.part != WavePart.overview;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) {
            if (_inOverview(d.localPosition.dy, h)) overviewSeek(d.localPosition);
          },
          // Only the detail listens for double-taps, so overview taps aren't delayed.
          onDoubleTap: canResetZoom ? () => w0.onZoom!(WaveformView.defaultZoom) : null,
          // One scale gesture covers both: one finger scrubs, two fingers zoom.
          onScaleStart: (d) {
            _dragOverview = _inOverview(d.localFocalPoint.dy, h);
            _dragFrom = w0.position;
            _dragDx = 0;
            _zoomFrom = w0.zoom;
            _pinching = false;
          },
          onScaleUpdate: (d) {
            if (d.pointerCount >= 2 && !_dragOverview) {
              final onZoom = w0.onZoom;
              if (onZoom == null || d.horizontalScale <= 0) return;
              _pinching = true;
              // Fingers apart = zoom in = fewer seconds across the screen.
              onZoom(
                (_zoomFrom / d.horizontalScale)
                    .clamp(WaveformView.minZoom, WaveformView.maxZoom)
                    .toDouble(),
              );
              return;
            }
            // After a pinch, the finger left behind shouldn't start scrubbing.
            if (_pinching) return;
            if (_dragOverview) {
              overviewSeek(d.localFocalPoint);
              return;
            }
            final onScrub = w0.onScrub;
            if (onScrub == null) return;
            _dragDx += d.focalPointDelta.dx;
            // Finger right pulls earlier audio under the playhead.
            onScrub(clampT(_dragFrom - _dragDx / w * w0.zoom * playRate));
          },
          child: paint,
        );
      },
    );
  }
}
