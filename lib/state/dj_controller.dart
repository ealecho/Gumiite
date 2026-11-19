import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidedeck/engine/analysis_cache.dart';
import 'package:sidedeck/engine/auto_cue.dart';
import 'package:sidedeck/engine/cue_store.dart';
import 'package:sidedeck/engine/history_store.dart';
import 'package:sidedeck/engine/mix_recorder.dart';
import 'package:sidedeck/engine/music_utils.dart' as music;
import 'package:sidedeck/engine/music_utils.dart' show KeyNotation;
import 'package:sidedeck/engine/native_engine.dart';
import 'package:sidedeck/engine/track_analyzer.dart';
import 'package:sidedeck/engine/usb_output.dart';
import 'package:sidedeck/rekordbox/rekordbox_store.dart';

class DeckState {
  String? path;
  /// The file actually opened when it differs from [path] (a cached copy).
  String? openPath;
  String title = 'Empty';
  String artist = '';
  bool loaded = false;
  bool playing = false;
  bool loopEnabled = false;
  double loopBars = 1;
  double loopStart = 0;
  double loopEnd = 0;
  double position = 0;
  double duration = 0;
  double bpm = 0;
  int key = -1;
  double rate = 1;
  bool synced = false;
  /// Main cue point (seconds); the engine resets it to 0 on load.
  double cuePoint = 0;
  /// Playing only while CUE is held from the cue point (CDJ cue preview).
  bool cuePreview = false;
  /// Hot cue positions in seconds per slot (A, B, C, D); negative = empty.
  List<double> hotCues = List.filled(NativeEngine.hotCueCount, -1);
  /// Snap cue, hot cue and loop-in to the beat grid (rbxport/Mixxx "Q").
  bool quantize = true;
  /// Beats moved by the rail's beat-jump buttons.
  int jumpBeats = 4;
  /// Share of kicks on the grid from analysis (0..1); negative = unknown.
  double gridConfidence = -1;
  bool get gridUnsure => gridConfidence >= 0 && gridConfidence < TrackAnalysis.unsureBelow;
  double beatOffset = 0;
  double gain = 1;
  /// Auto gain applied on top of [gain], dB (0 when off or unknown).
  double autoGainDb = 0;
  /// The loaded track's level, from the engine's load scan (dBFS; -100 unknown).
  double loudnessDb = -100;
  double peakDb = -100;
  double fader = 1;
  double filter = 0;
  double eqLow = 0;
  double eqMid = 0;
  double eqHigh = 0;

  /// 3-band waveform (low/mid/high bytes per column); see NativeEngine.waveBands.
  Uint8List bandDetail = Uint8List(0);
  Uint8List bandOverview = Uint8List(0);
  int bandsPerSec = 150;

  /// Tempo fader range: full travel is ±this (see DjController.tempoRanges).
  double tempoRange = 0.08;
  /// Key lock (master tempo): pitch held while the tempo changes.
  bool keylock = true;

  /// Seconds this load has been heard (see DjController.playedAfterSec).
  double audibleSec = 0;
  /// Logged to the play history already for this load.
  bool logged = false;
}

class DjController extends ChangeNotifier {
  DjController() {
    _engine = NativeEngine.open();
    _ticker = Timer.periodic(const Duration(milliseconds: 50), (_) => _tick());
    if (!_engine.started) {
      engineError = 'Audio engine failed to start.';
    }
    _usbSub = UsbOutput.events().listen(_onUsbEvent);
    _loadKeyNotation();
    _loadAutoGain();
    _loadShowFilter();
    _loadHistory();
    _loadTempoPrefs();
    _loadScreenPrefs();
    _recoverRecording();
  }

  // Tempo fader and key lock, per deck, after the CDJ's TEMPO range and
  // MASTER TEMPO buttons.
  static const tempoRanges = [0.08, 0.16, 0.50];

  /// Fader pulled down speeds up, as on a CDJ; off, up speeds up.
  bool tempoDownFaster = true;

  /// The rail's tempo column (KEY, fader, range); off by default for room.
  bool showTempoFader = false;

  Future<void> setShowTempoFader(bool on) async {
    showTempoFader = on;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('show_tempo_fader', on);
  }

  /// Intro / breakdown / drop / outro marks on the waveforms.
  bool showSections = true;

  Future<void> setShowSections(bool on) async {
    showSections = on;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('show_sections', on);
  }

  /// Scrolling waveforms mirrored round their middle; off, deck A grows up
  /// and deck B hangs down from the shared centre line (rbxport).
  bool fullWaveform = false;

  Future<void> setFullWaveform(bool on) async {
    fullWaveform = on;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('full_waveform', on);
  }

  /// The A–D hot cue pads in each deck's control row. Hidden, set cues keep
  /// their marks on the waveforms.
  bool showHotCues = true;

  Future<void> setShowHotCues(bool on) async {
    showHotCues = on;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('show_hot_cues', on);
  }

  // Mix recording: the USB mixer's return (its mix, effects included), saved
  // to Music/SideDeck on stop. See MixRecorder.
  bool recording = false;
  bool recordingSaving = false;
  double recordingSeconds = 0;
  Timer? _recordPoll;

  /// Latest outcome to show once ("Saved SideDeck mix … to Music/SideDeck").
  String? recordingMessage;

  void clearRecordingMessage() => recordingMessage = null;

  Future<void> toggleRecording() async {
    if (recordingSaving) return;
    if (recording) {
      await _stopRecording();
      return;
    }
    if (!externalMixer) {
      recordingMessage = 'Recording takes the mix from the USB mixer: turn on the external mixer first.';
      notifyListeners();
      return;
    }
    final r = await MixRecorder.start();
    if (r['permission'] == true) {
      recordingMessage = 'Allow recording audio, then tap REC again.';
    } else if (r['ok'] != true) {
      recordingMessage = '${r['error'] ?? 'Could not start recording.'}';
    } else {
      recording = true;
      recordingSeconds = 0;
      _recordPoll?.cancel();
      _recordPoll = Timer.periodic(const Duration(seconds: 1), (_) => _pollRecording());
    }
    notifyListeners();
  }

  Future<void> _pollRecording() async {
    final s = await MixRecorder.status();
    recordingSeconds = (s['seconds'] as num?)?.toDouble() ?? recordingSeconds;
    // The input died (unplugged): save what there is.
    if (recording && s['recording'] == false) {
      await _stopRecording();
      return;
    }
    notifyListeners();
  }

  Future<void> _stopRecording() async {
    _recordPoll?.cancel();
    _recordPoll = null;
    recording = false;
    recordingSaving = true;
    notifyListeners();
    final r = await MixRecorder.stop();
    recordingSaving = false;
    recordingMessage = r['ok'] == true
        ? 'Saved "${r['name']}" to ${r['where']}'
              '${'${r['error'] ?? ''}'.isEmpty ? '' : ' (${r['error']})'}'
        : '${r['error'] ?? 'Could not save the recording.'}';
    notifyListeners();
  }

  /// A take left behind by a crash or a killed app is saved on the next start.
  Future<void> _recoverRecording() async {
    if (!Platform.isAndroid) return;
    final r = await MixRecorder.recover();
    if (r['ok'] == true) {
      recordingMessage = 'Saved an unfinished recording, "${r['name']}", to ${r['where']}';
      notifyListeners();
    }
  }

  /// The GRID button (grid fix tools), off by default: grids are fixed while
  /// preparing a set, not during one.
  bool showGridButton = false;

  /// The Q button. Hidden, quantize keeps its setting (on by default).
  bool showQuantizeButton = false;

  Future<void> setShowGridButton(bool on) async {
    showGridButton = on;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('show_grid_button', on);
  }

  Future<void> setShowQuantizeButton(bool on) async {
    showQuantizeButton = on;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('show_quantize_button', on);
  }

  /// Settings → Screen: 0 follows the phone (and its rotation lock),
  /// 1 landscape only, 2 portrait only.
  int screenOrientation = 0;

  static const _orientations = [
    DeviceOrientation.values,
    [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight],
    [DeviceOrientation.portraitUp],
  ];

  Future<void> setScreenOrientation(int mode) async {
    screenOrientation = mode.clamp(0, 2);
    await SystemChrome.setPreferredOrientations(_orientations[screenOrientation]);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('screen_orientation', screenOrientation);
  }

  Future<void> _loadScreenPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    screenOrientation = (prefs.getInt('screen_orientation') ?? 0).clamp(0, 2);
    await SystemChrome.setPreferredOrientations(_orientations[screenOrientation]);
    notifyListeners();
  }

  /// Key lock on both decks, for the Settings switch.
  bool get keylockAll => deckA.keylock && deckB.keylock;

  Future<void> setKeylockAll(bool on) async {
    await setKeylock(0, on);
    await setKeylock(1, on);
  }

  Future<void> _loadTempoPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    for (var i = 0; i < 2; i++) {
      final d = deck(i);
      final range = prefs.getDouble('tempo_range_$i');
      if (range != null && tempoRanges.contains(range)) d.tempoRange = range;
      d.keylock = prefs.getBool('keylock_$i') ?? true;
      _engine.setKeylock(i, d.keylock);
    }
    tempoDownFaster = prefs.getBool('tempo_down_faster') ?? true;
    showTempoFader = prefs.getBool('show_tempo_fader') ?? false;
    showSections = prefs.getBool('show_sections') ?? true;
    fullWaveform = prefs.getBool('full_waveform') ?? false;
    showHotCues = prefs.getBool('show_hot_cues') ?? true;
    autoCue = prefs.getBool('auto_cue') ?? true;
    showGridButton = prefs.getBool('show_grid_button') ?? false;
    showQuantizeButton = prefs.getBool('show_quantize_button') ?? false;
    notifyListeners();
  }

  /// Fader position for the deck's current tempo, -1..1 (pegs at the ends
  /// when sync or the ± buttons went past the range).
  double tempoFader(int deckIndex) {
    final d = deck(deckIndex);
    return ((d.rate - 1) / d.tempoRange).clamp(-1.0, 1.0).toDouble();
  }

  void setTempoFader(int deckIndex, double v) {
    final d = deck(deckIndex);
    if (!d.loaded) return;
    setRate(deckIndex, (1 + v.clamp(-1.0, 1.0) * d.tempoRange).clamp(0.5, 2.0).toDouble());
  }

  void resetTempo(int deckIndex) {
    if (!deck(deckIndex).loaded) return;
    setRate(deckIndex, 1);
  }

  /// Next range; the tempo stays where it is.
  Future<void> cycleTempoRange(int deckIndex) async {
    final d = deck(deckIndex);
    final i = tempoRanges.indexOf(d.tempoRange);
    d.tempoRange = tempoRanges[(i + 1) % tempoRanges.length];
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('tempo_range_$deckIndex', d.tempoRange);
  }

  Future<void> setKeylock(int deckIndex, bool on) async {
    final d = deck(deckIndex);
    d.keylock = on;
    _engine.setKeylock(deckIndex, on);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('keylock_$deckIndex', on);
  }

  Future<void> setTempoDownFaster(bool on) async {
    tempoDownFaster = on;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('tempo_down_faster', on);
  }

  // Play history, after Mixxx's "played" marks and session history: a track
  // counts once it has been heard for [playedAfterSec] on one load.
  static const playedAfterSec = 30.0;

  /// Logged plays, oldest first.
  List<PlayedTrack> history = const [];

  /// Paths played in the session still going, for the library's marks.
  Set<String> playedPaths = const {};

  final Stopwatch _clock = Stopwatch()..start();
  Duration _lastTick = Duration.zero;

  Future<void> _loadHistory() async {
    try {
      history = await HistoryStore.instance.recent();
    } catch (_) {
      return;
    }
    _updatePlayed();
    notifyListeners();
  }

  void _updatePlayed() {
    final session = HistoryStore.currentSession(history, DateTime.now());
    playedPaths = {for (final t in session?.tracks ?? const <PlayedTrack>[]) t.path};
  }

  Future<void> clearHistory() async {
    history = const [];
    playedPaths = const {};
    notifyListeners();
    try {
      await HistoryStore.instance.clear();
    } catch (_) {}
  }

  /// Heard, not just running: a cue preview doesn't count, and on the phone's
  /// own mixer neither does a closed channel fader or crossfader. An external
  /// mixer's faders can't be seen, so there playing is enough.
  bool _audible(int i) {
    final d = deck(i);
    if (d.cuePreview) return false;
    if (externalMixer) return true;
    if (d.fader < 0.05) return false;
    return i == 0 ? xfader < 0.97 : xfader > 0.03;
  }

  void _countPlay(int i, double dt) {
    final d = deck(i);
    if (d.logged || d.path == null || !_audible(i)) return;
    d.audibleSec += dt;
    if (d.audibleSec < playedAfterSec) return;
    d.logged = true;
    final entry = PlayedTrack(
      path: d.path!,
      title: d.title,
      artist: d.artist,
      bpm: d.bpm,
      key: d.key,
      deck: i,
      playedAt: DateTime.now(),
      durationSec: d.duration,
    );
    history = [...history, entry];
    _updatePlayed();
    HistoryStore.instance.add(entry).catchError((_) {});
  }

  // On-screen mixer: the filter fader is optional (off by default) so the
  // strip stays EQ + crossfader and gives its room back to the decks.
  static const _showFilterPref = 'show_filter';

  bool showFilter = false;

  Future<void> _loadShowFilter() async {
    final prefs = await SharedPreferences.getInstance();
    final on = prefs.getBool(_showFilterPref) ?? false;
    if (on == showFilter) return;
    showFilter = on;
    notifyListeners();
  }

  /// Hiding the filter also opens it, so no deck stays filtered with no
  /// control on screen to undo it.
  Future<void> setShowFilter(bool on) async {
    showFilter = on;
    if (!on) {
      for (var i = 0; i < 2; i++) {
        if (deck(i).filter != 0) setFilter(i, 0);
      }
    }
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_showFilterPref, on);
  }

  static const _keyNotationPref = 'key_notation';

  KeyNotation get keyNotation => music.keyNotation;

  Future<void> _loadKeyNotation() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_keyNotationPref);
    final match = KeyNotation.values.where((n) => n.name == saved);
    if (match.isEmpty) return;
    music.keyNotation = match.first;
    notifyListeners();
  }

  /// Key display style for decks and library; saved across launches.
  Future<void> setKeyNotation(KeyNotation notation) async {
    music.keyNotation = notation;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyNotationPref, notation.name);
  }

  // Auto gain, after Mixxx's ReplayGain-based track gain: tracks are levelled
  // to a common loudness so a mix doesn't jump between quiet and hot masters.
  static const _autoGainPref = 'auto_gain';

  /// Loud parts are brought to this level. Most loud house masters already sit
  /// near it, so they change little; quiet ones are lifted.
  static const autoGainTargetDb = -10.0;
  static const _autoGainMinDb = -12.0;
  static const _autoGainMaxDb = 6.0;

  /// Headroom kept under full scale when boosting.
  static const _autoGainPeakCeilingDb = -0.3;

  bool autoGain = true;

  Future<void> _loadAutoGain() async {
    final prefs = await SharedPreferences.getInstance();
    final on = prefs.getBool(_autoGainPref) ?? true;
    if (on == autoGain) return;
    await setAutoGain(on);
  }

  Future<void> setAutoGain(bool on) async {
    autoGain = on;
    for (var i = 0; i < 2; i++) {
      _applyGain(i);
    }
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoGainPref, on);
  }

  /// The deck's gain to the engine: its own [DeckState.gain] times auto gain.
  void _applyGain(int deckIndex) {
    final d = deck(deckIndex);
    var db = 0.0;
    if (autoGain && d.loaded && d.loudnessDb > -99) {
      db = (autoGainTargetDb - d.loudnessDb).clamp(_autoGainMinDb, _autoGainMaxDb).toDouble();
      // Never boost the peak past the ceiling (the engine hard-clips at full scale).
      if (db > 0 && d.peakDb > -99) {
        db = math.min(db, math.max(0.0, _autoGainPeakCeilingDb - d.peakDb));
      }
    }
    d.autoGainDb = db;
    _engine.setGain(deckIndex, d.gain * math.pow(10, db / 20));
  }

  late final NativeEngine _engine;
  late final Timer _ticker;
  StreamSubscription<UsbHotplugEvent>? _usbSub;
  final AnalysisCache _analysisCache = AnalysisCache.instance;
  final Set<int> _declinedMixerIds = {};

  final DeckState deckA = DeckState();
  final DeckState deckB = DeckState();
  double xfader = 0.5;
  double master = 1.0;
  bool externalMixer = false;
  String usbDeviceName = '';
  int usbDeviceId = 0;
  UsbMixerOffer? mixerOffer;
  String? engineError;
  int? loadingDeck;
  String? loadingTitle;
  String? loadingPath;

  DeckState deck(int i) => i == 0 ? deckA : deckB;

  void clearError() {
    engineError = null;
    notifyListeners();
  }

  void _onUsbEvent(UsbHotplugEvent event) {
    if (event.attached) {
      _onUsbAttached(event);
    } else if (event.playbackStopped) {
      _onUsbPlaybackStopped(event);
    } else if (event.detached) {
      _onUsbDetached(event);
    }
  }

  void _onUsbPlaybackStopped(UsbHotplugEvent event) {
    if (!externalMixer) return;
    final name = UsbOutput.deviceLabel(
      usbDeviceName.isEmpty ? event.name : usbDeviceName,
    );
    setExternalMixer(false).then((_) {
      engineError = 'USB audio to $name stopped; audio is back on the phone.';
      notifyListeners();
    });
  }

  void _onUsbAttached(UsbHotplugEvent event) {
    if (externalMixer) return;
    if (_declinedMixerIds.contains(event.id)) return;
    if (mixerOffer?.id == event.id) return;
    mixerOffer = UsbMixerOffer(
      id: event.id,
      channels: event.channels,
      name: event.name,
    );
    notifyListeners();
  }

  void _onUsbDetached(UsbHotplugEvent event) {
    _declinedMixerIds.remove(event.id);
    final offeringThis = mixerOffer?.id == event.id;
    if (offeringThis) mixerOffer = null;
    if (externalMixer && usbDeviceId == event.id) {
      final name = UsbOutput.deviceLabel(
        usbDeviceName.isEmpty ? event.name : usbDeviceName,
      );
      setExternalMixer(false).then((_) {
        engineError = '$name disconnected; audio is back on the phone.';
        notifyListeners();
      });
      return;
    }
    if (offeringThis) notifyListeners();
  }

  Future<void> acceptMixerOffer() async {
    mixerOffer = null;
    notifyListeners();
    await setExternalMixer(true);
  }

  void declineMixerOffer() {
    final id = mixerOffer?.id;
    if (id != null) _declinedMixerIds.add(id);
    mixerOffer = null;
    notifyListeners();
  }

  void _tick() {
    final now = _clock.elapsed;
    // Capped so a stalled timer can't count a long gap as listening.
    final dt = math.min((now - _lastTick).inMicroseconds / 1e6, 0.5);
    _lastTick = now;
    var dirty = false;
    for (var i = 0; i < 2; i++) {
      final d = deck(i);
      if (!d.loaded || !d.playing) continue;
      d.position = _engine.position(i);
      d.playing = _engine.isPlaying(i);
      _countPlay(i, dt);
      if (d.loopEnabled) {
        _readLoop(i);
      }
      dirty = true;
    }
    if (dirty) notifyListeners();
    if (++_xrunTicks >= 40) {
      _xrunTicks = 0;
      _checkXruns();
    }
  }

  int _xrunTicks = 0;
  int _xrunsSeen = 0;

  /// Logs audio dropouts on the phone's own output every ~2 s, so a glitch
  /// heard mid-set can be matched in logcat. USB mode logs its own.
  void _checkXruns() {
    final n = _engine.xrunCount;
    if (n < 0) return;
    if (n < _xrunsSeen) _xrunsSeen = 0; // stream reopened
    if (n > _xrunsSeen) {
      debugPrint('audio: underrun x${n - _xrunsSeen} (total $n since the stream opened)');
      _xrunsSeen = n;
    }
  }

  /// Loads [path] onto a deck. [path] is the track's identity (cues, analysis,
  /// library); [openPath], when given, is the file the engine actually opens,
  /// e.g. a cached copy of a USB stick track Android won't open by path.
  Future<bool> loadFile(
    int deckIndex,
    String path, {
    String? title,
    String? artist,
    String? openPath,
  }) async {
    _dropPendingSeek(deckIndex);
    loadingDeck = deckIndex;
    loadingTitle = title ?? path.split(RegExp(r'[\\/]')).last;
    loadingPath = path;
    notifyListeners();
    await Future<void>.delayed(const Duration(milliseconds: 16));

    // A grid prepared in rekordbox is the user's own: it wins over ours.
    TrackAnalysis? cached = (await RekordboxStore.instance.track(path))?.analysis;
    if (cached != null && cached.bpm <= 0) cached = null;
    if (cached == null) {
      try {
        final stat = await File(openPath ?? path).stat();
        cached = await _analysisCache.get(
          path,
          stat.size,
          stat.modified.millisecondsSinceEpoch,
        );
      } catch (_) {}
    }

    final ok = _engine.load(
      deckIndex,
      openPath ?? path,
      bpm: cached?.bpm,
      key: cached?.key,
      beatOffset: cached?.beatOffset,
    );
    final d = deck(deckIndex);
    if (!ok) {
      loadingDeck = null;
      loadingTitle = null;
      loadingPath = null;
      final name = title ?? path.split(RegExp(r'[\\/]')).last;
      final detail = _engine.lastError();
      engineError = detail.isNotEmpty
          ? 'Could not load $name - $detail'
          : 'Could not decode $name (need MP3, WAV, FLAC, Opus, Ogg Vorbis, or AAC M4A).';
      notifyListeners();
      return false;
    }
    // A reload (e.g. after re-analysis) is the same play, not a new one.
    final reload = d.loaded && d.path == path;
    d.path = path;
    d.openPath = openPath;
    _gridUndo[deckIndex].clear(); // undo belongs to the track it was made on
    _taps[deckIndex].clear();
    d.title = title ?? path.split(RegExp(r'[\\/]')).last;
    d.artist = artist ?? '';
    d.loaded = true;
    d.playing = false;
    if (!reload) {
      d.audibleSec = 0;
      d.logged = false;
    }
    d.position = 0;
    d.cuePoint = 0;
    d.cuePreview = false;
    d.hotCues = List.filled(NativeEngine.hotCueCount, -1); // the engine clears them on load
    d.duration = _engine.duration(deckIndex);
    d.bpm = _engine.bpm(deckIndex);
    d.key = _engine.key(deckIndex);
    d.beatOffset = _engine.beatOffset(deckIndex);
    // A cached load skips analysis, so the engine only knows it after a fresh one.
    d.gridConfidence = cached?.gridConfidence ?? _engine.gridConfidence(deckIndex);
    d.rate = 1;
    d.synced = false;
    d.loopEnabled = false;
    d.loopStart = 0;
    d.loopEnd = 0;
    d.bandDetail = _engine.waveBands(deckIndex, overview: false);
    d.bandOverview = _engine.waveBands(deckIndex, overview: true);
    d.bandsPerSec = _engine.waveBandsPerSec;
    _engine.setRate(deckIndex, 1);
    _nudgeBend[deckIndex] = 0;
    final level = _engine.level(deckIndex);
    d.loudnessDb = level.loudnessDb;
    d.peakDb = level.peakDb;
    _applyGain(deckIndex);
    _engine.setFader(deckIndex, d.fader);
    _engine.setFilter(deckIndex, d.filter);
    _engine.setEq(deckIndex, d.eqLow, d.eqMid, d.eqHigh);

    if (cached == null) {
      try {
        final file = File(openPath ?? path);
        final stat = await file.stat();
        await _analysisCache.put(
          path: path,
          size: stat.size,
          mtime: stat.modified.millisecondsSinceEpoch,
          bpm: d.bpm,
          key: d.key,
          beatOffset: d.beatOffset,
          gridConfidence: d.gridConfidence,
        );
      } catch (_) {}
    }

    await _restoreCues(deckIndex, path);
    _autoCue(deckIndex, path);

    loadingDeck = null;
    loadingTitle = null;
    loadingPath = null;
    // If the other deck is synced to us and currently sounding, do not yank
    // its tempo to this new file. Hand tempo authority to the sounding deck.
    final other = 1 - deckIndex;
    if (deck(other).synced && deck(other).playing) {
      deck(other).synced = false;
    } else {
      _followMasterBpm(deckIndex);
    }
    notifyListeners();
    return true;
  }

  /// Bring back a track's saved cues. Like a CDJ, the deck then sits on its
  /// cue point, ready for CUE/PLAY.
  Future<void> _restoreCues(int deckIndex, String path) async {
    TrackCues? saved;
    try {
      saved = await CueStore.instance.get(path);
    } catch (_) {
      return;
    }
    final d = deck(deckIndex);
    if (saved == null || d.path != path || !d.loaded) return;
    for (var slot = 0; slot < d.hotCues.length && slot < saved.hotCues.length; slot++) {
      final t = saved.hotCues[slot];
      if (t < 0 || t >= d.duration) continue;
      _engine.setHotcue(deckIndex, slot, t);
      d.hotCues[slot] = t;
    }
    if (saved.cue > 0 && saved.cue < d.duration && !d.playing) {
      // The engine only sets the cue at the playhead, so park there first.
      _engine.seek(deckIndex, saved.cue);
      _engine.setCue(deckIndex);
      d.cuePoint = saved.cue;
      d.position = saved.cue;
    }
  }

  /// CDJ Auto Cue: with no saved cue, park on the first beat where the music
  /// starts (see [autoCuePoint]). Not saved, so a later grid fix moves it.
  void _autoCue(int deckIndex, String path) {
    final d = deck(deckIndex);
    if (!autoCue || d.path != path || !d.loaded || d.playing || d.cuePoint > 0) return;
    final t = autoCuePoint(d.bandDetail, d.bandsPerSec, d.bpm, d.beatOffset, d.duration);
    if (t <= 0) return;
    _engine.seek(deckIndex, t);
    _engine.setCue(deckIndex);
    d.cuePoint = t;
    d.position = t;
  }

  /// Settings → Deck buttons → Auto cue.
  bool autoCue = true;

  Future<void> setAutoCue(bool on) async {
    autoCue = on;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auto_cue', on);
  }

  void _saveCues(int deckIndex) {
    final d = deck(deckIndex);
    final path = d.path;
    if (path == null || !d.loaded) return;
    CueStore.instance
        .put(path, TrackCues(cue: d.cuePoint, hotCues: List.of(d.hotCues)))
        .catchError((Object _) {});
  }

  /// Re-read a track that was just re-analyzed, so a deck holding it picks up
  /// the new BPM and beat grid instead of keeping the stale one.
  Future<void> reloadIfLoaded(
    String path, {
    String? title,
    String? artist,
  }) async {
    for (var i = 0; i < 2; i++) {
      final d = deck(i);
      if (d.path != path) continue;
      await loadFile(
        i,
        path,
        title: title ?? d.title,
        artist: artist ?? d.artist,
        openPath: d.openPath,
      );
    }
  }

  void playPause(int deckIndex) {
    final d = deck(deckIndex);
    if (!d.loaded) return;
    if (d.cuePreview) {
      // PLAY during a cue preview keeps it playing once CUE is let go.
      d.cuePreview = false;
      notifyListeners();
      return;
    }
    final next = !d.playing;
    // A synced deck starting under a playing master snaps into beat phase,
    // as CDJ beat sync does. (A cue preview start is left exactly on the cue.)
    if (next && d.synced && deck(1 - deckIndex).playing) _alignPhase(deckIndex);
    _engine.play(deckIndex, next);
    d.playing = next;
    notifyListeners();
  }

  /// CDJ-style CUE press. Playing: back to the cue point and pause. Paused on
  /// the cue point: preview from it while held. Paused elsewhere: set the cue
  /// point here (drag the waveform to find the spot first).
  void cueDown(int deckIndex) {
    _dropPendingSeek(deckIndex);
    final d = deck(deckIndex);
    if (!d.loaded) return;
    if (d.playing) {
      _engine.jumpCue(deckIndex);
      _engine.play(deckIndex, false);
      d.playing = false;
      d.position = d.cuePoint;
    } else if ((d.position - d.cuePoint).abs() < 0.02) {
      _engine.play(deckIndex, true);
      d.playing = true;
      d.cuePreview = true;
    } else {
      if (d.quantize) {
        // Park on the nearest beat first: the engine sets the cue at the playhead.
        final beat = _nearestBeat(d, _engine.position(deckIndex));
        _engine.seek(deckIndex, beat);
      }
      _engine.setCue(deckIndex);
      d.cuePoint = _engine.position(deckIndex);
      d.position = d.cuePoint;
      _saveCues(deckIndex);
    }
    notifyListeners();
  }

  /// CUE release: ends a preview by returning to the cue point.
  void cueUp(int deckIndex) {
    _dropPendingSeek(deckIndex);
    final d = deck(deckIndex);
    if (!d.cuePreview) return;
    d.cuePreview = false;
    _engine.play(deckIndex, false);
    _engine.jumpCue(deckIndex);
    d.playing = false;
    d.position = d.cuePoint;
    notifyListeners();
  }

  /// Hot cue pad: an empty slot stores the playhead; a set slot jumps to it,
  /// keeping the deck playing or paused as it was.
  void hotCue(int deckIndex, int slot) {
    _dropPendingSeek(deckIndex);
    final d = deck(deckIndex);
    if (!d.loaded) return;
    if (d.hotCues[slot] < 0) {
      if (d.quantize) {
        _engine.setHotcue(deckIndex, slot, _nearestBeat(d, _engine.position(deckIndex)));
      } else {
        _engine.setHotcue(deckIndex, slot);
      }
      d.hotCues[slot] = _engine.hotcue(deckIndex, slot);
      _saveCues(deckIndex);
    } else if (d.quantize && d.playing && d.bpm > 1) {
      // Keep where we are within the beat, so the jump lands in time.
      final pos = _engine.position(deckIndex);
      final target = (d.hotCues[slot] + pos - _nearestBeat(d, pos))
          .clamp(0.0, math.max(0.0, d.duration))
          .toDouble();
      _engine.seek(deckIndex, target);
      d.position = target;
      _readLoop(deckIndex);
    } else {
      _engine.jumpHotcue(deckIndex, slot);
      // A playing deck applies the jump on the audio thread; show it now.
      d.position = d.hotCues[slot];
      _readLoop(deckIndex);
    }
    notifyListeners();
  }

  void clearHotCue(int deckIndex, int slot) {
    final d = deck(deckIndex);
    if (!d.loaded || d.hotCues[slot] < 0) return;
    _engine.clearHotcue(deckIndex, slot);
    d.hotCues[slot] = -1;
    _saveCues(deckIndex);
    notifyListeners();
  }

  /// Absolute seek (waveform scrub, overview tap or drag).
  ///
  /// A drag calls this on every pointer move, up to 120 times a second. On a
  /// playing keylock deck each engine seek re-primes the time-stretcher inside
  /// the audio callback, so the engine gets at most one seek per [_seekGap];
  /// the screen follows the finger every time and the last position always
  /// lands.
  void seekTo(int deckIndex, double seconds) {
    final d = deck(deckIndex);
    if (!d.loaded) return;
    final target = seconds.clamp(0.0, math.max(0.0, d.duration)).toDouble();
    d.position = target;
    _seekTarget[deckIndex] = target;
    final since = _clock.elapsed - _lastSeek[deckIndex];
    if (since >= _seekGap) {
      _seekTrail[deckIndex]?.cancel();
      _seekTrail[deckIndex] = null;
      _sendSeek(deckIndex);
    } else {
      _seekTrail[deckIndex] ??= Timer(_seekGap - since, () {
        _seekTrail[deckIndex] = null;
        _sendSeek(deckIndex);
      });
    }
    notifyListeners();
  }

  static const _seekGap = Duration(milliseconds: 40);
  final List<Duration> _lastSeek = [-_seekGap, -_seekGap];
  final List<double> _seekTarget = [0, 0];
  final List<Timer?> _seekTrail = [null, null];

  void _sendSeek(int deckIndex) {
    _lastSeek[deckIndex] = _clock.elapsed;
    if (!deck(deckIndex).loaded) return;
    _engine.seek(deckIndex, _seekTarget[deckIndex]);
    _readLoop(deckIndex);
  }

  /// A scrub seek still waiting must not land on top of a load or jump.
  void _dropPendingSeek(int deckIndex) {
    _seekTrail[deckIndex]?.cancel();
    _seekTrail[deckIndex] = null;
  }

  void setGain(int deckIndex, double v) {
    deck(deckIndex).gain = v;
    _applyGain(deckIndex);
    notifyListeners();
  }

  void setFader(int deckIndex, double v) {
    deck(deckIndex).fader = v;
    _engine.setFader(deckIndex, v);
    notifyListeners();
  }

  void setEq(int deckIndex, {double? low, double? mid, double? high}) {
    final d = deck(deckIndex);
    d.eqLow = low ?? d.eqLow;
    d.eqMid = mid ?? d.eqMid;
    d.eqHigh = high ?? d.eqHigh;
    _engine.setEq(deckIndex, d.eqLow, d.eqMid, d.eqHigh);
    notifyListeners();
  }

  void setFilter(int deckIndex, double amount) {
    deck(deckIndex).filter = amount;
    _engine.setFilter(deckIndex, amount);
    notifyListeners();
  }

  void setXfader(double x) {
    xfader = x;
    _engine.setXfader(x);
    notifyListeners();
  }

  void setMaster(double v) {
    master = v;
    _engine.setMaster(v);
    notifyListeners();
  }

  void setRate(int deckIndex, double rate) {
    final d = deck(deckIndex);
    d.rate = rate;
    d.synced = false;
    _applyRate(deckIndex);
    _followMasterBpm(deckIndex);
    notifyListeners();
  }

  final List<double> _nudgeBend = [0, 0]; // temporary pitch bend while held
  final List<Timer?> _nudgeHold = [null, null];

  void _applyRate(int deckIndex) {
    final d = deck(deckIndex);
    final effective = (d.rate * (1.0 + _nudgeBend[deckIndex])).clamp(0.5, 2.0);
    _engine.setRate(deckIndex, effective);
  }

  /// ±0.1 BPM (heard tempo). Rate is derived from the track's original BPM.
  void nudgeBpm(int deckIndex, double delta) {
    final d = deck(deckIndex);
    if (!d.loaded || d.bpm <= 0) return;
    final heard = d.bpm * d.rate;
    final tenths = (heard * 10).round() + (delta * 10).round();
    final next = (tenths / 10.0).clamp(d.bpm * 0.5, d.bpm * 2.0);
    d.rate = next / d.bpm;
    d.synced = false;
    _applyRate(deckIndex);
    _followMasterBpm(deckIndex);
    notifyListeners();
  }

  /// Hold to briefly speed up (+) or slow down (−) for beatmatching.
  /// While paused, the same buttons jog the playhead so you can cue visually.
  void startNudge(int deckIndex, {required bool faster}) {
    final d = deck(deckIndex);
    if (!d.loaded) return;
    _nudgeHold[deckIndex]?.cancel();
    if (d.playing) {
      _nudgeBend[deckIndex] = faster ? 0.08 : -0.08;
      _applyRate(deckIndex);
      notifyListeners();
      return;
    }
    _jogPaused(deckIndex, faster: faster);
    _nudgeHold[deckIndex] = Timer(const Duration(milliseconds: 350), () {
      _nudgeHold[deckIndex] = Timer.periodic(const Duration(milliseconds: 50), (
        _,
      ) {
        if (!deck(deckIndex).playing) {
          _jogPaused(deckIndex, faster: faster);
        }
      });
    });
  }

  void endNudge(int deckIndex) {
    _nudgeHold[deckIndex]?.cancel();
    _nudgeHold[deckIndex] = null;
    _nudgeBend[deckIndex] = 0;
    _applyRate(deckIndex);
    notifyListeners();
  }

  void _jogPaused(int deckIndex, {required bool faster}) {
    _dropPendingSeek(deckIndex);
    final d = deck(deckIndex);
    if (!d.loaded || d.playing) return;
    const step = 0.04; // 40 ms — visible on the 8 s zoom window, still fine
    final t = (d.position + (faster ? step : -step))
        .clamp(0.0, math.max(0.0, d.duration))
        .toDouble();
    _engine.seek(deckIndex, t);
    d.position = t;
    notifyListeners();
  }

  void setLoop(int deckIndex, bool enabled, [double? bars]) {
    final d = deck(deckIndex);
    if (bars != null) d.loopBars = bars.clamp(0.25, 8.0);
    final startsNow = enabled && !d.loopEnabled;
    d.loopEnabled = enabled;
    if (startsNow && d.quantize && d.bpm > 1) {
      // Quantized loop-in: start on the nearest beat, not the exact playhead.
      _engine.setLoopFrom(deckIndex, d.loopBars, _nearestBeat(d, _engine.position(deckIndex)));
    } else {
      _engine.setLoop(deckIndex, enabled, d.loopBars);
    }
    _readLoop(deckIndex);
    notifyListeners();
  }

  /// The beat grid line nearest [seconds]; [seconds] itself without a grid.
  double _nearestBeat(DeckState d, double seconds) {
    if (d.bpm <= 1) return seconds;
    final period = 60.0 / d.bpm;
    final k = ((seconds - d.beatOffset) / period).roundToDouble();
    return (d.beatOffset + k * period).clamp(0.0, math.max(0.0, d.duration)).toDouble();
  }

  void setQuantize(int deckIndex, bool on) {
    deck(deckIndex).quantize = on;
    notifyListeners();
  }

  static const jumpSizes = [1, 2, 4, 8, 16, 32];

  /// Rail size box: step through [jumpSizes].
  void cycleJumpSize(int deckIndex) {
    final d = deck(deckIndex);
    final i = jumpSizes.indexOf(d.jumpBeats);
    d.jumpBeats = jumpSizes[(i + 1) % jumpSizes.length];
    notifyListeners();
  }

  /// Rail beat-jump buttons: [direction] -1 back, +1 forward by jumpBeats.
  void jump(int deckIndex, int direction) {
    final d = deck(deckIndex);
    if (!d.loaded || d.bpm <= 1) return;
    beatJump(deckIndex, direction * d.jumpBeats);
  }

  static const loopBeats = [1.0, 2.0, 4.0, 8.0, 16.0, 32.0];

  void halfLoop(int deckIndex) {
    final d = deck(deckIndex);
    if (!d.loaded) return;
    final beats = d.loopBars * 4;
    final i = loopBeats.indexWhere((b) => (b - beats).abs() < 0.05);
    final next = i <= 0 ? loopBeats.first : loopBeats[i - 1];
    setLoop(deckIndex, d.loopEnabled, next / 4.0);
  }

  void doubleLoop(int deckIndex) {
    final d = deck(deckIndex);
    if (!d.loaded) return;
    final beats = d.loopBars * 4;
    var i = loopBeats.indexWhere((b) => (b - beats).abs() < 0.05);
    if (i < 0) i = 0;
    final next = i >= loopBeats.length - 1 ? loopBeats.last : loopBeats[i + 1];
    setLoop(deckIndex, d.loopEnabled, next / 4.0);
  }

  void _readLoop(int deckIndex) {
    final d = deck(deckIndex);
    if (!d.loopEnabled) {
      d.loopStart = 0;
      d.loopEnd = 0;
      return;
    }
    d.loopStart = _engine.loopStart(deckIndex);
    d.loopEnd = _engine.loopEnd(deckIndex);
  }

  void beatJump(int deckIndex, int beats) {
    _dropPendingSeek(deckIndex);
    _engine.beatJump(deckIndex, beats);
    deck(deckIndex).position = _engine.position(deckIndex);
    _readLoop(deckIndex);
    notifyListeners();
  }

  /// Match [slave] tempo to the other deck and keep following its BPM. With
  /// both decks playing it also snaps [slave] into beat phase (see
  /// [_alignPhase]). Press SYNC on the deck you want to change.
  void sync(int slave) {
    final masterIdx = 1 - slave;
    if (!deck(slave).loaded || !deck(masterIdx).loaded) return;
    _nudgeBend[slave] = 0;
    deck(slave).synced = true;
    deck(masterIdx).synced = false;
    _applySlaveTempo(slave);
    if (deck(slave).playing && deck(masterIdx).playing) _alignPhase(slave);
    notifyListeners();
  }

  /// SYNC button: a second press releases sync and keeps the tempo it had.
  void toggleSync(int deckIndex) {
    final d = deck(deckIndex);
    if (d.synced) {
      d.synced = false;
      notifyListeners();
    } else {
      sync(deckIndex);
    }
  }

  /// Set the heard tempo to an exact [heardBpm] (releases sync). Limited to
  /// half to double the track's own BPM, as the engine plays.
  void setBpm(int deckIndex, double heardBpm) {
    final d = deck(deckIndex);
    if (!d.loaded || d.bpm <= 1 || heardBpm <= 0) return;
    d.rate = (heardBpm / d.bpm).clamp(0.5, 2.0);
    d.synced = false;
    _nudgeBend[deckIndex] = 0;
    _applyRate(deckIndex);
    _followMasterBpm(deckIndex);
    notifyListeners();
  }

  /// Beat sync: shift [slave] by under half a beat so its position within
  /// the beat matches the other deck's. Both grids come from analysis (BPM
  /// and first-beat offset, in file seconds), so each uses its own period.
  void _alignPhase(int slave) {
    _dropPendingSeek(slave);
    final s = deck(slave);
    final m = deck(1 - slave);
    if (!s.loaded || !m.loaded || s.bpm <= 1 || m.bpm <= 1) return;
    double phase(int i, DeckState d) {
      final beats = (_engine.position(i) - d.beatOffset) / (60.0 / d.bpm);
      return beats - beats.floorToDouble();
    }

    var diff = phase(1 - slave, m) - phase(slave, s);
    diff -= diff.roundToDouble(); // shortest way round: -0.5 .. 0.5 beat
    if (diff.abs() < 0.002) return;
    final target = (_engine.position(slave) + diff * 60.0 / s.bpm)
        .clamp(0.0, math.max(0.0, s.duration))
        .toDouble();
    _engine.seek(slave, target);
    s.position = target;
  }

  double _tempoMatchRate(DeckState slave, DeckState master) {
    final slaveBpm = slave.bpm <= 0 ? 1.0 : slave.bpm;
    return (master.bpm * master.rate / slaveBpm).clamp(0.5, 2.0);
  }

  void _applySlaveTempo(int slave) {
    final d = deck(slave);
    final master = deck(1 - slave);
    if (!d.loaded || !master.loaded) return;
    d.rate = _tempoMatchRate(d, master);
    _applyRate(slave);
  }

  /// If [deckIndex] is the master of a synced slave, keep that slave matched.
  void _followMasterBpm(int deckIndex) {
    final slave = 1 - deckIndex;
    if (!deck(slave).synced) return;
    _applySlaveTempo(slave);
  }

  // Grid editing (GRID mode), after Mixxx's beats_* controls, openDJ and rbxport.
  static const _gridUndoDepth = 32;
  final List<List<(double, double)>> _gridUndo = [[], []]; // (bpm, beatOffset)
  final List<List<int>> _taps = [[], []]; // tap tempo, ms timestamps

  bool canUndoGrid(int deckIndex) => _gridUndo[deckIndex].isNotEmpty;

  /// Applies a hand-edited grid: normalises the offset to the first downbeat
  /// at or after the track start (whole bars, so bar numbers don't move),
  /// keeps a synced pair matched, clears "check grid" and saves it.
  void _setGrid(int deckIndex, double bpm, double beatOffset, {bool undoable = true}) {
    final d = deck(deckIndex);
    if (!d.loaded || bpm <= 1) return;
    if (undoable) {
      final stack = _gridUndo[deckIndex]..add((d.bpm, d.beatOffset));
      if (stack.length > _gridUndoDepth) stack.removeAt(0);
    }
    final bar = 4 * 60.0 / bpm;
    final offset = beatOffset - (beatOffset / bar).floorToDouble() * bar;
    _engine.setGrid(deckIndex, bpm, offset);
    d.bpm = bpm;
    d.beatOffset = offset;
    d.gridConfidence = -1; // hand-fixed: no longer "check grid"
    if (d.synced) _applySlaveTempo(deckIndex);
    _followMasterBpm(deckIndex);
    notifyListeners();
    _persistAnalysis(d, userEdited: true);
    // An imported track loads its grid from the stick import, so keep the fix there too.
    final path = d.path;
    if (path != null) RekordboxStore.instance.updateGrid(path, offset, bpm: bpm);
  }

  /// Moves the whole grid by [seconds] (the ‹ › 5 ms nudge).
  void nudgeGrid(int deckIndex, double seconds) {
    final d = deck(deckIndex);
    _setGrid(deckIndex, d.bpm, d.beatOffset + seconds);
  }

  void shiftGridMs(int deckIndex, int milliseconds) => nudgeGrid(deckIndex, milliseconds / 1000.0);

  /// BEAT HERE: the beat line nearest the playhead moves onto it.
  void gridBeatHere(int deckIndex) {
    final d = deck(deckIndex);
    if (!d.loaded || d.bpm <= 1) return;
    final pos = _engine.position(deckIndex);
    nudgeGrid(deckIndex, pos - _nearestBeat(d, pos));
  }

  /// BAR HERE: the playhead becomes bar 1, beat 1 (a downbeat).
  void gridBarHere(int deckIndex) {
    final d = deck(deckIndex);
    if (!d.loaded || d.bpm <= 1) return;
    _setGrid(deckIndex, d.bpm, _engine.position(deckIndex));
  }

  /// A new tempo, stretched about the beat line nearest the playhead so the
  /// beat you are looking at stays put.
  void _setGridTempo(int deckIndex, double bpm, {bool undoable = true}) {
    final d = deck(deckIndex);
    if (!d.loaded || d.bpm <= 1 || bpm <= 1) return;
    final anchor = _nearestBeat(d, _engine.position(deckIndex));
    final period = 60.0 / bpm;
    final k = ((anchor - d.beatOffset) / period).roundToDouble();
    _setGrid(deckIndex, bpm, anchor - k * period, undoable: undoable);
  }

  /// BPM ±0.01 (hold to repeat).
  void gridBpmStep(int deckIndex, double delta) {
    final d = deck(deckIndex);
    _setGridTempo(deckIndex, ((d.bpm + delta) * 100).roundToDouble() / 100);
  }

  /// ½ / ×2: the analysis caught half or double the real tempo.
  void gridBpmScale(int deckIndex, double factor) {
    final d = deck(deckIndex);
    final bpm = d.bpm * factor;
    if (bpm < 40 || bpm > 250) return;
    _setGridTempo(deckIndex, bpm);
  }

  /// TAP: once four taps are in, the BPM follows their average interval (the
  /// last sixteen); a pause of over two seconds starts over.
  void gridTap(int deckIndex) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final taps = _taps[deckIndex];
    if (taps.isNotEmpty && now - taps.last > 2000) taps.clear();
    taps.add(now);
    if (taps.length > 16) taps.removeAt(0);
    if (taps.length < 4) return;
    final interval = (taps.last - taps.first) / (taps.length - 1);
    final bpm = (60000 / interval * 100).roundToDouble() / 100;
    if (bpm < 40 || bpm > 250) return;
    // One undo step for a whole run of taps.
    _setGridTempo(deckIndex, bpm, undoable: taps.length == 4);
  }

  void undoGrid(int deckIndex) {
    final stack = _gridUndo[deckIndex];
    if (stack.isEmpty) return;
    final (bpm, offset) = stack.removeLast();
    _setGrid(deckIndex, bpm, offset, undoable: false);
  }

  Future<void> _persistAnalysis(DeckState d, {bool userEdited = false}) async {
    final path = d.path;
    if (path == null || path.isEmpty || d.bpm <= 0) return;
    try {
      final stat = await File(path).stat();
      await _analysisCache.put(
        path: path,
        size: stat.size,
        mtime: stat.modified.millisecondsSinceEpoch,
        bpm: d.bpm,
        key: d.key,
        beatOffset: d.beatOffset,
        userEdited: userEdited,
        gridConfidence: d.gridConfidence,
      );
    } catch (_) {}
  }

  Future<void> setExternalMixer(bool enabled) async {
    if (mixerOffer != null) {
      mixerOffer = null;
      notifyListeners();
    }
    var deviceId = 0;
    var usbChannels = 4;
    usbDeviceName = '';
    usbDeviceId = 0;
    await UsbOutput.stopPlayback();
    if (enabled) {
      final usb = await UsbOutput.find();
      if (usb != null) {
        deviceId = usb.id;
        usbDeviceName = usb.name;
        if (usb.channels >= 8) usbChannels = 8;
      }
    }
    final prepared = _engine.setExternalMixer(enabled);
    if (enabled && prepared && Platform.isAndroid) {
      final res = await UsbOutput.startPlayback(
        engineHandle: _engine.nativeHandle,
        deviceId: deviceId,
        channels: usbChannels,
      );
      externalMixer = res.ok;
      if (res.ok) {
        usbDeviceId = res.routedId != 0 ? res.routedId : deviceId;
        if (res.routedName.isNotEmpty) usbDeviceName = res.routedName;
        engineError = null;
      } else {
        await UsbOutput.stopPlayback();
        engineError =
            'This USB device cannot take Deck A and Deck B on separate '
            'channels; audio stayed on the phone.';
        _engine.setExternalMixer(false);
        externalMixer = false;
      }
    } else if (enabled && prepared && Platform.isIOS) {
      if (deviceId == 0) {
        _engine.setExternalMixer(false);
        externalMixer = false;
        engineError =
            'No USB mixer detected; audio stayed on the phone.';
      } else {
        externalMixer = true;
        usbDeviceId = deviceId;
        engineError = null;
      }
    } else if (enabled && !prepared) {
      engineError =
          'Could not open 4-channel USB output; audio stayed on the phone.';
      externalMixer = false;
    } else {
      externalMixer = false;
      if (!enabled) engineError = null;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _usbSub?.cancel();
    _recordPoll?.cancel();
    // Save a take still running when the app closes.
    if (recording) MixRecorder.stop();
    _ticker.cancel();
    _dropPendingSeek(0);
    _dropPendingSeek(1);
    _nudgeHold[0]?.cancel();
    _nudgeHold[1]?.cancel();
    UsbOutput.stopPlayback();
    _engine.dispose();
    super.dispose();
  }
}
