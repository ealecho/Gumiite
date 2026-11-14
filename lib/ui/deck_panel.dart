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
  });

  final DjController controller;
  final int index;
  final bool gridEditing;
  final VoidCallback onToggleGrid;
  final VoidCallback onLoad;

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
      onSeek: d.loaded && !gridEditing ? (t) => controller.seek(index, t) : null,
      onOverviewSeek: d.loaded ? (t) => controller.seekTo(index, t) : null,
    );

    Widget detail = wave(WavePart.detail);
    if (gridEditing) {
      // Tapping the wave closes the grid editor instead of jumping.
      detail = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onToggleGrid,
        child: AbsorbPointer(child: detail),
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
    final children = <Widget>[
      Padding(padding: const EdgeInsets.all(4), child: Align(alignment: Alignment.centerLeft, child: tag)),
      Expanded(child: Center(child: _playButton(d))),
    ];
    return ColoredBox(
      color: SideDeckTheme.deckRow,
      child: Column(children: _hang ? children.reversed.toList() : children),
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
        _mono(d.bpm > 1 ? heard.toStringAsFixed(2) : '—', SideDeckTheme.deckText),
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
      groupGap,
      _DeckButton(
        icon: Icons.arrow_back,
        onHoldStart: () => controller.startNudge(index, faster: false),
        onHoldEnd: () => controller.endNudge(index),
      ),
      gap,
      _DeckButton(
        icon: Icons.arrow_forward,
        onHoldStart: () => controller.startNudge(index, faster: true),
        onHoldEnd: () => controller.endNudge(index),
      ),
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

/// rbxport-style deck button: flat #282828, 2 px corners, blue when lit.
/// [onTap] fires once; [onStep] repeats while held; [onHoldStart]/[onHoldEnd]
/// bracket a press (nudge).
class _DeckButton extends StatelessWidget {
  const _DeckButton({
    this.label,
    this.icon,
    this.sub,
    this.width = 31,
    this.lit = false,
    this.enabled = true,
    this.onTap,
    this.onStep,
    this.onHoldStart,
    this.onHoldEnd,
  });

  final String? label;
  final IconData? icon;
  final String? sub;
  final double width;
  final bool lit;
  final bool enabled;
  final VoidCallback? onTap;
  final VoidCallback? onStep;
  final VoidCallback? onHoldStart;
  final VoidCallback? onHoldEnd;

  @override
  Widget build(BuildContext context) {
    final fg = !enabled ? SideDeckTheme.deckOutline : Colors.white;
    final Widget content;
    if (icon != null) {
      content = Icon(icon, size: 16, color: fg);
    } else if (sub != null) {
      content = Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(label!, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, height: 1, color: fg)),
          Text(sub!, style: TextStyle(fontSize: 7.5, fontWeight: FontWeight.w700, letterSpacing: 0.5, height: 1.1, color: lit ? Colors.white : SideDeckTheme.deckDim)),
        ],
      );
    } else {
      content = Text(label!, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, height: 1, color: fg));
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
    if (onHoldStart != null) {
      return Listener(
        onPointerDown: (_) => onHoldStart!(),
        onPointerUp: (_) => onHoldEnd?.call(),
        onPointerCancel: (_) => onHoldEnd?.call(),
        child: face,
      );
    }
    return GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTap, child: face);
  }
}
