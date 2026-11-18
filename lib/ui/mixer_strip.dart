import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sidedeck/state/dj_controller.dart';
import 'package:sidedeck/theme/sidedeck_theme.dart';

/// Mixer under the waveforms: EQ faders per deck (plus filter when turned on in
/// Settings, DjController.showFilter) and the crossfader,
/// in rbxport's neutral mixer style. Not shown in external mixer mode;
/// library/settings live in the deck rails.
class MixerStrip extends StatelessWidget {
  const MixerStrip({super.key, required this.controller, this.onHide});

  final DjController controller;

  /// Collapses the strip so the decks get the screen (see HomePage).
  final VoidCallback? onHide;

  static const _label = TextStyle(
    fontSize: 9,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.8,
    color: SideDeckTheme.deckDim,
  );

  @override
  Widget build(BuildContext context) {
    final a = controller.deckA;
    final b = controller.deckB;

    return ColoredBox(
      color: SideDeckTheme.deckRow,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
        child: Row(
          children: [
            Expanded(flex: 5, child: _eqBlock(0, a)),
            const SizedBox(width: 12),
            Expanded(flex: 6, child: _center()),
            const SizedBox(width: 12),
            Expanded(flex: 5, child: _eqBlock(1, b)),
          ],
        ),
      ),
    );
  }

  Widget _center() {
    return Column(
      children: [
        SizedBox(
          height: 22,
          child: onHide == null
              ? null
              : IconButton(
                  tooltip: 'Hide mixer',
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints.tightFor(width: 40, height: 22),
                  onPressed: onHide,
                  icon: const Icon(Icons.keyboard_arrow_down, size: 20, color: SideDeckTheme.deckDim),
                ),
        ),
        const Text('CROSSFADER', style: _label),
        Expanded(
          child: Row(
            children: [
              _deckTag(0),
              const SizedBox(width: 8),
              Expanded(
                child: _fader(
                  value: controller.xfader,
                  min: 0,
                  max: 1,
                  onChanged: controller.setXfader,
                  thumbLength: 14,
                  thumbWidth: 34,
                ),
              ),
              const SizedBox(width: 8),
              _deckTag(1),
            ],
          ),
        ),
      ],
    );
  }

  Widget _deckTag(int deck) {
    return Container(
      width: 18,
      height: 14,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: deck == 0 ? SideDeckTheme.accentA : SideDeckTheme.accentB,
        borderRadius: BorderRadius.circular(2),
      ),
      child: Text(
        deck == 0 ? 'A' : 'B',
        style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Colors.black, height: 1),
      ),
    );
  }

  Widget _eqBlock(int deck, DeckState d) {
    // Deck A's block sits under deck A's rail tag and B's on the far side, so
    // the crossfader's end tags are the only A/B marks the strip needs.
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Expanded(child: _vSlider('LOW', d.eqLow, -12, 12, (v) => controller.setEq(deck, low: v))),
          Expanded(child: _vSlider('MID', d.eqMid, -12, 12, (v) => controller.setEq(deck, mid: v))),
          Expanded(child: _vSlider('HIGH', d.eqHigh, -12, 12, (v) => controller.setEq(deck, high: v))),
          if (controller.showFilter)
            Expanded(child: _vSlider('FILT', d.filter, -1, 1, (v) => controller.setFilter(deck, v))),
        ],
      ),
    );
  }

  Widget _vSlider(
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double> onChanged,
  ) {
    return Column(
      children: [
        Expanded(
          child: RotatedBox(
            quarterTurns: 3,
            child: _fader(value: value, min: min, max: max, onChanged: onChanged),
          ),
        ),
        const SizedBox(height: 2),
        Text(label, style: _label),
      ],
    );
  }

  /// Horizontal fader; vertical ones are rotated. [thumbLength] runs along the
  /// rail, [thumbWidth] across it.
  Widget _fader({
    required double value,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
    double thumbLength = 12,
    double thumbWidth = 26,
  }) {
    return SliderTheme(
      data: SliderThemeData(
        trackHeight: 3,
        trackShape: const _CenterFillTrack(),
        thumbShape: _FaderThumb(length: thumbLength, width: thumbWidth),
        overlayShape: SliderComponentShape.noOverlay,
      ),
      child: CenterDetentSlider(
        value: value.clamp(min, max),
        min: min,
        max: max,
        onChanged: onChanged,
      ),
    );
  }
}

/// rbxport-style rail (#323232) with a centre notch; the stretch between the
/// centre and the thumb is filled blue so any move away from flat shows.
class _CenterFillTrack extends SliderTrackShape with BaseSliderTrackShape {
  const _CenterFillTrack();

  static const _rail = Color(0xFF323232);
  static const _notch = Color(0xFF8A8A8A);

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
  }) {
    final rect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    final canvas = context.canvas;
    canvas.drawRect(rect, Paint()..color = _rail);
    final cx = rect.center.dx;
    final x0 = thumbCenter.dx < cx ? thumbCenter.dx : cx;
    final x1 = thumbCenter.dx < cx ? cx : thumbCenter.dx;
    if (x1 - x0 > 0.5) {
      canvas.drawRect(
        Rect.fromLTRB(x0, rect.top, x1, rect.bottom),
        Paint()..color = SideDeckTheme.deckLit,
      );
    }
    canvas.drawRect(
      Rect.fromCenter(center: rect.center, width: 1.5, height: rect.height + 10),
      Paint()..color = _notch,
    );
  }
}

/// Flat fader cap: #646464 block, 2 px corners, light centre line.
class _FaderThumb extends SliderComponentShape {
  const _FaderThumb({required this.length, required this.width});

  final double length;
  final double width;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => Size(length, width);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final canvas = context.canvas;
    final body = RRect.fromRectAndRadius(
      Rect.fromCenter(center: center, width: length, height: width),
      const Radius.circular(2),
    );
    canvas.drawRRect(body, Paint()..color = SideDeckTheme.deckOutline);
    canvas.drawRect(
      Rect.fromCenter(center: center, width: 1.5, height: width - 6),
      Paint()..color = const Color(0xFFD0D0D0),
    );
  }
}

/// Follows the finger. A center notch only appears after you leave the
/// middle and come back in the same drag.
class CenterDetentSlider extends StatefulWidget {
  const CenterDetentSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 1,
  });

  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  @override
  State<CenterDetentSlider> createState() => _CenterDetentSliderState();
}

class _CenterDetentSliderState extends State<CenterDetentSlider> {
  static const _snapIn = 0.02;
  static const _breakOut = 0.11;

  bool _latched = false;
  bool _leftCenter = false;

  double get _mid => (widget.min + widget.max) / 2;
  double get _range => widget.max - widget.min;

  bool _near(double v, double threshold) => (v - _mid).abs() <= threshold * _range;

  void _onChangeStart(double v) {
    _latched = false;
    _leftCenter = !_near(v, _snapIn);
  }

  void _onChanged(double v) {
    final dist = (v - _mid).abs();

    if (_latched) {
      if (dist >= _breakOut * _range) {
        _latched = false;
        HapticFeedback.lightImpact();
        widget.onChanged(v);
      } else if (widget.value != _mid) {
        widget.onChanged(_mid);
      }
      return;
    }

    if (!_near(v, _snapIn)) {
      _leftCenter = true;
      widget.onChanged(v);
      return;
    }

    if (_leftCenter) {
      _latched = true;
      HapticFeedback.selectionClick();
      widget.onChanged(_mid);
    } else {
      widget.onChanged(v);
    }
  }

  void _onChangeEnd(double v) {
    _latched = false;
    _leftCenter = false;
  }

  // Double-tap resets to the centre (flat EQ, filter off, crossfader in the
  // middle). Raw pointers rather than a double-tap recognizer, so the
  // slider's own tap and drag don't wait to see if a second tap follows.
  static const _doubleTapGap = Duration(milliseconds: 300);
  static const _tapSlop = 18.0;
  Offset _downAt = Offset.zero;
  Duration _downTime = Duration.zero;
  Duration? _lastTapUp;
  Offset _lastTapAt = Offset.zero;

  void _pointerDown(PointerDownEvent e) {
    _downAt = e.position;
    _downTime = e.timeStamp;
  }

  void _pointerUp(PointerUpEvent e) {
    final isTap = (e.position - _downAt).distance < _tapSlop &&
        e.timeStamp - _downTime < const Duration(milliseconds: 250);
    if (!isTap) {
      _lastTapUp = null;
      return;
    }
    final last = _lastTapUp;
    if (last != null &&
        e.timeStamp - last < _doubleTapGap &&
        (e.position - _lastTapAt).distance < _tapSlop * 2) {
      _lastTapUp = null;
      HapticFeedback.mediumImpact();
      // After the slider has handled this tap's own jump.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onChanged(_mid);
      });
      widget.onChanged(_mid);
      return;
    }
    _lastTapUp = e.timeStamp;
    _lastTapAt = e.position;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _pointerDown,
      onPointerUp: _pointerUp,
      child: Slider(
        value: widget.value.clamp(widget.min, widget.max),
        min: widget.min,
        max: widget.max,
        onChangeStart: _onChangeStart,
        onChanged: _onChanged,
        onChangeEnd: _onChangeEnd,
      ),
    );
  }
}

/// Tap once, or hold to repeat after a short delay.
class HoldRepeatButton extends StatefulWidget {
  const HoldRepeatButton({
    super.key,
    required this.onStep,
    required this.child,
    this.enabled = true,
    this.delay = const Duration(milliseconds: 380),
    this.interval = const Duration(milliseconds: 70),
  });

  final VoidCallback onStep;
  final Widget child;
  final bool enabled;
  final Duration delay;
  final Duration interval;

  @override
  State<HoldRepeatButton> createState() => _HoldRepeatButtonState();
}

class _HoldRepeatButtonState extends State<HoldRepeatButton> {
  Timer? _delay;
  Timer? _repeat;

  void _start() {
    if (!widget.enabled) return;
    HapticFeedback.selectionClick();
    widget.onStep();
    _delay = Timer(widget.delay, () {
      _repeat = Timer.periodic(widget.interval, (_) => widget.onStep());
    });
  }

  void _stop() {
    _delay?.cancel();
    _repeat?.cancel();
    _delay = null;
    _repeat = null;
  }

  @override
  void didUpdateWidget(HoldRepeatButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) _stop();
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: widget.enabled ? (_) => _start() : null,
      onPointerUp: (_) => _stop(),
      onPointerCancel: (_) => _stop(),
      child: widget.child,
    );
  }
}
