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
