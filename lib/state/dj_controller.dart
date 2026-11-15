import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidedeck/engine/analysis_cache.dart';
import 'package:sidedeck/engine/cue_store.dart';
import 'package:sidedeck/engine/music_utils.dart' as music;
import 'package:sidedeck/engine/music_utils.dart' show KeyNotation;
import 'package:sidedeck/engine/native_engine.dart';
import 'package:sidedeck/engine/track_analyzer.dart';
import 'package:sidedeck/engine/usb_output.dart';

class DeckState {
  String? path;
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
  double fader = 1;
  double filter = 0;
  double eqLow = 0;
  double eqMid = 0;
  double eqHigh = 0;
  Float32List waveMin = Float32List(0);
  Float32List waveMax = Float32List(0);

  /// 3-band waveform (low/mid/high bytes per column); see NativeEngine.waveBands.
  Uint8List bandDetail = Uint8List(0);
  Uint8List bandOverview = Uint8List(0);
  int bandsPerSec = 150;
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
    } else {
      _onUsbDetached(event);
    }
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
    var dirty = false;
    for (var i = 0; i < 2; i++) {
      final d = deck(i);
      if (!d.loaded || !d.playing) continue;
      d.position = _engine.position(i);
      d.playing = _engine.isPlaying(i);
      if (d.loopEnabled) {
        _readLoop(i);
      }
      dirty = true;
    }
    if (dirty) notifyListeners();
  }

  Future<bool> loadFile(
    int deckIndex,
    String path, {
    String? title,
    String? artist,
  }) async {
    loadingDeck = deckIndex;
    loadingTitle = title ?? path.split(RegExp(r'[\\/]')).last;
    loadingPath = path;
    notifyListeners();
    await Future<void>.delayed(const Duration(milliseconds: 16));

    TrackAnalysis? cached;
    try {
      final stat = await File(path).stat();
      cached = await _analysisCache.get(
        path,
        stat.size,
        stat.modified.millisecondsSinceEpoch,
      );
    } catch (_) {}

    final ok = _engine.load(
      deckIndex,
      path,
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
    d.path = path;
    d.title = title ?? path.split(RegExp(r'[\\/]')).last;
    d.artist = artist ?? '';
    d.loaded = true;
    d.playing = false;
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
    final wave = _engine.waveform(deckIndex);
    d.waveMin = wave.min;
    d.waveMax = wave.max;
    d.bandDetail = _engine.waveBands(deckIndex, overview: false);
    d.bandOverview = _engine.waveBands(deckIndex, overview: true);
    d.bandsPerSec = _engine.waveBandsPerSec;
    _engine.setRate(deckIndex, 1);
    _nudgeBend[deckIndex] = 0;
    _engine.setGain(deckIndex, d.gain);
    _engine.setFader(deckIndex, d.fader);
    _engine.setFilter(deckIndex, d.filter);
    _engine.setEq(deckIndex, d.eqLow, d.eqMid, d.eqHigh);

    if (cached == null) {
      try {
        final file = File(path);
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

    loadingDeck = null;
    loadingTitle = null;
    loadingPath = null;
    _followMasterBpm(deckIndex);
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

  /// Absolute seek (waveform scrub, overview, pause nudge).
  void seekTo(int deckIndex, double seconds) {
    final d = deck(deckIndex);
    if (!d.loaded) return;
    final target = seconds.clamp(0.0, math.max(0.0, d.duration)).toDouble();
    _engine.seek(deckIndex, target);
    d.position = target;
    _readLoop(deckIndex);
    notifyListeners();
  }

  void setGain(int deckIndex, double v) {
    deck(deckIndex).gain = v;
    _engine.setGain(deckIndex, v);
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

  /// Beat sync: shift [slave] by under half a beat so its position within
  /// the beat matches the other deck's. Both grids come from analysis (BPM
  /// and first-beat offset, in file seconds), so each uses its own period.
  void _alignPhase(int slave) {
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

  void nudgeGrid(int deckIndex, double seconds) {
    _engine.nudgeGrid(deckIndex, seconds);
    final d = deck(deckIndex);
    d.beatOffset = _engine.beatOffset(deckIndex);
    d.gridConfidence = -1; // hand-fixed: no longer "check grid"
    notifyListeners();
    _persistAnalysis(d, userEdited: true);
  }

  /// Shift the painted grid. Negative = earlier (yellow moves left).
  void shiftGridBeats(int deckIndex, int beats) {
    final d = deck(deckIndex);
    if (!d.loaded || d.bpm <= 1) return;
    nudgeGrid(deckIndex, beats * (60.0 / d.bpm));
  }

  void shiftGridMs(int deckIndex, int milliseconds) {
    if (!deck(deckIndex).loaded) return;
    nudgeGrid(deckIndex, milliseconds / 1000.0);
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
    _ticker.cancel();
    _nudgeHold[0]?.cancel();
    _nudgeHold[1]?.cancel();
    UsbOutput.stopPlayback();
    _engine.dispose();
    super.dispose();
  }
}
