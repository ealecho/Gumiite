import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:sidedeck/engine/analysis_cache.dart';
import 'package:sidedeck/engine/music_utils.dart';
import 'package:sidedeck/rekordbox/rekordbox_store.dart';
import 'package:sidedeck/state/dj_controller.dart';
import 'package:sidedeck/theme/sidedeck_theme.dart';
import 'package:sidedeck/ui/waveform.dart';

/// Everything SideDeck knows about the track on a deck (tap its title).
Future<void> showTrackInfo(BuildContext context, DjController controller, int deckIndex) {
  return showDialog<void>(
    context: context,
    builder: (_) => _TrackInfoDialog(controller: controller, deckIndex: deckIndex),
  );
}

/// Key in all three notations, e.g. "Am · 8A · 1m".
String keyDetails(int key) {
  if (key < 0 || key > 23) return '—';
  final minor = key >= 12;
  final root = key % 12;
  final musical = '${keyNames[root]}${minor ? 'm' : ''}';
  final camelot = minor ? camelotMinor(root) : camelotMajor[root];
  // Open Key runs seven steps from Camelot: 8B (C major) is 1d.
  final n = int.parse(camelot.substring(0, camelot.length - 1));
  final open = '${(n + 4) % 12 + 1}${minor ? 'm' : 'd'}';
  return '$musical · $camelot · $open';
}

class _Facts {
  _Facts({this.album, this.source, this.sizeBytes, this.handFixed = false, this.imported = false});
  final String? album;
  final String? source;
  final int? sizeBytes;
  final bool handFixed;
  final bool imported;
}

class _TrackInfoDialog extends StatefulWidget {
  const _TrackInfoDialog({required this.controller, required this.deckIndex});

  final DjController controller;
  final int deckIndex;

  @override
  State<_TrackInfoDialog> createState() => _TrackInfoDialogState();
}

class _TrackInfoDialogState extends State<_TrackInfoDialog> {
  _Facts _facts = _Facts();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChange);
    _load();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  /// Facts that need a file or database look-up.
  Future<void> _load() async {
    final d = widget.controller.deck(widget.deckIndex);
    final path = d.path;
    if (path == null) return;
    StickTrack? stick;
    int? size;
    var handFixed = false;
    try {
      stick = await RekordboxStore.instance.track(path);
    } catch (_) {}
    try {
      size = (await File(d.openPath ?? path).stat()).size;
      if (size <= 0) size = null;
    } catch (_) {}
    try {
      handFixed = (await AnalysisCache.instance.userEditedPaths()).contains(path);
    } catch (_) {}
    final String source;
    if (stick != null) {
      source = 'rekordbox USB stick';
    } else if (path.contains('sidedeck_cache')) {
      source = 'Subsonic server (cached copy)';
    } else {
      source = 'Local file';
    }
    if (!mounted) return;
    setState(() {
      _facts = _Facts(
        album: (stick?.album.isNotEmpty ?? false) ? stick!.album : null,
        source: source,
        sizeBytes: size,
        handFixed: handFixed,
        imported: stick != null,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final d = c.deck(widget.deckIndex);
    final deckName = widget.deckIndex == 0 ? 'A' : 'B';
    final tag = widget.deckIndex == 0 ? SideDeckTheme.accentA : SideDeckTheme.accentB;
    final path = d.path ?? '';

    String time(double s) => formatDuration(s);
    String bpm(double v) => v > 1 ? v.toStringAsFixed(2) : '—';
    final pct = (d.rate - 1) * 100;
    String signed(double v, String unit) =>
        '${v > 0 ? '+' : v < 0 ? '−' : ''}${v.abs().toStringAsFixed(v.abs() >= 10 ? 1 : 2)}$unit';

    final String gridState;
    if (_facts.handFixed) {
      gridState = 'Fixed by hand';
    } else if (d.gridUnsure) {
      gridState = 'Check grid (it doesn\'t hold through the track)';
    } else if (_facts.imported) {
      gridState = 'From rekordbox';
    } else if (d.gridConfidence >= 0) {
      gridState = 'Analysed, holds through the track';
    } else {
      gridState = 'Analysed';
    }

    final cues = <String>[
      'CUE ${time(d.cuePoint)}',
      for (var i = 0; i < d.hotCues.length; i++)
        if (d.hotCues[i] >= 0) '${WaveformPainter.hotCueLabel(i)} ${time(d.hotCues[i])}',
    ];

    final level = d.loudnessDb > -99
        ? '${d.loudnessDb.toStringAsFixed(1)} dBFS loud parts · peak ${d.peakDb.toStringAsFixed(1)} dBFS'
        : '—';
    final autoGain = !c.autoGain
        ? 'Off'
        : (d.loudnessDb > -99 ? signed(d.autoGainDb, ' dB') : '—');

    final rows = <(String, String)>[
      if (d.artist.isNotEmpty) ('Artist', d.artist),
      if (_facts.album != null) ('Album', _facts.album!),
      ('Length', '${time(d.duration)} · at ${time(d.position)}'),
      ('BPM', d.rate == 1 ? bpm(d.bpm) : '${bpm(d.bpm * d.rate)} playing · ${bpm(d.bpm)} original'),
      ('Tempo', '${signed(pct, ' %')}${d.synced ? ' · synced' : ''}'),
      ('Key', keyDetails(d.key)),
      ('Beat grid', '${bpm(d.bpm)} BPM, first downbeat ${d.beatOffset.toStringAsFixed(3)} s'),
      ('Grid', gridState),
      ('Cues', cues.join('   ')),
      ('Level', level),
      ('Auto gain', autoGain),
      ('Format', p.extension(path).replaceFirst('.', '').toUpperCase().ifEmpty('—')),
      if (_facts.sizeBytes != null) ('Size', '${(_facts.sizeBytes! / (1024 * 1024)).toStringAsFixed(1)} MB'),
      ('Source', _facts.source ?? '…'),
      ('File', path.startsWith('stick:') ? path.substring(6) : path),
    ];

    return Dialog(
      backgroundColor: SideDeckTheme.deckRow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 48, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 18,
                    height: 14,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: tag, borderRadius: BorderRadius.circular(2)),
                    child: Text(
                      deckName,
                      style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Colors.black, height: 1),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SelectableText(
                      d.loaded ? d.title : 'No track loaded',
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: SideDeckTheme.deckText),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close, size: 20),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (d.loaded)
                Flexible(
                  child: SingleChildScrollView(
                    child: Table(
                      columnWidths: const {0: IntrinsicColumnWidth(), 1: FlexColumnWidth()},
                      defaultVerticalAlignment: TableCellVerticalAlignment.top,
                      children: [
                        for (final (label, value) in rows)
                          TableRow(
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(right: 16, bottom: 6),
                                child: Text(
                                  label.toUpperCase(),
                                  style: const TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 0.8,
                                    color: SideDeckTheme.deckDim,
                                    height: 1.6,
                                  ),
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: SelectableText(
                                  value,
                                  style: const TextStyle(fontSize: 13, color: SideDeckTheme.deckText),
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}
