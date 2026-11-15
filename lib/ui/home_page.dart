import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidedeck/engine/usb_output.dart';
import 'package:sidedeck/state/dj_controller.dart';
import 'package:sidedeck/state/library_controller.dart';
import 'package:sidedeck/theme/sidedeck_theme.dart';
import 'package:sidedeck/ui/deck_panel.dart';
import 'package:sidedeck/ui/library_drawer.dart';
import 'package:sidedeck/ui/mixer_strip.dart';
import 'package:sidedeck/ui/settings_page.dart';
import 'package:sidedeck/ui/waveform.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  DjController? _dj;
  LibraryController? _library;
  String? _bootError;
  int? _gridEditDeck;
  double _waveZoom = WaveformView.defaultZoom;
  bool _mixerHidden = false;
  bool _mixerDialogOpen = false;
  BuildContext? _mixerDialogContext;

  /// Only call from widgets built after a successful boot.
  DjController get _djReady => _dj!;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _loadMixerHidden();
    try {
      final dj = DjController();
      final library = LibraryController();
      dj.addListener(_onDjChanged);
      _dj = dj;
      _library = library;
    } catch (e, st) {
      _bootError = '$e\n$st';
    }
  }

  @override
  void dispose() {
    final dj = _dj;
    if (dj != null) {
      dj.removeListener(_onDjChanged);
      dj.dispose();
    }
    _library?.dispose();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  void _onDjChanged() {
    if (!mounted) return;
    final dj = _dj;
    if (dj == null) return;
    final err = dj.engineError;
    // Only when this route is on top — Settings shows its own SnackBar.
    if (err != null && (ModalRoute.of(context)?.isCurrent ?? false)) {
      final msg = err;
      dj.clearError();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg)),
        );
      });
    }
    final offer = dj.mixerOffer;
    if (offer == null) {
      if (_mixerDialogOpen) _dismissMixerDialog();
      return;
    }
    if (_mixerDialogOpen) return;
    _mixerDialogOpen = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final next = _dj?.mixerOffer;
      if (!mounted || next == null) {
        _mixerDialogOpen = false;
        return;
      }
      _showMixerOffer(next);
    });
  }

  void _dismissMixerDialog() {
    final ctx = _mixerDialogContext;
    if (ctx == null) return;
    _mixerDialogContext = null;
    if (ctx.mounted) Navigator.of(ctx).pop();
  }

  Future<void> _showMixerOffer(UsbMixerOffer offer) async {
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        _mixerDialogContext = ctx;
        return AlertDialog(
          backgroundColor: SideDeckTheme.panel,
          title: Text('${offer.label} detected'),
          content: const Text(
            'Enable external mixer mode? Deck A and Deck B go out as '
            'separate channels so you mix on hardware.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Not now'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Enable'),
            ),
          ],
        );
      },
    );
    _mixerDialogContext = null;
    _mixerDialogOpen = false;
    if (!mounted) return;
    final dj = _dj;
    if (dj == null) return;
    if (accepted == true) {
      await dj.acceptMixerOffer();
    } else if (dj.mixerOffer != null) {
      dj.declineMixerOffer();
    }
  }

  Future<void> _openSettings() async {
    final dj = _dj;
    if (dj == null) return;
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => SettingsPage(dj: dj)));
  }

  Future<void> _openLibrary() async {
    final dj = _dj;
    final library = _library;
    if (dj == null || library == null) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: false,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return FractionallySizedBox(
          heightFactor: 1,
          child: MediaQuery.removePadding(
            context: context,
            removeLeft: true,
            removeRight: true,
            child: LibraryOverlay(
              dj: dj,
              library: library,
              onOpenSettings: () async {
                Navigator.pop(context);
                await _openSettings();
              },
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final bootError = _bootError;
    if (bootError != null) {
      return Scaffold(
        backgroundColor: SideDeckTheme.bg,
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: SelectableText(
              'SideDeck failed to start\n\n$bootError',
              style: const TextStyle(
                color: SideDeckTheme.text,
                fontSize: 13,
                fontFamily: 'Courier',
              ),
            ),
          ),
        ),
      );
    }

    final dj = _djReady;
    final library = _library!;
    return AnimatedBuilder(
      animation: Listenable.merge([dj, library]),
      builder: (context, _) {
        return Scaffold(
          // Match the deck rails/mixer so L/R (and home-indicator) safe-area gutters blend in.
          backgroundColor: SideDeckTheme.deckRow,
          body: SafeArea(
            child: ColoredBox(
              color: Colors.black,
              child: Column(
                children: [
                  Expanded(flex: 6, child: _deck(0)),
                  // Shared center line: deck A's detail rises to it, deck B's hangs from it.
                  const SizedBox(height: 1, child: ColoredBox(color: Color(0xFF323232))),
                  Expanded(flex: 6, child: _deck(1)),
                  // External mixer: the hardware mixes, so the decks get the whole screen.
                  if (!dj.externalMixer)
                    if (_mixerHidden) _mixerHandle() else Expanded(flex: 5, child: _mixerBar()),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  static const _mixerHiddenPref = 'mixer_hidden';

  /// Hiding only takes the controls off screen; EQ, filter and crossfader
  /// keep their settings. Remembered across launches.
  Future<void> _setMixerHidden(bool hidden) async {
    setState(() => _mixerHidden = hidden);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_mixerHiddenPref, hidden);
  }

  Future<void> _loadMixerHidden() async {
    final prefs = await SharedPreferences.getInstance();
    final hidden = prefs.getBool(_mixerHiddenPref) ?? false;
    if (mounted && hidden != _mixerHidden) setState(() => _mixerHidden = hidden);
  }

  /// The slim strip left when the mixer is hidden: tap to bring it back.
  Widget _mixerHandle() {
    return Material(
      color: SideDeckTheme.deckRow,
      child: InkWell(
        onTap: () => _setMixerHidden(false),
        child: const SizedBox(
          height: 22,
          width: double.infinity,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.keyboard_arrow_up, size: 18, color: SideDeckTheme.deckDim),
              SizedBox(width: 4),
              Text(
                'MIXER',
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                  color: SideDeckTheme.deckDim,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _mixerBar() {
    return Stack(
      fit: StackFit.expand,
      children: [
        MixerStrip(controller: _djReady, onHide: () => _setMixerHidden(true)),
        if (_gridEditDeck != null)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _gridEditDeck = null),
            ),
          ),
      ],
    );
  }

  Widget _deck(int i) {
    return DeckPanel(
      controller: _djReady,
      index: i,
      gridEditing: _gridEditDeck == i,
      onToggleGrid: () => setState(() => _gridEditDeck = _gridEditDeck == i ? null : i),
      onLoad: _openLibrary,
      onLibrary: _openLibrary,
      onSettings: _openSettings,
      zoom: _waveZoom,
      onZoom: (z) => setState(() => _waveZoom = z),
    );
  }
}
