import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The looks the app can wear, picked in Settings.
enum SdLook {
  /// The original dark deck: raised grey buttons, blue when lit, colour
  /// waveforms.
  classic('Classic'),

  /// After fm1-sampler (github.com/ferluht/fm1-sampler): paper and ink, one
  /// orange for what is live, flat shapes, no gradients or shadows.
  paper('Paper'),

  /// Paper's dark variant: black paper, white ink, the same orange.
  ink('Ink');

  const SdLook(this.label);
  final String label;
}

/// Every colour the UI names, per look.
class SdPalette {
  const SdPalette({
    required this.flat,
    required this.dark,
    required this.bg,
    required this.panel,
    required this.panelAlt,
    required this.accentA,
    required this.accentB,
    required this.text,
    required this.muted,
    required this.deckBg,
    required this.deckRow,
    required this.deckButton,
    required this.deckText,
    required this.deckDim,
    required this.deckOutline,
    required this.deckLit,
    required this.onLit,
    required this.litText,
    required this.playRing,
    required this.playLit,
    required this.wellFill,
    required this.wellEdge,
    required this.divider,
    required this.icon,
    required this.cueRing,
    required this.rec,
    required this.scrim,
    required this.rail,
    required this.notch,
    required this.tick,
    required this.capFill,
    required this.capLine,
    required this.waveBg,
    required this.waveInk,
    required this.waveDim,
    required this.playhead,
    required this.beat,
    required this.beatHead,
    required this.downbeat,
    required this.downbeatHead,
    required this.cue,
    required this.loop,
    required this.loopAlpha,
    required this.barLabel,
    required this.barRim,
    required this.barPlayed,
    required this.phraseText,
    required this.error,
  });

  /// fm1 style: no gradients, no shadows, ink/dim waveforms.
  final bool flat;
  final bool dark;
  final Color bg, panel, panelAlt, accentA, accentB, text, muted;
  final Color deckBg, deckRow, deckButton, deckText, deckDim, deckOutline;

  /// Lit buttons, the EQ/tempo fill, synced readouts.
  final Color deckLit;

  /// Text on a lit button face.
  final Color onLit;

  /// A lit value readout's text (the loop length while looping).
  final Color litText;
  final Color playRing, playLit, wellFill, wellEdge;

  /// The line between the decks.
  final Color divider;

  /// Library / settings icons on the rails.
  final Color icon;
  final Color cueRing, rec;

  /// Behind text drawn over a waveform.
  final Color scrim;

  /// Fader rails, their centre notch, the ticks beside them, the cap.
  final Color rail, notch, tick, capFill, capLine;

  // Waveform.
  final Color waveBg;

  /// Flat looks: the played part (and the overview's), and what is to come.
  final Color waveInk, waveDim;
  final Color playhead, beat, beatHead, downbeat, downbeatHead, cue, loop;
  final double loopAlpha;
  final Color barLabel, barRim, barPlayed, phraseText;
  final Color error;

  static const classic = SdPalette(
    flat: false,
    dark: true,
    bg: Color(0xFF0E1116),
    panel: Color(0xFF171B22),
    panelAlt: Color(0xFF1E2430),
    accentA: Color(0xFF4CC9F0),
    accentB: Color(0xFFF72585),
    text: Color(0xFFE8ECF1),
    muted: Color(0xFF8B93A7),
    // Deck chrome after rbxport's player tokens (src/styles/tokens.css):
    // neutral greys for both decks, blue for anything lit.
    deckBg: Color(0xFF000000),
    deckRow: Color(0xFF1E1E1E),
    deckButton: Color(0xFF282828),
    deckText: Color(0xFFE6E6E6),
    deckDim: Color(0xFF878787),
    deckOutline: Color(0xFF646464),
    deckLit: Color(0xFF3571E3),
    onLit: Color(0xFFFFFFFF),
    litText: Color(0xFF6FA0F5),
    playRing: Color(0xFF36642A),
    playLit: Color(0xFF60D330),
    wellFill: Color(0xFF141414),
    wellEdge: Color(0xFF3A3A3A),
    divider: Color(0xFF323232),
    icon: Color(0xFFA0A0A0),
    cueRing: Color(0xFFEDB751),
    rec: Color(0xFFE53935),
    scrim: Color(0xCC000000),
    rail: Color(0xFF050505),
    notch: Color(0xFF8A8A8A),
    tick: Color(0xFF4A4A4A),
    capFill: Color(0xFF4A4A4A),
    capLine: Color(0xFFF0F0F0),
    waveBg: Color(0xFF000000),
    waveInk: Color(0xFFFFFFFF),
    waveDim: Color(0xFF6B6B6B),
    playhead: Color(0xFFE0E0E0),
    beat: Color(0xFF4C4C4C),
    beatHead: Color(0xFF7C7C7C),
    downbeat: Color(0xFFFFFFFF),
    downbeatHead: Color(0xFFEA3323),
    cue: Color(0xFFEA3323),
    loop: Color(0xFF3571E3),
    loopAlpha: 0.38,
    barLabel: Color(0xFF367BDA),
    barRim: Color(0xFF6B6B6B),
    barPlayed: Color(0xFFC8C8C8),
    phraseText: Color(0xFF9A9A9A),
    error: Color(0xFFFF6B6B),
  );

  // fm1-sampler's engine/ui/Theme.h, light variant: paper F1EFE9, surface
  // E4E1D8, raised D6D3C9, outline A8A59A, ink 111111, dim 9A968C,
  // accent FF5A0A. Text that must be read small is a shade darker than DIM.
  static const _paper = Color(0xFFF1EFE9);
  static const _surface = Color(0xFFE4E1D8);
  static const _raised = Color(0xFFD6D3C9);
  static const _outline = Color(0xFFA8A59A);
  static const _inkText = Color(0xFF111111);
  static const _dim = Color(0xFF9A968C);
  static const _dimText = Color(0xFF6F6B62);
  static const _orange = Color(0xFFFF5A0A);

  static const paper = SdPalette(
    flat: true,
    dark: false,
    bg: _paper,
    panel: _paper,
    panelAlt: _surface,
    accentA: _orange,
    accentB: _inkText,
    text: _inkText,
    muted: _dimText,
    deckBg: _paper,
    deckRow: _paper,
    deckButton: _surface,
    deckText: _inkText,
    deckDim: _dimText,
    deckOutline: _outline,
    deckLit: _orange,
    onLit: Color(0xFFFFFFFF),
    litText: _orange,
    playRing: _inkText,
    playLit: _orange,
    wellFill: _surface,
    wellEdge: _raised,
    divider: _raised,
    icon: _inkText,
    cueRing: _inkText,
    rec: _orange,
    scrim: Color(0xD9F1EFE9),
    rail: _raised,
    notch: _dim,
    tick: _raised,
    capFill: _inkText,
    capLine: _paper,
    waveBg: _paper,
    waveInk: _inkText,
    waveDim: Color(0xFFB9B5AA),
    playhead: _orange,
    beat: _raised,
    beatHead: _dim,
    downbeat: _dim,
    downbeatHead: _orange,
    cue: _orange,
    loop: _orange,
    loopAlpha: 0.16,
    barLabel: _inkText,
    barRim: _raised,
    barPlayed: _inkText,
    phraseText: _dimText,
    error: Color(0xFFC62828),
  );

  // Theme.h, dark variant: paper 000000, surface 101010, raised 222222,
  // outline 404040, ink FFFFFF, dim 6A6A6A, accent FF6A1F.
  static const _black = Color(0xFF000000);
  static const _surfaceD = Color(0xFF101010);
  static const _raisedD = Color(0xFF222222);
  static const _outlineD = Color(0xFF404040);
  static const _white = Color(0xFFFFFFFF);
  static const _dimD = Color(0xFF6A6A6A);
  static const _dimTextD = Color(0xFF8C8C8C);
  static const _orangeD = Color(0xFFFF6A1F);

  static const ink = SdPalette(
    flat: true,
    dark: true,
    bg: _black,
    panel: _black,
    panelAlt: _surfaceD,
    accentA: _orangeD,
    accentB: _white,
    text: _white,
    muted: _dimTextD,
    deckBg: _black,
    deckRow: _black,
    deckButton: _raisedD,
    deckText: _white,
    deckDim: _dimTextD,
    deckOutline: _outlineD,
    deckLit: _orangeD,
    onLit: _black,
    litText: _orangeD,
    playRing: _white,
    playLit: _orangeD,
    wellFill: _surfaceD,
    wellEdge: _raisedD,
    divider: _raisedD,
    icon: _white,
    cueRing: _white,
    rec: _orangeD,
    scrim: Color(0xD9000000),
    rail: Color(0xFF2A2A2A),
    notch: _dimD,
    tick: Color(0xFF2A2A2A),
    capFill: _white,
    capLine: _black,
    waveBg: _black,
    waveInk: _white,
    waveDim: Color(0xFF4A4A4A),
    playhead: _orangeD,
    beat: Color(0xFF2A2A2A),
    beatHead: _dimD,
    downbeat: _dimD,
    downbeatHead: _orangeD,
    cue: _orangeD,
    loop: _orangeD,
    loopAlpha: 0.2,
    barLabel: _white,
    barRim: _raisedD,
    barPlayed: _white,
    phraseText: _dimTextD,
    error: Color(0xFFFF6B6B),
  );

  static SdPalette of(SdLook look) => switch (look) {
    SdLook.classic => classic,
    SdLook.paper => paper,
    SdLook.ink => ink,
  };
}

class SideDeckTheme {
  static SdPalette _p = SdPalette.classic;

  /// The look in use. Listened to by the app root, which swaps the
  /// [ThemeData] and repaints every widget (see [setLook]).
  static final look = ValueNotifier<SdLook>(SdLook.classic);

  static SdPalette get p => _p;
  static bool get flat => _p.flat;

  static const _lookPref = 'ui_look';

  /// Reads the saved look; call before the first frame.
  static Future<void> loadLook() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final name = prefs.getString(_lookPref);
      final saved = SdLook.values.where((l) => l.name == name).firstOrNull;
      if (saved != null) _apply(saved);
    } catch (_) {
      // Keep Classic.
    }
  }

  static void _apply(SdLook l) {
    _p = SdPalette.of(l);
    look.value = l;
  }

  /// Switches the look and remembers it. Widgets read their colours from
  /// [SideDeckTheme] when they build and paint, so every element is rebuilt
  /// and repainted once (const widgets and painters included).
  static Future<void> setLook(SdLook l) async {
    if (l == look.value) return;
    _apply(l);
    void visit(Element e) {
      e.markNeedsBuild();
      if (e is RenderObjectElement) e.renderObject.markNeedsPaint();
      e.visitChildren(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(visit);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lookPref, l.name);
  }

  static Color get bg => _p.bg;
  static Color get panel => _p.panel;
  static Color get panelAlt => _p.panelAlt;
  static Color get accentA => _p.accentA;
  static Color get accentB => _p.accentB;
  static Color get text => _p.text;
  static Color get muted => _p.muted;

  static Color get deckBg => _p.deckBg;
  static Color get deckRow => _p.deckRow;
  static Color get deckButton => _p.deckButton;
  static Color get deckText => _p.deckText;
  static Color get deckDim => _p.deckDim;
  static Color get deckOutline => _p.deckOutline;
  static Color get deckLit => _p.deckLit;
  static Color get playRing => _p.playRing;
  static Color get playLit => _p.playLit;
  static Color get wellFill => _p.wellFill;
  static Color get wellEdge => _p.wellEdge;

  /// Every look sets text in Space Mono and readouts (times, tempo, bars)
  /// in Doto's dot matrix.
  static const bodyFont = 'SpaceMono';
  static const displayFont = 'Doto';

  /// Text and icons on an unlit button face.
  static Color get buttonText => _p.flat ? _p.deckText : Colors.white;

  // Depth for the classic deck controls: raised buttons lit from above,
  // recessed readouts and fader wells, so controls stand off the flat rows.
  static const _raisedTop = Color(0xFF3E3E3E);
  static const _raisedBottom = Color(0xFF2A2A2A);
  static const _raisedEdge = Color(0xFF4C4C4C);
  static const _litTop = Color(0xFF4A86F0);
  static const _litBottom = Color(0xFF2B5FC8);

  /// A button face; [lit] glows blue (orange when flat), [tint] colours an
  /// "on" face (e.g. a set hot cue in its slot colour).
  static BoxDecoration raised({bool lit = false, Color? tint, double radius = 3}) {
    if (_p.flat) {
      return BoxDecoration(
        color: tint ?? (lit ? _p.deckLit : _p.deckButton),
        borderRadius: BorderRadius.circular(2),
      );
    }
    final Color top, bottom, edge;
    if (tint != null) {
      top = Color.lerp(tint, Colors.white, 0.18)!;
      bottom = Color.lerp(tint, Colors.black, 0.18)!;
      edge = Color.lerp(tint, Colors.white, 0.35)!;
    } else if (lit) {
      top = _litTop;
      bottom = _litBottom;
      edge = const Color(0xFF6FA0F5);
    } else {
      top = _raisedTop;
      bottom = _raisedBottom;
      edge = _raisedEdge;
    }
    // A rounded box needs one border colour all round (Flutter can't paint
    // mixed sides with a radius), so the lit top edge is drawn into the
    // gradient and the rim is a single dark line.
    return BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [edge, top, bottom],
        stops: const [0, 0.1, 1],
      ),
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: const Color(0xFF101010), width: 1),
      boxShadow: [
        if (lit && tint == null) BoxShadow(color: _litTop.withValues(alpha: 0.35), blurRadius: 6),
        const BoxShadow(color: Color(0x66000000), blurRadius: 2, offset: Offset(0, 1)),
      ],
    );
  }

  /// A sunken box for readouts and fader wells: dark fill, thin rim. Flat
  /// looks have no wells: just the rim, square.
  static BoxDecoration recessed({double radius = 4}) => _p.flat
      ? BoxDecoration(
          borderRadius: BorderRadius.circular(2),
          border: Border.all(color: _p.wellEdge, width: 1.5),
        )
      : BoxDecoration(
          color: wellFill,
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: wellEdge, width: 1),
        );

  /// Material theme for the current look.
  static ThemeData theme() {
    final p = _p;
    final brightness = p.dark ? Brightness.dark : Brightness.light;
    final scheme = ColorScheme.fromSeed(
      seedColor: p.flat ? p.deckLit : p.accentA,
      brightness: brightness,
    );
    final base = ThemeData(
      brightness: brightness,
      useMaterial3: true,
      fontFamily: bodyFont,
      colorScheme: p.flat
          ? scheme.copyWith(
              primary: p.deckLit,
              onPrimary: p.onLit,
              surface: p.bg,
              onSurface: p.text,
              surfaceContainerHighest: p.panelAlt,
              outline: p.deckOutline,
              // The seeded tones lean brown next to the orange: the selected
              // segment, subtitles and dividers use the look's own colours.
              secondary: p.deckLit,
              onSecondary: p.onLit,
              secondaryContainer: p.deckLit,
              onSecondaryContainer: p.onLit,
              onSurfaceVariant: p.muted,
              outlineVariant: p.divider,
            )
          : scheme,
    );
    return base.copyWith(
      scaffoldBackgroundColor: p.bg,
      textTheme: base.textTheme.apply(bodyColor: p.text, displayColor: p.text),
      appBarTheme: p.flat
          ? AppBarTheme(backgroundColor: p.bg, foregroundColor: p.text, surfaceTintColor: Colors.transparent)
          : null,
      dividerColor: p.flat ? p.divider : null,
    );
  }
}
