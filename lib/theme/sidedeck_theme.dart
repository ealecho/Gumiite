import 'package:flutter/material.dart';

class SideDeckTheme {
  static const bg = Color(0xFF0E1116);
  static const panel = Color(0xFF171B22);
  static const panelAlt = Color(0xFF1E2430);
  static const accentA = Color(0xFF4CC9F0);
  static const accentB = Color(0xFFF72585);
  static const text = Color(0xFFE8ECF1);
  static const muted = Color(0xFF8B93A7);

  // Deck chrome after rbxport's player tokens (src/styles/tokens.css): neutral
  // greys for both decks, blue for anything lit. accentA/B survive only as tags.
  static const deckBg = Color(0xFF000000);
  static const deckRow = Color(0xFF1E1E1E);
  static const deckButton = Color(0xFF282828);
  static const deckPressed = Color(0xFF383838);
  static const deckText = Color(0xFFE6E6E6);
  static const deckDim = Color(0xFF878787);
  static const deckOutline = Color(0xFF646464);
  static const deckLit = Color(0xFF3571E3);
  static const playRing = Color(0xFF36642A);
  static const playLit = Color(0xFF60D330);

  // Depth for the deck controls: raised buttons lit from above, recessed
  // readouts and fader wells, so controls stand off the flat rows.
  static const _raisedTop = Color(0xFF3E3E3E);
  static const _raisedBottom = Color(0xFF2A2A2A);
  static const _raisedEdge = Color(0xFF4C4C4C);
  static const _litTop = Color(0xFF4A86F0);
  static const _litBottom = Color(0xFF2B5FC8);
  static const wellFill = Color(0xFF141414);
  static const wellEdge = Color(0xFF3A3A3A);

  /// A raised button face; [lit] glows blue, [tint] colours an "on" face
  /// (e.g. a set hot cue in its slot colour).
  static BoxDecoration raised({bool lit = false, Color? tint, double radius = 3}) {
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

  /// A sunken box for readouts and fader wells: dark fill, thin rim.
  static BoxDecoration recessed({double radius = 4}) => BoxDecoration(
    color: wellFill,
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(color: wellEdge, width: 1),
  );

  static ThemeData dark() {
    final base = ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: accentA,
        brightness: Brightness.dark,
      ),
    );
    return base.copyWith(
      scaffoldBackgroundColor: bg,
      textTheme: base.textTheme.apply(bodyColor: text, displayColor: text),
    );
  }
}
