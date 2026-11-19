import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sidedeck/engine/music_utils.dart';
import 'package:sidedeck/engine/sections.dart';
import 'package:sidedeck/state/dj_controller.dart';
import 'package:sidedeck/theme/sidedeck_theme.dart';
import 'package:sidedeck/ui/bpm_pad.dart';
import 'package:sidedeck/ui/mixer_strip.dart';
import 'package:sidedeck/ui/track_info.dart';
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
    this.portrait = false,
  });

  /// Phone held upright: the stacked layout without the side rail.
  final bool portrait;
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

  static const _railW = 104.0;

  /// Extra rail width for the tempo column, when shown.
  static const _tempoW = 38.0;
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
      sections: d.loaded && controller.showSections
          ? sectionsFor(d.bandDetail, d.bandsPerSec, d.bpm, d.beatOffset, d.duration)
          : const [],
      fullWave: controller.fullWaveform,
      playing: d.playing,
      zoom: zoom,
      onOverviewSeek: d.loaded ? (t) => controller.seekTo(index, t) : null,
      onScrub: d.loaded ? (t) => controller.seekTo(index, t) : null,
      onZoom: d.loaded ? onZoom : null,
    );

    Widget detail = wave(WavePart.detail);
    // In GRID mode the wave still scrubs and zooms (BEAT HERE / BAR HERE need
    // a kick under the playhead first); only the nudge glyphs step aside.
    if (d.loaded && !gridEditing) {
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
    if (index == 0 && (controller.recording || controller.recordingSaving)) {
      final plain = detail;
      detail = Stack(
        fit: StackFit.expand,
        children: [plain, Positioned(top: 6, right: 8, child: _recTimer())],
      );
    }
    if (portrait) return _portraitBody(context, d, wave(WavePart.overview), detail);
    final rows = <Widget>[
      SizedBox(height: WaveformPainter.overviewH, child: wave(WavePart.overview)),
      SizedBox(height: _rowH, child: _controlRow(context, d)),
      Expanded(child: detail),
    ];

    Widget body = Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(width: _railW + (controller.showTempoFader ? _tempoW : 0), child: _rail(d)),
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

  /// Portrait: no side rail. Overview, a title/readout row, the performance
  /// row and a horizontal transport row, then the detail; deck B stacks the
  /// other way round so both details still meet at the line between decks.
  /// The tempo fader stays landscape-only (± and the SYNC pad set tempo).
  Widget _portraitBody(BuildContext context, DeckState d, Widget overview, Widget detail) {
    final tool = index == 0
        ? _railIcon(Icons.library_music, 'Library', onLibrary)
        : _railIcon(Icons.settings_outlined, 'Settings', onSettings);
    final info = Container(
      height: 26,
      color: SideDeckTheme.deckRow,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        children: [
          _deckTag(),
          const SizedBox(width: 6),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: d.loaded ? () => showTrackInfo(context, controller, index) : onLoad,
              child: d.loaded
                  ? _title(d)
                  : Text(
                      'Deck ${index == 0 ? 'A' : 'B'} — tap to load a track',
                      style: TextStyle(fontSize: 12, color: SideDeckTheme.deckDim),
                    ),
            ),
          ),
          const SizedBox(width: 8),
          if (index == 1) ...[_recButton(), const SizedBox(width: 10)],
          tool,
        ],
      ),
    );
    final readouts = Container(
      height: 20,
      color: SideDeckTheme.deckRow,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      alignment: Alignment.centerLeft,
      child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: _readouts(d)),
    );
    final perf = Container(
      height: _rowH,
      color: SideDeckTheme.deckRow,
      // Right-aligned, in line with the transport row's buttons below.
      padding: const EdgeInsets.only(left: 6, right: 10, top: 2, bottom: 2),
      child: d.loaded
          ? FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ...(gridEditing ? _gridEditor() : _performanceControls(context, d)),
                  if (controller.showGridButton) ...[
                    const SizedBox(width: 6),
                    _DeckButton(label: 'GRID', lit: gridEditing, width: 40, onTap: onToggleGrid),
                  ],
                ],
              ),
            )
          : const SizedBox.shrink(),
    );
    final jumpOk = d.loaded && d.bpm > 1;
    final transport = Container(
      height: 56,
      color: SideDeckTheme.deckRow,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          _cueButton(d),
          const SizedBox(width: 14),
          _playButton(d),
          const Spacer(),
          _railChip(icon: Icons.fast_rewind, enabled: jumpOk, onTap: () => controller.jump(index, -1)),
          const SizedBox(width: 6),
          _railChip(icon: Icons.fast_forward, enabled: jumpOk, onTap: () => controller.jump(index, 1)),
          const SizedBox(width: 6),
          _railChip(label: '${d.jumpBeats}', onTap: () => controller.cycleJumpSize(index)),
          const SizedBox(width: 6),
          if (controller.showQuantizeButton) ...[
            _railChip(label: 'Q', lit: d.quantize, onTap: () => controller.setQuantize(index, !d.quantize)),
            const SizedBox(width: 6),
          ],
          _railChip(label: 'KEY', lit: d.keylock, onTap: () => controller.setKeylock(index, !d.keylock)),
        ],
      ),
    );
    final rows = <Widget>[
      SizedBox(height: WaveformPainter.overviewH, child: overview),
      info,
      readouts,
      perf,
      transport,
      const SizedBox(height: 2),
      Expanded(child: detail),
    ];
    Widget body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: _hang ? rows.reversed.toList() : rows,
    );
    if (!d.loaded) {
      body = GestureDetector(behavior: HitTestBehavior.opaque, onTap: onLoad, child: body);
    }
    return ColoredBox(color: SideDeckTheme.deckBg, child: body);
  }

  static Color get _recRed => SideDeckTheme.p.rec;

  /// Mix recording (deck B): records the USB mixer's return, its mix with
  /// effects, and saves it to Music/SideDeck on stop. Lit red while
  /// recording; the time shows on deck A's waveform (see [_recTimer]).
  Widget _recButton() {
    final rec = controller.recording;
    final saving = controller.recordingSaving;
    final Widget label = saving
        ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  color: rec ? SideDeckTheme.p.onLit : _recRed,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 5),
              Text(
                'REC',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  height: 1,
                  color: rec ? SideDeckTheme.p.onLit : SideDeckTheme.buttonText,
                ),
              ),
            ],
          );
    return Tooltip(
      message: rec ? 'Stop and save the recording' : "Record the mixer's mix",
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: saving ? null : controller.toggleRecording,
        child: Container(
          width: 48,
          height: 28,
          alignment: Alignment.center,
          decoration: rec ? SideDeckTheme.raised(tint: _recRed) : SideDeckTheme.raised(),
          child: label,
        ),
      ),
    );
  }

  /// Recording time in red, top right of deck A's waveform.
  Widget _recTimer() {
    final secs = controller.recordingSeconds.floor();
    final h = secs ~/ 3600, m = (secs ~/ 60) % 60, s = secs % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    final time = h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
    return IgnorePointer(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: SideDeckTheme.p.scrim,
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(
          controller.recordingSaving ? 'SAVING…' : '● REC $time',
          style: TextStyle(
            color: _recRed,
            fontFamily: SideDeckTheme.displayFont,
            fontSize: 14,
            fontWeight: FontWeight.w800,
            height: 1,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }

  Widget _deckTag() => Container(
    width: 18,
    height: 14,
    alignment: Alignment.center,
    decoration: BoxDecoration(color: _tagColor, borderRadius: BorderRadius.circular(2)),
    child: Text(
      index == 0 ? 'A' : 'B',
      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: SideDeckTheme.deckBg, height: 1),
    ),
  );

  Widget _rail(DeckState d) {
    final tag = Container(
      width: 18,
      height: 14,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: _tagColor, borderRadius: BorderRadius.circular(2)),
      child: Text(
        index == 0 ? 'A' : 'B',
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: SideDeckTheme.deckBg, height: 1),
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
        child: Row(
          children: [
            tag,
            if (index == 1) ...[
              const SizedBox(width: 4),
              Flexible(child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: _recButton())),
              const SizedBox(width: 2),
            ],
            const Spacer(),
            tool,
          ],
        ),
      ),
      Expanded(
        // Keep clear of the centre line, so deck B's CUE isn't right against
        // deck A's buttons.
        child: Padding(
          padding: EdgeInsets.only(
            top: _hang ? 10 : 2,
            bottom: _hang ? 2 : 10,
            right: controller.showTempoFader ? 6 : 0,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _transport(d)),
              if (controller.showTempoFader) ...[const SizedBox(width: 6), _tempoColumn(d)],
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

  /// CDJ-style tempo column: KEY (key lock), the fader, and its range.
  Widget _tempoColumn(DeckState d) {
    final pct = (d.tempoRange * 100).round();
    return SizedBox(
      width: 30,
      child: Column(
        children: [
          _railChip(label: 'KEY', lit: d.keylock, onTap: () => controller.setKeylock(index, !d.keylock)),
          const SizedBox(height: 4),
          Expanded(
            child: TempoFader(
              value: controller.tempoFader(index),
              downIsFaster: controller.tempoDownFaster,
              enabled: d.loaded,
              onChanged: (v) => controller.setTempoFader(index, v),
              onReset: () => controller.resetTempo(index),
            ),
          ),
          const SizedBox(height: 4),
          _railChip(label: '±$pct', onTap: () => controller.cycleTempoRange(index)),
        ],
      ),
    );
  }

  Widget _transport(DeckState d) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      // Two columns: CUE over PLAY, and beside them rbxport's beat-jump
      // pair, our Q toggle and the jump-size box.
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Column(mainAxisSize: MainAxisSize.min, children: [_cueButton(d), const SizedBox(height: 12), _playButton(d)]),
          const SizedBox(width: 12),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _railChip(
                icon: Icons.fast_rewind,
                enabled: d.loaded && d.bpm > 1,
                onTap: () => controller.jump(index, -1),
              ),
              const SizedBox(height: 6),
              _railChip(
                icon: Icons.fast_forward,
                enabled: d.loaded && d.bpm > 1,
                onTap: () => controller.jump(index, 1),
              ),
              if (controller.showQuantizeButton) ...[
                const SizedBox(height: 6),
                _railChip(label: 'Q', lit: d.quantize, onTap: () => controller.setQuantize(index, !d.quantize)),
              ],
              const SizedBox(height: 6),
              _railChip(label: '${d.jumpBeats}', onTap: () => controller.cycleJumpSize(index)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _railIcon(IconData icon, String tooltip, VoidCallback onTap) {
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onTap,
        radius: 18,
        child: Icon(icon, size: 20, color: SideDeckTheme.p.icon),
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
    final fg = !enabled ? SideDeckTheme.deckOutline : (lit ? SideDeckTheme.p.onLit : SideDeckTheme.buttonText);
    final face = Container(
      width: 30,
      height: 24,
      alignment: Alignment.center,
      decoration: SideDeckTheme.raised(lit: lit),
      child: icon != null
          ? Icon(icon, size: 15, color: fg)
          : Text(
              label!,
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, height: 1, color: fg),
            ),
    );
    if (!enabled) return face;
    if (onStep != null) return HoldRepeatButton(onStep: onStep, child: face);
    return GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTap, child: face);
  }

  /// CDJ-style CUE (see DjController.cueDown): reacts on press, and release
  /// ends a cue preview, so it is a raw pointer listener rather than a tap.
  Widget _cueButton(DeckState d) {
    final p = SideDeckTheme.p;
    // Flat looks: an ink ring that fills orange while the cue previews.
    final ring = p.flat && d.cuePreview ? p.deckLit : p.cueRing;
    final face = Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: d.cuePreview ? ring : p.deckBg,
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
              : (d.cuePreview ? (p.flat ? p.onLit : Colors.black) : SideDeckTheme.buttonText),
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
    final p = SideDeckTheme.p;
    // Flat looks: an ink ring, filled orange while playing.
    final Color glyph;
    if (!d.loaded) {
      glyph = SideDeckTheme.deckOutline;
    } else if (p.flat) {
      glyph = lit ? p.onLit : p.deckText;
    } else {
      glyph = lit ? Colors.white : const Color(0xFFB4B4B4);
    }
    return Material(
      color: p.flat && lit ? p.playLit : p.deckBg,
      shape: CircleBorder(
        side: BorderSide(
          color: !d.loaded && p.flat ? p.deckOutline : (lit ? p.playLit : p.playRing),
          width: 2,
        ),
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

  Widget _controlRow(BuildContext context, DeckState d) {
    if (!d.loaded) {
      return Container(
        color: SideDeckTheme.deckRow,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        alignment: Alignment.centerLeft,
        child: Text(
          'Deck ${index == 0 ? 'A' : 'B'} — tap to load a track',
          style: TextStyle(fontSize: 12, color: SideDeckTheme.deckDim),
        ),
      );
    }
    final controls = gridEditing ? _gridEditor() : _performanceControls(context, d);
    return Container(
      color: SideDeckTheme.deckRow,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: Row(
        children: [
          // Title and readouts share what the buttons leave; readouts shrink
          // to fit rather than squeezing the title out.
          // GRID mode has more buttons: give the title less of the row.
          // Tap the title for the full track details.
          Expanded(
            flex: gridEditing ? 1 : 2,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => showTrackInfo(context, controller, index),
              child: _title(d),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 3,
            child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerRight, child: _readouts(d)),
          ),
          const SizedBox(width: 10),
          ...controls,
          if (controller.showGridButton) ...[
            const SizedBox(width: 6),
            _DeckButton(label: 'GRID', lit: gridEditing, width: 40, onTap: onToggleGrid),
          ],
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
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: SideDeckTheme.deckText),
          ),
          if (d.artist.isNotEmpty)
            TextSpan(
              text: '  ${d.artist}',
              style: TextStyle(fontSize: 12, color: SideDeckTheme.deckDim),
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
        // Auto gain at work: the level change applied to this track.
        if (controller.autoGain && d.autoGainDb.abs() >= 0.1) ...[
          sep(),
          _mono('${d.autoGainDb > 0 ? '+' : '−'}${d.autoGainDb.abs().toStringAsFixed(1)} dB', SideDeckTheme.deckDim),
        ],
      ],
    );
  }

  // Doto's dots need a little more size than the platform font to read.
  static TextStyle get _readoutStyle => SideDeckTheme.displayFont == null
      ? const TextStyle(fontSize: 12.5, fontFeatures: [FontFeature.tabularFigures()], height: 1)
      : TextStyle(fontFamily: SideDeckTheme.displayFont, fontSize: 14, fontWeight: FontWeight.w700, height: 1);

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

  /// Long-press SYNC: type the exact tempo this deck should play at.
  Future<void> _enterBpm(BuildContext ctx, DeckState d) async {
    HapticFeedback.mediumImpact();
    final bpm = await showBpmPad(
      ctx,
      title: 'Deck ${index == 0 ? 'A' : 'B'} tempo',
      current: d.bpm * d.rate,
      trackBpm: d.bpm,
    );
    if (bpm != null) controller.setBpm(index, bpm);
  }

  List<Widget> _performanceControls(BuildContext context, DeckState d) {
    final beats = d.loopBars * 4;
    final beatsLabel = (beats - beats.round()).abs() < 0.05 ? '${beats.round()}' : beats.toStringAsFixed(1);
    final canHalf = beats > DjController.loopBeats.first + 0.05;
    final canDouble = beats < DjController.loopBeats.last - 0.05;
    final hasBpm = d.bpm > 1;
    final canSync = controller.deck(1 - index).loaded;
    const gap = SizedBox(width: 3);
    const groupGap = SizedBox(width: 8);
    return [
      if (controller.showHotCues) ...[
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
      ],
      // Loop: ‹ halves, the beat count toggles the loop (lit while on), › doubles.
      _DeckButton(
        label: 'Halve loop',
        icon: Icons.chevron_left,
        enabled: canHalf,
        onStep: () => controller.halfLoop(index),
      ),
      gap,
      _DeckButton(
        label: beatsLabel,
        display: true,
        width: 36,
        lit: d.loopEnabled,
        onTap: () => controller.setLoop(index, !d.loopEnabled, d.loopBars == 0 ? 1 : d.loopBars),
      ),
      gap,
      _DeckButton(
        label: 'Double loop',
        icon: Icons.chevron_right,
        enabled: canDouble,
        onStep: () => controller.doubleLoop(index),
      ),
      groupGap,
      _DeckButton(label: '−', enabled: hasBpm, onStep: () => controller.nudgeBpm(index, -0.1)),
      gap,
      _DeckButton(
        label: 'SYNC',
        width: 40,
        lit: d.synced,
        enabled: canSync || hasBpm,
        // Tap syncs to the other deck, tap again releases; hold to type a BPM.
        onTap: canSync || d.synced ? () => controller.toggleSync(index) : null,
        onLongPress: hasBpm ? () => _enterBpm(context, d) : null,
      ),
      gap,
      _DeckButton(label: '+', enabled: hasBpm, onStep: () => controller.nudgeBpm(index, 0.1)),
    ];
  }

  /// GRID mode: fix a grid by hand. Tempo changes stretch about the beat at
  /// the playhead; every change can be undone.
  List<Widget> _gridEditor() {
    const gap = SizedBox(width: 3);
    const groupGap = SizedBox(width: 8);
    return [
      _DeckButton(label: 'BEAT', sub: 'HERE', width: 38, onTap: () => controller.gridBeatHere(index)),
      gap,
      _DeckButton(label: 'BAR', sub: 'HERE', width: 38, onTap: () => controller.gridBarHere(index)),
      groupGap,
      _DeckButton(label: '‹', sub: '5 MS', onStep: () => controller.shiftGridMs(index, -5)),
      gap,
      _DeckButton(label: '›', sub: '5 MS', onStep: () => controller.shiftGridMs(index, 5)),
      groupGap,
      _DeckButton(label: '−', sub: '.01', onStep: () => controller.gridBpmStep(index, -0.01)),
      gap,
      _DeckButton(label: '+', sub: '.01', onStep: () => controller.gridBpmStep(index, 0.01)),
      gap,
      _DeckButton(label: '½', sub: 'BPM', onTap: () => controller.gridBpmScale(index, 0.5)),
      gap,
      _DeckButton(label: '×2', sub: 'BPM', onTap: () => controller.gridBpmScale(index, 2)),
      groupGap,
      _DeckButton(label: 'TAP', width: 36, onPress: () => controller.gridTap(index)),
      gap,
      _DeckButton(
        label: 'UNDO',
        width: 40,
        enabled: controller.canUndoGrid(index),
        onTap: () => controller.undoGrid(index),
      ),
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
  const _HotCuePad({required this.slot, required this.set, required this.onTap, required this.onClear});

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
        decoration: SideDeckTheme.raised(tint: set ? colour : null),
        child: Text(
          WaveformPainter.hotCueLabel(slot),
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, height: 1, color: set ? Colors.black : colour),
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
      ..color = SideDeckTheme.p.waveInk.withValues(alpha: alpha)
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
/// [onTap] fires once; [onStep] repeats while held; [onPress] fires the moment
/// the finger lands (tap tempo, where release timing would add jitter).
class _DeckButton extends StatelessWidget {
  const _DeckButton({
    required this.label,
    this.sub,
    this.width = 31,
    this.lit = false,
    this.enabled = true,
    this.onTap,
    this.onStep,
    this.onPress,
    this.onLongPress,
    this.icon,
    this.display = false,
  });

  /// Shown instead of [label] (which then only names the button).
  final IconData? icon;

  /// A value readout (the loop length) rather than a button: recessed.
  final bool display;
  final VoidCallback? onLongPress;
  final String label;
  final String? sub;
  final double width;
  final bool lit;
  final bool enabled;
  final VoidCallback? onTap;
  final VoidCallback? onStep;
  final VoidCallback? onPress;

  @override
  Widget build(BuildContext context) {
    final fg = !enabled
        ? SideDeckTheme.deckOutline
        : (display && lit ? SideDeckTheme.p.litText : (lit ? SideDeckTheme.p.onLit : SideDeckTheme.buttonText));
    final Widget content;
    if (sub != null) {
      content = Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, height: 1, color: fg),
          ),
          Text(
            sub!,
            style: TextStyle(
              fontSize: 7.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
              height: 1.1,
              color: lit ? SideDeckTheme.p.onLit : SideDeckTheme.deckDim,
            ),
          ),
        ],
      );
    } else if (icon != null) {
      content = Icon(icon, size: 20, color: fg);
    } else {
      content = Text(
        label,
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, height: 1, color: fg),
      );
    }
    final face = Container(
      width: width,
      height: 26,
      alignment: Alignment.center,
      // A readout sits sunk in a dark box, its text blue while on; buttons
      // are raised.
      decoration: display
          ? SideDeckTheme.recessed(radius: 3).copyWith(
              border: Border.all(color: lit ? SideDeckTheme.deckLit : SideDeckTheme.wellEdge),
            )
          : SideDeckTheme.raised(lit: lit),
      child: content,
    );
    if (!enabled) return face;
    if (onStep != null) return HoldRepeatButton(onStep: onStep!, child: face);
    if (onPress != null) {
      return Listener(behavior: HitTestBehavior.opaque, onPointerDown: (_) => onPress!(), child: face);
    }
    return GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTap, onLongPress: onLongPress, child: face);
  }
}

/// Vertical tempo fader, value -1..1 (0 = original tempo). Drag-only and
/// relative, so a stray tap never jumps the tempo; it clicks into 0 % on the
/// way through, and a double-tap resets. Down is faster when [downIsFaster]
/// (CDJ), and the stretch from the centre is filled like the mixer faders.
class TempoFader extends StatefulWidget {
  const TempoFader({
    super.key,
    required this.value,
    required this.onChanged,
    required this.onReset,
    this.downIsFaster = true,
    this.enabled = true,
  });

  final double value;
  final ValueChanged<double> onChanged;
  final VoidCallback onReset;
  final bool downIsFaster;
  final bool enabled;

  @override
  State<TempoFader> createState() => _TempoFaderState();
}

class _TempoFaderState extends State<TempoFader> {
  static const _detent = 0.03;
  double _raw = 0;

  void _start(DragStartDetails _) => _raw = widget.value;

  void _update(DragUpdateDetails e, double height) {
    if (height <= 0) return;
    // Full travel (top to bottom) covers the whole -1..1 range.
    final step = e.delta.dy / height * 2 * (widget.downIsFaster ? 1 : -1);
    final before = _raw;
    _raw = (_raw + step).clamp(-1.0, 1.0).toDouble();
    final was = before.abs() < _detent ? 0.0 : before;
    final now = _raw.abs() < _detent ? 0.0 : _raw;
    if (now == 0 && was != 0) HapticFeedback.selectionClick();
    if (now != was) widget.onChanged(now);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final fader = CustomPaint(
          size: Size(c.maxWidth, c.maxHeight),
          painter: _TempoFaderPainter(value: widget.value, downIsFaster: widget.downIsFaster, enabled: widget.enabled),
        );
        if (!widget.enabled) return fader;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragStart: _start,
          onVerticalDragUpdate: (e) => _update(e, c.maxHeight),
          onDoubleTap: () {
            HapticFeedback.selectionClick();
            widget.onReset();
          },
          child: fader,
        );
      },
    );
  }
}

class _TempoFaderPainter extends CustomPainter {
  _TempoFaderPainter({required this.value, required this.downIsFaster, required this.enabled});

  final double value;
  final bool downIsFaster;
  final bool enabled;

  static Color get _rail => SideDeckTheme.flat ? SideDeckTheme.p.rail : const Color(0xFF323232);
  static Color get _notch => SideDeckTheme.p.notch;
  static const _thumbH = 10.0;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final top = _thumbH / 2;
    final bottom = size.height - _thumbH / 2;
    final mid = (top + bottom) / 2;
    final half = (bottom - top) / 2;
    final y = mid + value * half * (downIsFaster ? 1 : -1);

    canvas.drawRect(Rect.fromLTRB(cx - 1.5, top, cx + 1.5, bottom), Paint()..color = _rail);
    if ((y - mid).abs() > 0.5) {
      canvas.drawRect(
        Rect.fromLTRB(cx - 1.5, math.min(y, mid), cx + 1.5, math.max(y, mid)),
        Paint()..color = SideDeckTheme.deckLit,
      );
    }
    // Centre (0 %) mark across the rail, and the faster end's "+".
    canvas.drawRect(Rect.fromCenter(center: Offset(cx, mid), width: 14, height: 1.5), Paint()..color = _notch);
    final plusY = downIsFaster ? bottom : top;
    final minusY = downIsFaster ? top : bottom;
    final glyph = Paint()
      ..color = _notch
      ..strokeWidth = 1.2;
    canvas.drawLine(Offset(size.width - 6, plusY - 3), Offset(size.width - 6, plusY + 3), glyph);
    canvas.drawLine(Offset(size.width - 9, plusY), Offset(size.width - 3, plusY), glyph);
    canvas.drawLine(Offset(size.width - 9, minusY), Offset(size.width - 3, minusY), glyph);

    if (!enabled) return;
    final body = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(cx, y), width: 20, height: _thumbH),
      const Radius.circular(2),
    );
    final flat = SideDeckTheme.flat;
    canvas.drawRRect(body, Paint()..color = flat ? SideDeckTheme.p.capFill : SideDeckTheme.deckOutline);
    canvas.drawRect(
      Rect.fromCenter(center: Offset(cx, y), width: 14, height: 1.5),
      Paint()..color = flat ? SideDeckTheme.p.capLine : const Color(0xFFD0D0D0),
    );
  }

  @override
  bool shouldRepaint(_TempoFaderPainter old) =>
      old.value != value || old.downIsFaster != downIsFaster || old.enabled != enabled;
}
