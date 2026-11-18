import 'package:flutter/services.dart';

/// Records a USB mixer's return: the stereo mix it sends back to the phone,
/// effects included (MixRecorder.kt). Android only.
class MixRecorder {
  static const _ch = MethodChannel('sidedeck/audio');

  static Map<String, dynamic> _map(Object? raw) =>
      raw is Map ? {for (final e in raw.entries) '${e.key}': e.value} : <String, dynamic>{};

  static Future<Map<String, dynamic>> _call(String method) async {
    try {
      return _map(await _ch.invokeMethod<Object?>(method));
    } catch (e) {
      return {'ok': false, 'error': '$e'};
    }
  }

  /// `ok`, or `permission: true` when Android has just asked for the mic.
  static Future<Map<String, dynamic>> start() => _call('startRecording');

  /// Stops and saves to Music/SideDeck: `name`, `where`, `seconds`, `gainDb`.
  static Future<Map<String, dynamic>> stop() => _call('stopRecording');

  /// `recording`, `seconds`, `error`.
  static Future<Map<String, dynamic>> status() => _call('recordingStatus');

  /// Saves a take left behind by a crash, if any (empty map when none).
  static Future<Map<String, dynamic>> recover() => _call('recoverRecording');
}
