import 'package:flutter/material.dart';
import 'package:sidedeck/engine/music_utils.dart';
import 'package:sidedeck/state/dj_controller.dart';
import 'package:sidedeck/theme/sidedeck_theme.dart';
import 'package:sidedeck/ui/mixer_strip.dart';
import 'package:sidedeck/ui/waveform.dart';

/// One deck in rbxport's 2-player arrangement: a transport rail on the left,
/// then overview, control row and scrolling detail. Deck B ([index] 1) stacks
/// the other way round (detail, controls, overview) so both details meet at the
/// line between the decks.
class DeckPanel extends StatelessWidget {
  const DeckPanel({
    super.key,
    required this.controller,
    required this.index,
    required this.gridEditing,
    required this.onToggleGrid,
    required this.onLoad,
    required this.onLibrary,
    required this.onSettings,
    required this.zoom,
    required this.onZoom,
  });

  final DjController controller;
  final int index;
  final bool gridEditing;
  final VoidCallback onToggleGrid;
  final VoidCallback onLoad;
  final VoidCallback onLibrary;
  final VoidCallback onSettings;
  /// Detail zoom in heard seconds, shared by both decks so their grids match.
  final double zoom;
  final ValueChanged<double> onZoom;

  static const _railW = 60.0;
  static const _rowH = 30.0;

  bool get _hang => index == 1;
  Color get _tagColor => index == 0 ? SideDeckTheme.accentA : SideDeckTheme.accentB;

  @override
  Widget build(BuildContext context) {
    final d = controller.deck(index);
    Widget wave(WavePart part) => WaveformView(
      part: part,
      detail: d.bandDetail,
      overview: d.bandOverview,
      columnsPerSec: d.bandsPerSec,
      hangDown: _hang,
      position: d.position,
      duration: d.duration,
      beatOffset: d.beatOffset,
      bpm: d.bpm,
      rate: d.rate,
      loopEnabled: d.loopEnabled,
      loopStart: d.loopStart,
      loopEnd: d.loopEnd,
      cuePoint: d.loaded ? d.cuePoint : -1,
      // A copy, so the painter can tell when a slot changes.
      hotCues: d.loaded ? List.of(d.hotCues) : const [],
      playing: d.playing,
      zoom: zoom,
      onOverviewSeek: d.loaded ? (t) => controller.seekTo(index, t) : null,
      onScrub: d.loaded && !gridEditing ? (t) => controller.seekTo(index, t) : null,
      onZoom: d.loaded && !gridEditing ? onZoom : null,
    );

    Widget detail = wave(WavePart.detail);
    if (gridEditing) {
      // Tapping the wave closes the grid editor instead of jumping.
      detail = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onToggleGrid,
        child: AbsorbPointer(child: detail),
      );
    } else if (d.loaded) {
      // Nudge sits either side of the playhead: − slows/jogs back, + speeds
      // up/jogs forward. Stacked above the wave so a press never scrubs it.
      // The builder runs later, so it must not read `detail` after this
      // reassignment (that would nest the view inside itself forever).
      final plain = detail;
      detail = LayoutBuilder(
        builder: (context, c) {
          final cx = c.maxWidth / 2;
          const hit = 48.0;
          const offset = 64.0;
          Widget glyph(bool faster) => Positioned(
            left: cx + (faster ? offset : -offset) - hit / 2,
            top: (c.maxHeight - hit) / 2,
            width: hit,
            height: hit,
            child: _NudgeGlyph(
              faster: faster,
              onStart: () => controller.startNudge(index, faster: faster),
              onEnd: () => controller.endNudge(index),
            ),
          );
          return Stack(fit: StackFit.expand, children: [plain, glyph(false), glyph(true)]);
        },
      );
    }
    final rows = <Widget>[
      SizedBox(height: WaveformPainter.overviewH, child: wave(WavePart.overview)),
      SizedBox(height: _rowH, child: _controlRow(d)),
      Expanded(child: detail),
    ];

    Widget body = Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(width: _railW, child: _rail(d)),
        const SizedBox(width: 2),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: _hang ? rows.reversed.toList() : rows,
          ),
        ),
      ],
    );
    if (!d.loaded) {
      body = GestureDetector(behavior: HitTestBehavior.opaque, onTap: onLoad, child: body);
    }
    return ColoredBox(color: SideDeckTheme.deckBg, child: body);
  }

  Widget _rail(DeckState d) {
    final tag = Container(
      width: 18,
      height: 14,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: _tagColor, borderRadius: BorderRadius.circular(2)),
      child: Text(
        index == 0 ? 'A' : 'B',
        style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Colors.black, height: 1),
      ),
    );
    // Library on deck A's rail, settings on deck B's: the rails have room, and
    // in external mixer mode there is no mixer strip to hold them.
    final tool = index == 0
        ? _railIcon(Icons.library_music, 'Library', onLibrary)
        : _railIcon(Icons.settings_outlined, 'Settings', onSettings);
    final children = <Widget>[
      Padding(
        padding: const EdgeInsets.all(4),
        child: Row(children: [tag, const Spacer(), tool]),
      ),
      Expanded(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _cueButton(d),
              const SizedBox(height: 8),
              _playButton(d),
              const SizedBox(height: 8),
              // rbxport's rail: beat-jump pair, then size box (+ our Q toggle).
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _railChip(
                    icon: Icons.fast_rewind,
                    enabled: d.loaded && d.bpm > 1,
                    onTap: () => controller.jump(index, -1),
                  ),
                  const SizedBox(width: 4),
                  _railChip(
                    icon: Icons.fast_forward,
                    enabled: d.loaded && d.bpm > 1,
                    onTap: () => controller.jump(index, 1),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _railChip(
                    label: 'Q',
                    lit: d.quantize,
                    onTap: () => controller.setQuantize(index, !d.quantize),
                  ),
                  const SizedBox(width: 4),
                  _railChip(
                    label: '${d.jumpBeats}',
                    onTap: () => controller.cycleJumpSize(index),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ];
    return ColoredBox(
      color: SideDeckTheme.deckRow,
      child: Column(children: _hang ? children.reversed.toList() : children),
    );
  }

  Widget _railIcon(IconData icon, String tooltip, VoidCallback onTap) {
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onTap,
        radius: 18,
        child: Icon(icon, size: 20, color: const Color(0xFFA0A0A0)),
      ),
    );
  }

  /// Small rail button: tap ([onTap]) or hold-to-repeat ([onStep]).
  Widget _railChip({
    String? label,
    IconData? icon,
    bool lit = false,
    bool enabled = true,
    VoidCallback? onTap,
    VoidCallback? onStep,
  }) {
    final fg = enabled ? Colors.white : SideDeckTheme.deckOutline;
    final face = Container(
      width: 22,
      height: 20,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: lit ? SideDeckTheme.deckLit : SideDeckTheme.deckButton,
        borderRadius: BorderRadius.circular(2),
      ),
      child: icon != null
          ? Icon(icon, size: 13, color: fg)
          : Text(label!, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, height: 1, color: fg)),
    );
    if (!enabled) return face;
    if (onStep != null) return HoldRepeatButton(onStep: onStep, child: face);
    return GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTap, child: face);
  }

  /// CDJ-style CUE (see DjController.cueDown): reacts on press, and release
  /// ends a cue preview, so it is a raw pointer listener rather than a tap.
  Widget _cueButton(DeckState d) {
    const ring = Color(0xFFEDB751);
    final face = Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: d.cuePreview ? ring : Colors.black,
        shape: BoxShape.circle,
        border: Border.all(color: d.loaded ? ring : SideDeckTheme.deckOutline, width: 2),
      ),
      child: Text(
        'CUE',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w800,
          color: !d.loaded
              ? SideDeckTheme.deckOutline
              : (d.cuePreview ? Colors.black : Colors.white),
        ),
      ),
    );
    if (!d.loaded) return face;
    return Listener(
      onPointerDown: (_) => controller.cueDown(index),
      onPointerUp: (_) => controller.cueUp(index),
      onPointerCancel: (_) => controller.cueUp(index),
      child: face,
    );
  }

  Widget _playButton(DeckState d) {
    final lit = d.playing;
    final glyph = !d.loaded
        ? SideDeckTheme.deckOutline
        : (lit ? Colors.white : const Color(0xFFB4B4B4));
    return Material(
      color: Colors.black,
      shape: CircleBorder(
        side: BorderSide(color: lit ? SideDeckTheme.playLit : SideDeckTheme.playRing, width: 2),
      ),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: d.loaded ? () => controller.playPause(index) : null,
        child: SizedBox(
          width: 46,
          height: 46,
          child: Icon(lit ? Icons.pause : Icons.play_arrow, size: 26, color: glyph),
        ),
      ),
    );
  }

  Widget _controlRow(DeckState d) {
    if (!d.loaded) {
      return Container(
        color: SideDeckTheme.deckRow,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        alignment: Alignment.centerLeft,
        child: Text(
          'Deck ${index == 0 ? 'A' : 'B'} — tap to load a track',
          style: const TextStyle(fontSize: 12, color: SideDeckTheme.deckDim),
        ),
      );
    }
    final controls = gridEditing ? _gridEditor() : _performanceControls(d);
    return Container(
      color: SideDeckTheme.deckRow,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: Row(
        children: [
          // Title and readouts share what the buttons leave; readouts shrink
          // to fit rather than squeezing the title out.
          Expanded(flex: 2, child: _title(d)),
          const SizedBox(width: 8),
          Expanded(
            flex: 3,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: _readouts(d),
            ),
          ),
          const SizedBox(width: 10),
          ...controls,
          const SizedBox(width: 6),
          _DeckButton(label: 'GRID', lit: gridEditing, width: 40, onTap: onToggleGrid),
        ],
      ),
    );
  }

  Widget _title(DeckState d) {
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: d.title,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: SideDeckTheme.deckText),
          ),
          if (d.artist.isNotEmpty)
            TextSpan(
              text: '  ${d.artist}',
              style: const TextStyle(fontSize: 12, color: SideDeckTheme.deckDim),
            ),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _readouts(DeckState d) {
    final remaining = (d.duration - d.position).clamp(0.0, 359999.0);
    final heard = d.bpm * d.rate;
    final pct = (d.rate - 1) * 100;
    final pctLabel = '${pct < -0.004 ? '−' : '+'}${pct.abs().toStringAsFixed(2)}%';
    Widget sep() => Container(
      width: 1,
      height: 14,
      margin: const EdgeInsets.symmetric(horizontal: 6),
      color: SideDeckTheme.deckOutline,
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _time(remaining, negative: true, color: SideDeckTheme.deckText),
        sep(),
        _time(d.position, color: SideDeckTheme.deckDim),
        sep(),
        if (d.gridUnsure) ...[const GridWarningBadge(), const SizedBox(width: 4)],
        _mono(
          d.bpm > 1 ? heard.toStringAsFixed(2) : '—',
          d.gridUnsure ? GridWarningBadge.colour : SideDeckTheme.deckText,
        ),
        sep(),
        _mono(pctLabel, d.synced ? SideDeckTheme.deckLit : SideDeckTheme.deckDim),
        sep(),
        _mono(formatKey(d.key), SideDeckTheme.deckText),
      ],
    );
  }

  static const _readoutStyle = TextStyle(
    fontSize: 12.5,
    fontFeatures: [FontFeature.tabularFigures()],
    height: 1,
  );

  Widget _mono(String s, Color color) => Text(s, style: _readoutStyle.copyWith(color: color));

  /// `-MM:SS` with the tenths in a smaller face, as rbxport's readouts.
  Widget _time(double seconds, {bool negative = false, required Color color}) {
    final tenths = (seconds * 10).floor();
    final m = tenths ~/ 600;
    final s = (tenths ~/ 10) % 60;
    final t = tenths % 10;
    final main = '${negative ? '-' : ''}${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: main),
          TextSpan(text: '.$t', style: const TextStyle(fontSize: 10)),
        ],
      ),
      style: _readoutStyle.copyWith(color: color),
    );
  }

  List<Widget> _performanceControls(DeckState d) {
    final beats = d.loopBars * 4;
    final beatsLabel = (beats - beats.round()).abs() < 0.05 ? '${beats.round()}' : beats.toStringAsFixed(1);
    final canHalf = beats > DjController.loopBeats.first + 0.05;
    final canDouble = beats < DjController.loopBeats.last - 0.05;
    final hasBpm = d.bpm > 1;
    final canSync = controller.deck(1 - index).loaded;
    const gap = SizedBox(width: 3);
    const groupGap = SizedBox(width: 8);
    return [
      for (var slot = 0; slot < d.hotCues.length; slot++) ...[
        if (slot > 0) gap,
        _HotCuePad(
          slot: slot,
          set: d.hotCues[slot] >= 0,
          onTap: () => controller.hotCue(index, slot),
          onClear: () => controller.clearHotCue(index, slot),
        ),
      ],
      groupGap,
      _DeckButton(label: '½', enabled: canHalf, onStep: () => controller.halfLoop(index)),
      gap,
      _DeckButton(
        label: beatsLabel,
        sub: 'LOOP',
        width: 40,
        lit: d.loopEnabled,
        onTap: () => controller.setLoop(index, !d.loopEnabled, d.loopBars == 0 ? 1 : d.loopBars),
      ),
      gap,
      _DeckButton(label: '×2', enabled: canDouble, onStep: () => controller.doubleLoop(index)),
      groupGap,
      _DeckButton(label: '−', enabled: hasBpm, onStep: () => controller.nudgeBpm(index, -0.1)),
      gap,
      _DeckButton(
        label: 'SYNC',
        width: 40,
        lit: d.synced,
        enabled: canSync,
        onTap: () => controller.sync(index),
      ),
      gap,
      _DeckButton(label: '+', enabled: hasBpm, onStep: () => controller.nudgeBpm(index, 0.1)),
    ];
  }

  List<Widget> _gridEditor() {
    const gap = SizedBox(width: 3);
    Widget caption(String s) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Text(s, style: const TextStyle(fontSize: 10, color: SideDeckTheme.deckDim)),
    );
    return [
      _DeckButton(label: '«', onStep: () => controller.shiftGridBeats(index, -1)),
      caption('BEAT'),
      _DeckButton(label: '»', onStep: () => controller.shiftGridBeats(index, 1)),
      const SizedBox(width: 10),
      _DeckButton(label: '‹', onStep: () => controller.shiftGridMs(index, -5)),
      caption('5 MS'),
      _DeckButton(label: '›', onStep: () => controller.shiftGridMs(index, 5)),
      gap,
    ];
  }
}

/// Amber "!" (optionally with a label) for a grid that analysis was unsure of:
/// few kicks landed on it, so check it before playing out (openDJ's grid_unsure).
class GridWarningBadge extends StatelessWidget {
  const GridWarningBadge({super.key, this.label});

  final String? label;

  static const colour = Color(0xFFFFA600);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: label == null ? 0 : 4, vertical: 1),
      constraints: const BoxConstraints(minWidth: 13, minHeight: 13),
      alignment: Alignment.center,
      decoration: BoxDecoration(color: colour, borderRadius: BorderRadius.circular(2)),
      child: Text(
        label ?? '!',
        style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w900, color: Colors.black, height: 1.1),
      ),
    );
  }
}

/// Hot cue pad in its slot colour: empty shows a coloured letter on the
/// button grey, set is filled with a black letter. Tap sets or jumps;
/// long-press clears.
class _HotCuePad extends StatelessWidget {
  const _HotCuePad({
    required this.slot,
    required this.set,
    required this.onTap,
    required this.onClear,
  });

  final int slot;
  final bool set;
  final VoidCallback onTap;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final colour = WaveformPainter.hotCueColours[slot % WaveformPainter.hotCueColours.length];
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: set ? onClear : null,
      child: Container(
        width: 26,
        height: 26,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: set ? colour : SideDeckTheme.deckButton,
          borderRadius: BorderRadius.circular(2),
        ),
        child: Text(
          WaveformPainter.hotCueLabel(slot),
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w800,
            height: 1,
            color: set ? Colors.black : colour,
          ),
        ),
      ),
    );
  }
}

/// Minimal on-wave nudge glyph, drawn like the old jump chevrons: a thin,
/// translucent − or + that brightens while held.
class _NudgeGlyph extends StatefulWidget {
  const _NudgeGlyph({required this.faster, required this.onStart, required this.onEnd});

  final bool faster;
  final VoidCallback onStart;
  final VoidCallback onEnd;

  @override
  State<_NudgeGlyph> createState() => _NudgeGlyphState();
}

class _NudgeGlyphState extends State<_NudgeGlyph> {
  bool _held = false;

  void _set(bool held) {
    if (held == _held) return;
    setState(() => _held = held);
    held ? widget.onStart() : widget.onEnd();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) => _set(true),
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: Center(
        child: CustomPaint(
          size: const Size(16, 16),
          painter: _NudgePainter(plus: widget.faster, alpha: _held ? 0.85 : 0.35),
        ),
      ),
    );
  }
}

class _NudgePainter extends CustomPainter {
  const _NudgePainter({required this.plus, required this.alpha});

  final bool plus;
  final double alpha;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Colors.white.withValues(alpha: alpha)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    final c = size.center(Offset.zero);
    final r = size.width / 2;
    canvas.drawLine(c.translate(-r, 0), c.translate(r, 0), p);
    if (plus) canvas.drawLine(c.translate(0, -r), c.translate(0, r), p);
  }

  @override
  bool shouldRepaint(_NudgePainter old) => old.plus != plus || old.alpha != alpha;
}

/// rbxport-style deck button: flat #282828, 2 px corners, blue when lit.
/// [onTap] fires once; [onStep] repeats while held.
class _DeckButton extends StatelessWidget {
  const _DeckButton({
    required this.label,
    this.sub,
    this.width = 31,
    this.lit = false,
    this.enabled = true,
    this.onTap,
    this.onStep,
  });

  final String label;
  final String? sub;
  final double width;
  final bool lit;
  final bool enabled;
  final VoidCallback? onTap;
  final VoidCallback? onStep;

  @override
  Widget build(BuildContext context) {
    final fg = !enabled ? SideDeckTheme.deckOutline : Colors.white;
    final Widget content;
    if (sub != null) {
      content = Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, height: 1, color: fg)),
          Text(sub!, style: TextStyle(fontSize: 7.5, fontWeight: FontWeight.w700, letterSpacing: 0.5, height: 1.1, color: lit ? Colors.white : SideDeckTheme.deckDim)),
        ],
      );
    } else {
      content = Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, height: 1, color: fg));
    }
    final face = Container(
      width: width,
      height: 26,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: lit ? SideDeckTheme.deckLit : SideDeckTheme.deckButton,
        borderRadius: BorderRadius.circular(2),
      ),
      child: content,
    );
    if (!enabled) return face;
    if (onStep != null) return HoldRepeatButton(onStep: onStep!, child: face);
    return GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTap, child: face);
  }
}
