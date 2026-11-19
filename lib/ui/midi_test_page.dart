import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sidedeck/theme/sidedeck_theme.dart';

/// Debug: shows every MIDI message a USB mixer sends (see MidiMonitor.kt), so
/// we can see what each K.O. knob and button sends, with and without SELECT,
/// before mapping them to deck controls.
class MidiTestPage extends StatefulWidget {
  const MidiTestPage({super.key});

  @override
  State<MidiTestPage> createState() => _MidiTestPageState();
}

class _MidiMsg {
  _MidiMsg(this.status, this.channel, this.d1, this.d2, this.raw, this.time);

  final int status;
  final int channel;
  final int d1;
  final int d2;
  final String raw;
  final DateTime time;

  /// One row per control: channel + message type + controller/note number.
  String get key => status == 0xE0 ? '$channel/$status' : '$channel/$status/$d1';

  /// Pitch bend is 14-bit; everything else shows its second data byte.
  int get value => status == 0xE0 ? (d2 << 7) | d1 : (status == 0xC0 || status == 0xD0 ? d1 : d2);

  String get kind => switch (status) {
    0x80 => 'note off $d1',
    0x90 => 'note on $d1',
    0xA0 => 'aftertouch $d1',
    0xB0 => 'CC $d1',
    0xC0 => 'program',
    0xD0 => 'pressure',
    0xE0 => 'pitch bend',
    _ => 'status ${status.toRadixString(16)}',
  };

  /// What the EP-136 guide (MIDI note map) says this is. Channel 1 and 2 are
  /// the two sides; "+ SELECT" is the variant sent while SELECT is held.
  String? get koLabel {
    if (status == 0xE0 && channel == 3) return 'mod stick';
    if (status != 0xB0) return null;
    if (channel == 3) {
      return switch (d1) {
        1 => 'force pad',
        2 => 'force pad + SELECT',
        _ => null,
      };
    }
    if (channel != 1 && channel != 2) return null;
    final side = channel == 1 ? 'left' : 'right';
    final name = switch (d1) {
      20 => 'gain knob',
      25 => 'gain knob + SELECT',
      21 => 'gain button',
      26 => 'gain button + SELECT',
      3 => 'cue button',
      52 => 'cue button + SELECT',
      14 => 'fx button',
      15 => 'fx button + SELECT',
      22 => 'eq high',
      27 => 'eq high + SELECT',
      23 => 'eq mid',
      28 => 'eq mid + SELECT',
      24 => 'eq low',
      29 => 'eq low + SELECT',
      7 => 'fader',
      9 => 'fader + SELECT',
      _ => null,
    };
    return name == null ? null : '$name ($side)';
  }
}

class _ControlStats {
  _ControlStats(_MidiMsg m) : last = m, min = m.value, max = m.value;

  _MidiMsg last;
  int min;
  int max;
  int count = 1;
  final values = <int>{};

  void add(_MidiMsg m) {
    last = m;
    count++;
    if (m.value < min) min = m.value;
    if (m.value > max) max = m.value;
    if (values.length < 8) values.add(m.value);
  }
}

class _MidiTestPageState extends State<MidiTestPage> {
  static const _events = EventChannel('sidedeck/midi');
  static const _maxLog = 300;

  StreamSubscription<dynamic>? _sub;
  String _status = 'Looking for a USB MIDI device…';
  bool _connected = false;
  final _log = <_MidiMsg>[];
  final _controls = <String, _ControlStats>{};
  final _order = <String>[]; // first-seen order, newest first

  @override
  void initState() {
    super.initState();
    _sub = _events.receiveBroadcastStream().listen(
      _onEvent,
      onError: (Object e) {
        if (mounted) setState(() => _status = 'Error: $e');
      },
    );
  }

  void _onEvent(dynamic raw) {
    if (raw is! Map || !mounted) return;
    switch (raw['event']) {
      case 'device':
        setState(() {
          _connected = true;
          _status = 'Listening to ${raw['name']}';
        });
      case 'none':
        setState(() {
          _connected = false;
          _status = 'No USB MIDI device. Plug the mixer in (USB mode Multi, MIDI on).';
        });
      case 'error':
        setState(() {
          _connected = false;
          _status = '${raw['error']}';
        });
      case 'msg':
        final m = _MidiMsg(
          (raw['status'] as num).toInt(),
          (raw['channel'] as num).toInt(),
          (raw['d1'] as num).toInt(),
          (raw['d2'] as num).toInt(),
          '${raw['raw']}',
          DateTime.now(),
        );
        setState(() {
          _log.insert(0, m);
          if (_log.length > _maxLog) _log.removeLast();
          final s = _controls[m.key];
          if (s == null) {
            _controls[m.key] = _ControlStats(m);
            _order.insert(0, m.key);
          } else {
            s.add(m);
          }
        });
    }
  }

  void _clear() => setState(() {
    _log.clear();
    _controls.clear();
    _order.clear();
  });

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  static TextStyle get _small => TextStyle(color: SideDeckTheme.muted, fontSize: 12, height: 1.4);
  static const _mono = TextStyle(fontFeatures: [FontFeature.tabularFigures()], fontSize: 13);

  String _clock(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:'
      '${t.second.toString().padLeft(2, '0')}.${(t.millisecond ~/ 10).toString().padLeft(2, '0')}';

  Widget _controlRow(_ControlStats s) {
    final m = s.last;
    final label = m.koLabel;
    final range = s.min == s.max ? '${s.min}' : '${s.min}–${s.max}';
    // A few distinct values (e.g. 0 and 127, or 1 and 127) say a lot about
    // whether it's a button, an absolute knob, or an endless encoder.
    final seen = s.values.length <= 6 ? '  seen ${(s.values.toList()..sort()).join(', ')}' : '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 128, child: Text('ch ${m.channel} · ${m.kind}', style: _mono)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label ?? 'not in the K.O. guide',
                  style: TextStyle(color: label == null ? SideDeckTheme.accentB : SideDeckTheme.text),
                ),
                Text('now ${m.value}  range $range  ×${s.count}$seen', style: _small),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Test MIDI input'),
        actions: [
          IconButton(
            tooltip: 'Clear',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: _log.isEmpty ? null : _clear,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Icon(
                _connected ? Icons.usb : Icons.usb_off,
                size: 18,
                color: _connected ? SideDeckTheme.playLit : SideDeckTheme.muted,
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(_status)),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Press and turn each control on the mixer, then again while holding SELECT. '
            'Note whether the mixer itself also reacts (volume, cue light, effect).',
            style: _small,
          ),
          const Divider(height: 28),
          Text('Controls (${_order.length})', style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          if (_order.isEmpty)
            Text('Nothing received yet.', style: _small)
          else
            for (final k in _order) _controlRow(_controls[k]!),
          const Divider(height: 28),
          const Text('Recent messages', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          for (final m in _log.take(60))
            Text(
              '${_clock(m.time)}  ${m.raw.padRight(9)}  ch ${m.channel} ${m.kind} = ${m.value}',
              style: _mono.copyWith(fontFamily: 'monospace', fontSize: 12),
            ),
        ],
      ),
    );
  }
}
