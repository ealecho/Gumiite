import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidedeck/engine/music_utils.dart';
import 'package:sidedeck/engine/usb_output.dart';
import 'package:sidedeck/state/dj_controller.dart';
import 'package:sidedeck/subsonic/subsonic_client.dart';
import 'package:sidedeck/theme/sidedeck_theme.dart';
import 'package:sidedeck/ui/midi_test_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.dj});

  final DjController dj;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _url = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  String? _status;
  bool _busy = false;
  bool _inputTesting = false;

  Future<void> _testUsbInput() async {
    setState(() => _inputTesting = true);
    final r = await UsbOutput.testInput(seconds: 60);
    if (!mounted) return;
    setState(() => _inputTesting = false);
    final ok = r['ok'] == true;
    final peak = (r['peakDb'] as List?)?.cast<num>() ?? const [];
    final rms = (r['rmsDb'] as List?)?.cast<num>() ?? const [];
    String lvl(num db) => db <= -119 ? 'silent' : '${db.toStringAsFixed(1)} dB';
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: SideDeckTheme.panel,
        title: Text(ok ? 'USB input: ${r['channels']} channels' : 'USB input test'),
        content: SingleChildScrollView(
          child: ok
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${r['device']} · ${r['sampleRate']} Hz · '
                      '${r['float'] == true ? '32-bit float' : '16-bit'} · '
                      '${(r['seconds'] as num).toStringAsFixed(1)} s',
                      style: TextStyle(color: SideDeckTheme.muted, fontSize: 12),
                    ),
                    const SizedBox(height: 10),
                    for (var i = 0; i < peak.length; i++)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text(
                          'Ch ${i + 1}:  peak ${lvl(peak[i])}   avg ${lvl(rms[i])}',
                          style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
                        ),
                      ),
                    const SizedBox(height: 10),
                    Text(
                      'Saved to ${r['path']}',
                      style: TextStyle(color: SideDeckTheme.muted, fontSize: 11),
                    ),
                  ],
                )
              : Text('${r['error'] ?? 'Failed'}'),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _url.text = prefs.getString('subsonic_url') ?? '';
    _user.text = prefs.getString('subsonic_user') ?? '';
    _pass.text = prefs.getString('subsonic_pass') ?? '';
    setState(() {});
  }

  Future<void> _saveAndTest() async {
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      await SubsonicClient.savePrefs(
        url: _url.text.trim(),
        user: _user.text.trim(),
        pass: _pass.text,
      );
      final client = SubsonicClient(
        baseUrl: _url.text.trim(),
        username: _user.text.trim(),
        password: _pass.text,
      );
      await client.ping();
      setState(() => _status = 'Connected OK');
    } catch (e) {
      setState(() => _status = 'Failed: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _url.dispose();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Look',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 8),
          Text(
            'Classic is the original dark deck. Paper and Ink are flat and '
            'minimal, after fm1-sampler: ink on paper (or white on black) with '
            'one orange for whatever is live.',
            style: TextStyle(color: SideDeckTheme.muted, fontSize: 12, height: 1.4),
          ),
          const SizedBox(height: 10),
          SegmentedButton<SdLook>(
            showSelectedIcon: false,
            segments: [
              for (final l in SdLook.values) ButtonSegment(value: l, label: Text(l.label)),
            ],
            selected: {SideDeckTheme.look.value},
            onSelectionChanged: (s) async {
              await SideDeckTheme.setLook(s.first);
              if (mounted) setState(() {});
            },
          ),
          const SizedBox(height: 24),
          const Text(
            'External mixer',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 8),
          Text(
            'Turn this on with a USB mixer plugged into the phone. Deck A and Deck B '
            'go out as separate channels so you mix and cue on the hardware — the '
            'on-screen EQ/crossfader hides. Works with devices such as the EP-136 '
            '(set USB mode to Multi). iPhone needs USB-C or a Lightning camera adapter.',
            style: TextStyle(color: SideDeckTheme.muted, fontSize: 12, height: 1.4),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Use external mixer'),
            subtitle: Text(
              widget.dj.externalMixer
                  ? 'ON — Deck A → channel 1, Deck B → channel 2 on the '
                      '${UsbOutput.deviceLabel(widget.dj.usbDeviceName)}'
                  : 'OFF — audio stays on the phone',
            ),
            value: widget.dj.externalMixer,
            onChanged: (v) async {
              final messenger = ScaffoldMessenger.of(context);
              await widget.dj.setExternalMixer(v);
              if (!mounted) return;
              setState(() {});
              final err = widget.dj.engineError;
              if (err != null) {
                messenger.showSnackBar(SnackBar(content: Text(err)));
                widget.dj.clearError();
              }
            },
          ),
          // Debug builds only: what does the mixer send back over USB?
          if (kDebugMode && Platform.isAndroid)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: _inputTesting
                  ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.mic_external_on_outlined),
              title: const Text('Test USB input (1 min)'),
              subtitle: Text(
                'Debug: records a minute from the mixer\'s USB input, every channel, '
                'and shows each one\'s level. Play a deck with a mixer effect on while it runs.',
                style: TextStyle(color: SideDeckTheme.muted, fontSize: 12, height: 1.4),
              ),
              onTap: _inputTesting ? null : _testUsbInput,
            ),
          if (kDebugMode && Platform.isAndroid)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.piano_outlined),
              title: const Text('Test MIDI input'),
              subtitle: Text(
                'Debug: shows every MIDI message the mixer sends as you press its buttons '
                'and turn its knobs (K.O.: USB mode Multi, MIDI on).',
                style: TextStyle(color: SideDeckTheme.muted, fontSize: 12, height: 1.4),
              ),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const MidiTestPage()),
              ),
            ),
          const Divider(height: 32),
          const Text(
            'On-screen mixer',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 8),
          Text(
            'Controls shown in the phone\'s own mixer, used when no external mixer '
            'is connected.',
            style: TextStyle(color: SideDeckTheme.muted, fontSize: 12, height: 1.4),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Filter'),
            subtitle: Text(
              'A FILT fader per deck: down for low-pass, up for high-pass. '
              'Turning it off resets both filters.',
              style: TextStyle(color: SideDeckTheme.muted, fontSize: 12, height: 1.4),
            ),
            value: widget.dj.showFilter,
            onChanged: (v) async {
              await widget.dj.setShowFilter(v);
              if (mounted) setState(() {});
            },
          ),
          const Divider(height: 32),
          const Text(
            'Screen',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 8),
          Text(
            'Upright, the decks stack with their buttons on the outside and the '
            'waveforms meeting in the middle. Auto turns with the phone and keeps to '
            'its rotation lock.',
            style: TextStyle(color: SideDeckTheme.muted, fontSize: 12, height: 1.4),
          ),
          const SizedBox(height: 8),
          // Upright there is no room for icons beside "Landscape".
          SegmentedButton<int>(
            segments: MediaQuery.sizeOf(context).width < 600
                ? const [
                    ButtonSegment(value: 0, label: Text('Auto')),
                    ButtonSegment(value: 1, label: Text('Landscape')),
                    ButtonSegment(value: 2, label: Text('Portrait')),
                  ]
                : const [
                    ButtonSegment(value: 0, label: Text('Auto'), icon: Icon(Icons.screen_rotation)),
                    ButtonSegment(value: 1, label: Text('Landscape'), icon: Icon(Icons.stay_current_landscape)),
                    ButtonSegment(value: 2, label: Text('Portrait'), icon: Icon(Icons.stay_current_portrait)),
                  ],
            selected: {widget.dj.screenOrientation},
            showSelectedIcon: false,
            onSelectionChanged: (s) async {
              await widget.dj.setScreenOrientation(s.first);
              if (mounted) setState(() {});
            },
          ),
          const Divider(height: 32),
          const Text(
            'Deck buttons',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Hot cue pads (A–D)'),
            subtitle: Text(
              'The four hot cue buttons on each deck. Off gives the row more room; '
              'cues already set still show on the waveforms.',
              style: TextStyle(color: SideDeckTheme.muted, fontSize: 12, height: 1.4),
            ),
            value: widget.dj.showHotCues,
            onChanged: (v) async {
              await widget.dj.setShowHotCues(v);
              if (mounted) setState(() {});
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('GRID button'),
            subtitle: Text(
              'The beat grid fix tools (beat here, bar here, BPM, tap, undo). For '
              'preparing tracks before a set; off keeps the deck row clear.',
              style: TextStyle(color: SideDeckTheme.muted, fontSize: 12, height: 1.4),
            ),
            value: widget.dj.showGridButton,
            onChanged: (v) async {
              await widget.dj.setShowGridButton(v);
              if (mounted) setState(() {});
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Quantize button (Q)'),
            subtitle: Text(
              'Hidden, quantize stays as it is: '
              '${widget.dj.deckA.quantize && widget.dj.deckB.quantize ? 'on' : 'as last set'} '
              '(cues, hot cues and loops snap to the beat).',
              style: TextStyle(color: SideDeckTheme.muted, fontSize: 12, height: 1.4),
            ),
            value: widget.dj.showQuantizeButton,
            onChanged: (v) async {
              await widget.dj.setShowQuantizeButton(v);
              if (mounted) setState(() {});
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Auto cue'),
            subtitle: Text(
              'On load, the cue sits on the first beat where the music starts, '
              'skipping any silence, as on a CDJ. A cue you set yourself is kept instead.',
              style: TextStyle(color: SideDeckTheme.muted, fontSize: 12, height: 1.4),
            ),
            value: widget.dj.autoCue,
            onChanged: (v) async {
              await widget.dj.setAutoCue(v);
              if (mounted) setState(() {});
            },
          ),
          const Divider(height: 32),
          const Text(
            'Waveform',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Full waveform'),
            subtitle: Text(
              'Both decks\' scrolling waveforms drawn full, mirrored round their middle. '
              'Off: half waveforms, deck A rising and deck B hanging from the centre line.',
              style: TextStyle(color: SideDeckTheme.muted, fontSize: 12, height: 1.4),
            ),
            value: widget.dj.fullWaveform,
            onChanged: (v) async {
              await widget.dj.setFullWaveform(v);
              if (mounted) setState(() {});
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Track sections'),
            subtitle: Text(
              'INTRO, BREAK, DROP and OUTRO marked on the waveforms, found from where '
              'the bass drops out and comes back. The bar counter counts down to the '
              'next one. Follows the beat grid, so fix the grid first if they look off.',
              style: TextStyle(color: SideDeckTheme.muted, fontSize: 12, height: 1.4),
            ),
            value: widget.dj.showSections,
            onChanged: (v) async {
              await widget.dj.setShowSections(v);
              if (mounted) setState(() {});
            },
          ),
          const Divider(height: 32),
          const Text(
            'Tempo',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Key lock'),
            subtitle: Text(
              'Keeps the pitch when the tempo changes. Off: pitch follows tempo like '
              'a turntable. Both decks; the KEY button on the tempo fader sets one.',
              style: TextStyle(color: SideDeckTheme.muted, fontSize: 12, height: 1.4),
            ),
            value: widget.dj.keylockAll,
            onChanged: (v) async {
              await widget.dj.setKeylockAll(v);
              if (mounted) setState(() {});
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Tempo fader on the deck rails'),
            subtitle: Text(
              'A fader per deck (double-tap to reset) with KEY above it and its range '
              'below (±8 / ±16 / ±50 %). Off saves room; − / + and SYNC still set tempo.',
              style: TextStyle(color: SideDeckTheme.muted, fontSize: 12, height: 1.4),
            ),
            value: widget.dj.showTempoFader,
            onChanged: (v) async {
              await widget.dj.setShowTempoFader(v);
              if (mounted) setState(() {});
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Pull the fader down to speed up'),
            subtitle: Text(
              'As on a CDJ. Off: push it up to speed up.',
              style: TextStyle(color: SideDeckTheme.muted, fontSize: 12, height: 1.4),
            ),
            value: widget.dj.tempoDownFaster,
            onChanged: (v) async {
              await widget.dj.setTempoDownFaster(v);
              if (mounted) setState(() {});
            },
          ),
          const Divider(height: 32),
          const Text(
            'Key display',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 8),
          Text(
            'How track keys appear on the decks and in the library.',
            style: TextStyle(color: SideDeckTheme.muted, fontSize: 12, height: 1.4),
          ),
          const SizedBox(height: 8),
          SegmentedButton<KeyNotation>(
            segments: const [
              ButtonSegment(value: KeyNotation.camelot, label: Text('Camelot · 10A')),
              ButtonSegment(value: KeyNotation.musical, label: Text('Musical · Bm')),
              ButtonSegment(value: KeyNotation.both, label: Text('Both · Bm / 10A')),
            ],
            selected: {widget.dj.keyNotation},
            showSelectedIcon: false,
            onSelectionChanged: (s) async {
              await widget.dj.setKeyNotation(s.first);
              if (mounted) setState(() {});
            },
          ),
          const Divider(height: 32),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Auto gain'),
            subtitle: Text(
              'Levels every track to the same loudness '
              '(${DjController.autoGainTargetDb.toStringAsFixed(0)} dBFS for the loud parts, '
              'never pushing the peak to clipping), so a mix doesn\'t jump between '
              'quiet and hot masters. The applied gain shows on each deck.',
              style: TextStyle(color: SideDeckTheme.muted, fontSize: 12, height: 1.4),
            ),
            value: widget.dj.autoGain,
            onChanged: (v) async {
              await widget.dj.setAutoGain(v);
              if (mounted) setState(() {});
            },
          ),
          const Divider(height: 32),
          const Text(
            'Subsonic server',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 8),
          Text(
            'Optional. Tracks download to a local cache, then play like local files. '
            'Use http:// for a server on your LAN. Use https:// if the server is '
            'on the internet — otherwise the login token travels in the clear.',
            style: TextStyle(color: SideDeckTheme.muted, fontSize: 12, height: 1.4),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _url,
            decoration: const InputDecoration(
              labelText: 'Server URL',
              hintText: 'http://192.168.1.10:4533',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _user,
            decoration: const InputDecoration(
              labelText: 'Username',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _pass,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Password',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _busy ? null : _saveAndTest,
            child: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Save & ping'),
          ),
          if (_status != null) ...[
            const SizedBox(height: 8),
            Text(_status!),
          ],
          const Divider(height: 32),
          const Text(
            'About',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 8),
          Text(
            'SideDeck 1.1.0\n'
            'Copyright © 2026 SideDeck contributors\n\n'
            'This program is free software under the GNU GPL v3 or later. '
            'There is no warranty.\n\n'
            'Support & issues: github.com/manueljpy/SideDeck',
            style: TextStyle(color: SideDeckTheme.muted, fontSize: 12, height: 1.4),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: () {
              showLicensePage(
                context: context,
                applicationName: 'SideDeck',
                applicationVersion: '1.1.0',
                applicationLegalese:
                    'Copyright © 2026 SideDeck contributors\n\n'
                    'GNU GPL v3 or later. See LICENSE and NOTICE in the '
                    'source repository.',
              );
            },
            child: const Text('Open-source licenses'),
          ),
        ],
      ),
    );
  }
}
