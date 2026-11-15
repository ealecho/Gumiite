import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:sidedeck/engine/native_lib.dart';

typedef _CreateC = Pointer<Void> Function();
typedef _DestroyC = Void Function(Pointer<Void>);
typedef _StartC = Int32 Function(Pointer<Void>);
typedef _StopC = Void Function(Pointer<Void>);
typedef _SetModeC = Int32 Function(Pointer<Void>, Int32);
typedef _GetIntC = Int32 Function(Pointer<Void>);
typedef _LoadC = Int32 Function(Pointer<Void>, Int32, Pointer<Utf8>);
typedef _LastErrorC = Pointer<Utf8> Function();
typedef _LoadAnalyzedC = Int32 Function(
  Pointer<Void>,
  Int32,
  Pointer<Utf8>,
  Float,
  Int32,
  Float,
);
typedef _UnloadC = Void Function(Pointer<Void>, Int32);
typedef _PlayC = Void Function(Pointer<Void>, Int32, Int32);
typedef _SeekC = Void Function(Pointer<Void>, Int32, Double);
typedef _PosC = Double Function(Pointer<Void>, Int32);
typedef _PlayingC = Int32 Function(Pointer<Void>, Int32);
typedef _SetFloatDeckC = Void Function(Pointer<Void>, Int32, Float);
typedef _SetEqC = Void Function(Pointer<Void>, Int32, Float, Float, Float);
typedef _SetXfaderC = Void Function(Pointer<Void>, Float);
typedef _SetMasterC = Void Function(Pointer<Void>, Float);
typedef _GetBpmC = Float Function(Pointer<Void>, Int32);
typedef _GetKeyC = Int32 Function(Pointer<Void>, Int32);
typedef _NudgeC = Void Function(Pointer<Void>, Int32, Float);
typedef _SetGridC = Void Function(Pointer<Void>, Int32, Float, Float);
typedef _GetLevelC = Void Function(Pointer<Void>, Int32, Pointer<Float>, Pointer<Float>);
typedef _SetLoopC = Void Function(Pointer<Void>, Int32, Int32, Float);
typedef _SetLoopFromC = Void Function(Pointer<Void>, Int32, Float, Double);
typedef _BeatJumpC = Void Function(Pointer<Void>, Int32, Int32);
typedef _SetHotcueC = Void Function(Pointer<Void>, Int32, Int32, Double);
typedef _GetHotcueC = Double Function(Pointer<Void>, Int32, Int32);
typedef _WaveBinsC = Int32 Function();
typedef _BandColumnsC = Int32 Function(Pointer<Void>, Int32, Int32);
typedef _BandCopyC = Int32 Function(Pointer<Void>, Int32, Int32, Pointer<Uint8>, Int32);
typedef _WaveCopyC = Int32 Function(
  Pointer<Void>,
  Int32,
  Pointer<Float>,
  Pointer<Float>,
  Int32,
);

class NativeEngine {
  NativeEngine._(this._lib, this._handle);

  final DynamicLibrary _lib;
  final Pointer<Void> _handle;
  bool started = false;

  late final _destroy = _lib.lookupFunction<_DestroyC, void Function(Pointer<Void>)>(
    'dj_destroy',
  );
  late final _start = _lib.lookupFunction<_StartC, int Function(Pointer<Void>)>(
    'dj_start',
  );
  late final _stop = _lib.lookupFunction<_StopC, void Function(Pointer<Void>)>(
    'dj_stop',
  );
  late final _setMode = _lib
      .lookupFunction<_SetModeC, int Function(Pointer<Void>, int)>(
        'dj_set_output_mode',
      );
  late final _getChannels = _lib.lookupFunction<_GetIntC, int Function(Pointer<Void>)>(
    'dj_get_output_channels',
  );
  late final _load = _lib
      .lookupFunction<_LoadC, int Function(Pointer<Void>, int, Pointer<Utf8>)>(
        'dj_load',
      );
  late final _lastError = _lib
      .lookupFunction<_LastErrorC, Pointer<Utf8> Function()>('dj_last_error');
  late final _loadAnalyzed = _lib.lookupFunction<
    _LoadAnalyzedC,
    int Function(Pointer<Void>, int, Pointer<Utf8>, double, int, double)
  >('dj_load_with_analysis');
  late final _unload = _lib
      .lookupFunction<_UnloadC, void Function(Pointer<Void>, int)>('dj_unload');
  late final _play = _lib
      .lookupFunction<_PlayC, void Function(Pointer<Void>, int, int)>('dj_play');
  late final _setHotcue = _lib
      .lookupFunction<_SetHotcueC, void Function(Pointer<Void>, int, int, double)>(
        'dj_set_hotcue',
      );
  late final _getHotcue = _lib
      .lookupFunction<_GetHotcueC, double Function(Pointer<Void>, int, int)>('dj_get_hotcue');
  late final _jumpHotcue = _lib
      .lookupFunction<_BeatJumpC, void Function(Pointer<Void>, int, int)>('dj_jump_hotcue');
  late final _clearHotcue = _lib
      .lookupFunction<_BeatJumpC, void Function(Pointer<Void>, int, int)>('dj_clear_hotcue');
  late final _setCue = _lib
      .lookupFunction<_UnloadC, void Function(Pointer<Void>, int)>('dj_set_cue');
  late final _jumpCue = _lib
      .lookupFunction<_UnloadC, void Function(Pointer<Void>, int)>('dj_jump_cue');
  late final _seek = _lib
      .lookupFunction<_SeekC, void Function(Pointer<Void>, int, double)>('dj_seek');
  late final _position = _lib
      .lookupFunction<_PosC, double Function(Pointer<Void>, int)>('dj_position');
  late final _duration = _lib
      .lookupFunction<_PosC, double Function(Pointer<Void>, int)>('dj_duration');
  late final _playing = _lib
      .lookupFunction<_PlayingC, int Function(Pointer<Void>, int)>('dj_playing');
  late final _setGain = _lib
      .lookupFunction<_SetFloatDeckC, void Function(Pointer<Void>, int, double)>(
        'dj_set_gain',
      );
  late final _setEq = _lib
      .lookupFunction<
        _SetEqC,
        void Function(Pointer<Void>, int, double, double, double)
      >('dj_set_eq');
  late final _setFilter = _lib
      .lookupFunction<_SetFloatDeckC, void Function(Pointer<Void>, int, double)>(
        'dj_set_filter',
      );
  late final _setFader = _lib
      .lookupFunction<_SetFloatDeckC, void Function(Pointer<Void>, int, double)>(
        'dj_set_fader',
      );
  late final _setXfader = _lib
      .lookupFunction<_SetXfaderC, void Function(Pointer<Void>, double)>(
        'dj_set_xfader',
      );
  late final _setMaster = _lib
      .lookupFunction<_SetMasterC, void Function(Pointer<Void>, double)>(
        'dj_set_master',
      );
  late final _setRate = _lib
      .lookupFunction<_SetFloatDeckC, void Function(Pointer<Void>, int, double)>(
        'dj_set_rate',
      );
  late final _getBpm = _lib
      .lookupFunction<_GetBpmC, double Function(Pointer<Void>, int)>('dj_get_bpm');
  late final _getKey = _lib
      .lookupFunction<_GetKeyC, int Function(Pointer<Void>, int)>('dj_get_key');
  late final _getBeatOffset = _lib
      .lookupFunction<_GetBpmC, double Function(Pointer<Void>, int)>(
        'dj_get_beat_offset',
      );
  late final _getGridConfidence = _lib
      .lookupFunction<_GetBpmC, double Function(Pointer<Void>, int)>(
        'dj_get_grid_confidence',
      );
  late final _getLevel = _lib
      .lookupFunction<_GetLevelC, void Function(Pointer<Void>, int, Pointer<Float>, Pointer<Float>)>(
        'dj_get_level',
      );
  late final _setLoopFrom = _lib
      .lookupFunction<_SetLoopFromC, void Function(Pointer<Void>, int, double, double)>(
        'dj_set_loop_from',
      );
  late final _nudgeGrid = _lib
      .lookupFunction<_NudgeC, void Function(Pointer<Void>, int, double)>(
        'dj_nudge_grid',
      );
  late final _setGrid = _lib
      .lookupFunction<_SetGridC, void Function(Pointer<Void>, int, double, double)>(
        'dj_set_grid',
      );
  late final _setLoop = _lib
      .lookupFunction<_SetLoopC, void Function(Pointer<Void>, int, int, double)>(
        'dj_set_loop',
      );
  late final _loopStart = _lib
      .lookupFunction<_PosC, double Function(Pointer<Void>, int)>('dj_loop_start');
  late final _loopEnd = _lib
      .lookupFunction<_PosC, double Function(Pointer<Void>, int)>('dj_loop_end');
  late final _beatJump = _lib
      .lookupFunction<_BeatJumpC, void Function(Pointer<Void>, int, int)>(
        'dj_beat_jump',
      );
  late final _waveBins = _lib.lookupFunction<_WaveBinsC, int Function()>(
    'dj_waveform_bins',
  );
  late final _waveCopy = _lib
      .lookupFunction<
        _WaveCopyC,
        int Function(
          Pointer<Void>,
          int,
          Pointer<Float>,
          Pointer<Float>,
          int,
        )
      >('dj_waveform_copy');
  late final _bandsPerSec = _lib.lookupFunction<_WaveBinsC, int Function()>(
    'dj_wave_bands_per_sec',
  );
  late final _bandColumns = _lib
      .lookupFunction<_BandColumnsC, int Function(Pointer<Void>, int, int)>(
        'dj_wave_bands_columns',
      );
  late final _bandCopy = _lib
      .lookupFunction<
        _BandCopyC,
        int Function(Pointer<Void>, int, int, Pointer<Uint8>, int)
      >('dj_wave_bands_copy');

  static NativeEngine open() {
    late final DynamicLibrary lib;
    try {
      lib = openDjEngine();
    } catch (e) {
      throw StateError('Failed to open dj_engine library: $e');
    }
    late final Pointer<Void> Function() create;
    try {
      create = lib.lookupFunction<_CreateC, _CreateC>('dj_create');
    } catch (e) {
      throw StateError(
        'dj_create missing — native engine not linked into the iOS binary: $e',
      );
    }
    final handle = create();
    if (handle.address == 0) {
      throw StateError('dj_create returned null');
    }
    final engine = NativeEngine._(lib, handle);
    engine.started = engine._start(handle) == 1;
    return engine;
  }

  void dispose() {
    _stop(_handle);
    _destroy(_handle);
  }

  bool setExternalMixer(bool enabled) {
    final ok = _setMode(_handle, enabled ? 1 : 0) == 1;
    if (ok) started = true;
    return ok;
  }

  int get outputChannels => _getChannels(_handle);
  int get nativeHandle => _handle.address;

  bool load(
    int deck,
    String path, {
    double? bpm,
    int? key,
    double? beatOffset,
  }) {
    final p = path.toNativeUtf8();
    try {
      if (bpm != null && bpm > 1) {
        return _loadAnalyzed(
              _handle,
              deck,
              p,
              bpm,
              key ?? -1,
              beatOffset ?? 0,
            ) ==
            1;
      }
      return _load(_handle, deck, p) == 1;
    } finally {
      malloc.free(p);
    }
  }

  /// Reason for the last failed [load], or empty if none / success.
  String lastError() {
    final ptr = _lastError();
    if (ptr == nullptr) return '';
    return ptr.toDartString();
  }

  void unload(int deck) => _unload(_handle, deck);
  void play(int deck, bool playing) => _play(_handle, deck, playing ? 1 : 0);
  /// Cue point = the current playhead.
  void setCue(int deck) => _setCue(_handle, deck);
  void jumpCue(int deck) => _jumpCue(_handle, deck);

  /// Hot cue slots (see [hotCueCount]); seconds < 0 stores the playhead.
  static const hotCueCount = 4;
  void setHotcue(int deck, int slot, [double seconds = -1]) =>
      _setHotcue(_handle, deck, slot, seconds);
  /// Seconds, or a negative value when the slot is empty.
  double hotcue(int deck, int slot) => _getHotcue(_handle, deck, slot);
  void jumpHotcue(int deck, int slot) => _jumpHotcue(_handle, deck, slot);
  void clearHotcue(int deck, int slot) => _clearHotcue(_handle, deck, slot);
  void seek(int deck, double seconds) => _seek(_handle, deck, seconds);
  double position(int deck) => _position(_handle, deck);
  double duration(int deck) => _duration(_handle, deck);
  bool isPlaying(int deck) => _playing(_handle, deck) == 1;
  void setGain(int deck, double v) => _setGain(_handle, deck, v);
  void setEq(int deck, double low, double mid, double high) =>
      _setEq(_handle, deck, low, mid, high);
  void setFilter(int deck, double amount) => _setFilter(_handle, deck, amount);
  void setFader(int deck, double v) => _setFader(_handle, deck, v);
  void setXfader(double x) => _setXfader(_handle, x);
  void setMaster(double v) => _setMaster(_handle, v);
  void setRate(int deck, double rate) => _setRate(_handle, deck, rate);
  double bpm(int deck) => _getBpm(_handle, deck);
  int key(int deck) => _getKey(_handle, deck);
  double beatOffset(int deck) => _getBeatOffset(_handle, deck);
  /// Grid confidence from an analysis run at load (0..1); negative = unknown,
  /// including when the load used cached analysis.
  double gridConfidence(int deck) => _getGridConfidence(_handle, deck);

  /// The loaded track's loudness (loud parts) and peak in dBFS; -100 = unknown.
  ({double loudnessDb, double peakDb}) level(int deck) {
    final loud = malloc<Float>();
    final peak = malloc<Float>();
    try {
      loud.value = -100;
      peak.value = -100;
      _getLevel(_handle, deck, loud, peak);
      return (loudnessDb: loud.value, peakDb: peak.value);
    } finally {
      malloc.free(loud);
      malloc.free(peak);
    }
  }
  void nudgeGrid(int deck, double seconds) => _nudgeGrid(_handle, deck, seconds);
  /// Replace the grid: BPM and first-downbeat offset in seconds.
  void setGrid(int deck, double bpm, double beatOffset) => _setGrid(_handle, deck, bpm, beatOffset);
  void setLoop(int deck, bool enabled, double bars) =>
      _setLoop(_handle, deck, enabled ? 1 : 0, bars);
  /// Enable a loop of [bars] starting at [startSec] (quantized loop-in).
  void setLoopFrom(int deck, double bars, double startSec) =>
      _setLoopFrom(_handle, deck, bars, startSec);
  double loopStart(int deck) => _loopStart(_handle, deck);
  double loopEnd(int deck) => _loopEnd(_handle, deck);
  void beatJump(int deck, int beats) => _beatJump(_handle, deck, beats);

  ({Float32List min, Float32List max}) waveform(int deck) {
    final bins = _waveBins();
    final minPtr = malloc<Float>(bins);
    final maxPtr = malloc<Float>(bins);
    try {
      final n = _waveCopy(_handle, deck, minPtr, maxPtr, bins);
      return (
        min: Float32List.fromList(minPtr.asTypedList(n)),
        max: Float32List.fromList(maxPtr.asTypedList(n)),
      );
    } finally {
      malloc.free(minPtr);
      malloc.free(maxPtr);
    }
  }

  /// Detail columns per second of track in [waveBands] (overview: false).
  int get waveBandsPerSec => _bandsPerSec();

  /// Interleaved low/mid/high bytes (0..127) per column.
  Uint8List waveBands(int deck, {required bool overview}) {
    final cols = _bandColumns(_handle, deck, overview ? 1 : 0);
    if (cols <= 0) return Uint8List(0);
    final ptr = malloc<Uint8>(cols * 3);
    try {
      final n = _bandCopy(_handle, deck, overview ? 1 : 0, ptr, cols);
      return Uint8List.fromList(ptr.asTypedList(n * 3));
    } finally {
      malloc.free(ptr);
    }
  }
}
