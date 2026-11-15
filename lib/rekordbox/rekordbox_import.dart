import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sidedeck/engine/cue_store.dart';
import 'package:sidedeck/engine/music_utils.dart';
import 'package:sidedeck/engine/native_engine.dart';
import 'package:sidedeck/rekordbox/anlz_reader.dart';
import 'package:sidedeck/rekordbox/pdb_reader.dart';
import 'package:sidedeck/rekordbox/rekordbox_store.dart';

/// Android's Storage Access Framework, for the stick's non-media files.
class StickChannel {
  static const _ch = MethodChannel('sidedeck/stick');

  /// Lets the user pick the stick's root; null when cancelled.
  static Future<({String tree, String basePath})?> pick() async {
    final r = await _ch.invokeMethod<dynamic>('pick');
    if (r is! Map) return null;
    return (tree: '${r['tree']}', basePath: '${r['basePath'] ?? ''}');
  }

  static Future<Uint8List?> read(String tree, String relPath) =>
      _ch.invokeMethod<Uint8List>('read', {'tree': tree, 'path': relPath});

  static Future<bool> copy(String tree, String relPath, String dest) async =>
      await _ch.invokeMethod<bool>('copy', {'tree': tree, 'path': relPath, 'dest': dest}) ?? false;
}

class ImportResult {
  const ImportResult({
    required this.tracks,
    required this.playlists,
    required this.withGrid,
    required this.variableGrids,
    required this.withCues,
  });

  final int tracks;
  final int playlists;
  final int withGrid;
  final int variableGrids;
  final int withCues;
}

class ImportException implements Exception {
  ImportException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Imports a rekordbox-prepared USB stick: its tracks, playlists, beat grids
/// and cues. Phase 1 maps rekordbox's beat-by-beat grid onto SideDeck's
/// constant one (BPM + downbeat offset); grids that change tempo or restart
/// their bar count keep their opening section and are flagged "check grid".
class RekordboxImporter {
  /// Picks a stick and imports it; null when the user cancels.
  static Future<ImportResult?> pickAndImport() async {
    final picked = await StickChannel.pick();
    if (picked == null) return null;
    return import(picked.tree, picked.basePath);
  }

  static Future<ImportResult> import(String tree, String basePath) async {
    String? root;
    Uint8List? pdbBytes;
    for (final candidate in const ['PIONEER', '.PIONEER']) {
      pdbBytes = await StickChannel.read(tree, '$candidate/rekordbox/export.pdb');
      if (pdbBytes != null) {
        root = candidate;
        break;
      }
    }
    if (pdbBytes == null || root == null) {
      final inside = await StickChannel.read(tree, 'rekordbox/export.pdb');
      throw ImportException(
        inside != null
            ? 'That is the PIONEER folder. Pick the stick itself (the folder holding PIONEER and Contents).'
            : 'No rekordbox library here. Pick the root of a stick exported from rekordbox.',
      );
    }
    final lib = PdbReader(pdbBytes).read();

    String pathOf(String rel) {
      final r = rel.startsWith('/') ? rel : '/$rel';
      return basePath.isNotEmpty ? '$basePath$r' : 'stick:$r';
    }

    final tracks = <StickTrack>[];
    final byId = <int, String>{};
    var withGrid = 0, variable = 0, withCues = 0;
    for (final t in lib.tracks) {
      if (t.filePath.isEmpty) continue;
      final path = pathOf(t.filePath);
      byId[t.id] = path;

      AnlzFile? dat, ext;
      if (t.analyzePath.isNotEmpty) {
        final datPath = t.analyzePath.replaceFirst(RegExp(r'^/'), '');
        final datBytes = await StickChannel.read(tree, datPath);
        if (datBytes != null) dat = AnlzReader(datBytes).read();
        final extBytes = await StickChannel.read(tree, datPath.replaceFirst(RegExp(r'\.DAT$', caseSensitive: false), '.EXT'));
        if (extBytes != null) ext = AnlzReader(extBytes).read();
      }

      final grid = gridFromBeats(dat?.beats ?? ext?.beats ?? const []);
      if (grid != null) {
        withGrid++;
        if (!grid.constant) variable++;
      }
      final cues = (ext != null && ext.extendedCues) ? ext.cues : [...?dat?.cues, ...?ext?.cues];
      if (await _importCues(path, cues)) withCues++;

      tracks.add(StickTrack(
        path: path,
        relPath: t.filePath,
        title: t.title.isNotEmpty ? t.title : p.basenameWithoutExtension(t.filePath),
        artist: lib.artists[t.artistId] ?? '',
        album: lib.albums[t.albumId] ?? '',
        durationSec: t.durationSec,
        bpm: grid?.bpm ?? t.tempo,
        key: keyFromName(lib.keys[t.keyId] ?? ''),
        beatOffset: grid?.beatOffset ?? 0,
        // Constant rekordbox grids are trusted; a grid that moves is shown
        // with "check grid" until variable grids are supported.
        gridConfidence: grid == null ? -1 : (grid.constant ? 1 : 0),
      ));
    }

    final playlists = [
      for (final pl in lib.playlists)
        StickPlaylist(
          id: pl.id,
          parentId: pl.parentId,
          name: pl.name,
          isFolder: pl.isFolder,
          sortOrder: pl.sortOrder,
          trackPaths: [
            for (final id in lib.playlistTracks[pl.id] ?? const <int>[])
              if (byId[id] != null) byId[id]!,
          ],
        ),
    ];
    await RekordboxStore.instance.replace(
      tree: tree,
      basePath: basePath,
      tracks: tracks,
      playlists: playlists,
    );
    return ImportResult(
      tracks: tracks.length,
      playlists: playlists.where((pl) => !pl.isFolder).length,
      withGrid: withGrid,
      variableGrids: variable,
      withCues: withCues,
    );
  }

  /// Cues from rekordbox, unless the track already has cues set in SideDeck.
  /// The earliest memory cue becomes the main cue (a CDJ loads to it); hot
  /// cues A-D fill SideDeck's four pads. Hot loops keep their start for now.
  static Future<bool> _importCues(String path, List<AnlzCue> cues) async {
    if (cues.isEmpty) return false;
    final existing = await CueStore.instance.get(path);
    if (existing != null) return false;
    final memory = cues.where((c) => c.hotCue == 0).map((c) => c.timeSec).toList()..sort();
    final hot = List<double>.filled(NativeEngine.hotCueCount, -1);
    for (final c in cues) {
      if (c.hotCue >= 1 && c.hotCue <= hot.length) hot[c.hotCue - 1] = c.timeSec;
    }
    if (memory.isEmpty && hot.every((t) => t < 0)) return false;
    await CueStore.instance.put(
      path,
      TrackCues(cue: memory.isNotEmpty ? memory.first : 0, hotCues: hot),
    );
    return true;
  }

  /// The file a deck should open for [t]: the stick's own copy when Android
  /// lets the app open it by path, else a copy in the app cache.
  static Future<String?> playablePath(StickTrack t) async {
    if (!t.path.startsWith('stick:') && await File(t.path).exists()) return t.path;
    final stick = await RekordboxStore.instance.stick();
    if (stick == null) return null;
    final cache = await getTemporaryDirectory();
    final ext = p.extension(t.relPath);
    final dest = p.join(cache.path, 'stick', '${t.relPath.hashCode.toUnsigned(32)}$ext');
    if (await File(dest).exists()) return dest;
    final ok = await StickChannel.copy(stick.tree, t.relPath.replaceFirst(RegExp(r'^/'), ''), dest);
    return ok ? dest : null;
  }
}

/// SideDeck's constant grid from rekordbox's beat list.
class ImportedGrid {
  const ImportedGrid(this.bpm, this.beatOffset, {required this.constant});
  final double bpm;

  /// A downbeat (bar 1, beat 1) at or after the track start, in seconds.
  final double beatOffset;

  /// Whether one tempo and bar phase fits the whole list.
  final bool constant;
}

/// A least-squares line through rekordbox's beats (times are whole ms, so the
/// fit is more precise than any one beat). If the whole list fits within a
/// couple of ms the grid is constant; otherwise the opening run that does is
/// used and the grid is marked as not constant.
ImportedGrid? gridFromBeats(List<AnlzBeat> beats) {
  if (beats.length < 8) return null;

  (double, double) fit(int n) {
    double sx = 0, sy = 0, sxx = 0, sxy = 0;
    for (var i = 0; i < n; i++) {
      final y = beats[i].timeSec;
      sx += i;
      sy += y;
      sxx += i * i.toDouble();
      sxy += i * y;
    }
    final slope = (n * sxy - sx * sy) / (n * sxx - sx * sx);
    return (slope, (sy - slope * sx) / n);
  }

  bool fits(int n, double period, double at0) {
    for (var i = 0; i < n; i++) {
      if ((beats[i].timeSec - (at0 + i * period)).abs() > 0.003) return false;
    }
    // A bar count that restarts mid-way is a phase change even at one tempo.
    for (var i = 1; i < n; i++) {
      if (beats[i].beatInBar != beats[i - 1].beatInBar % 4 + 1) return false;
    }
    return true;
  }

  var n = beats.length;
  var (period, at0) = fit(n);
  final constant = fits(n, period, at0);
  if (!constant) {
    // Opening run: grow while it still fits.
    n = 8;
    (period, at0) = fit(n);
    while (n < beats.length) {
      final (p2, a2) = fit(n + 1);
      if (!fits(n + 1, p2, a2)) break;
      n++;
      (period, at0) = (p2, a2);
    }
  }
  if (!(period > 0.2 && period < 2.0)) return null;

  var bpm = 60.0 / period;
  // rekordbox stores the tempo to 0.01 BPM; use it when the fit agrees.
  final stated = beats.first.tempo;
  if ((bpm - stated).abs() < 0.01) bpm = stated;
  final beat = 60.0 / bpm;

  final firstDown = beats.indexWhere((b) => b.beatInBar == 1);
  var downbeat = at0 + (firstDown < 0 ? 0 : firstDown) * beat;
  final bar = 4 * beat;
  downbeat -= (downbeat / bar).floorToDouble() * bar;
  return ImportedGrid(bpm, downbeat, constant: constant);
}

/// rekordbox key names ("Am", "F#", "Ebm"), Camelot ("8A") or Open Key ("1m")
/// to SideDeck's index: 0..11 major, 12..23 minor; -1 when unknown.
int keyFromName(String raw) {
  final s = raw.trim();
  final camelot = RegExp(r'^(\d{1,2})\s*([ABab])$').firstMatch(s);
  if (camelot != null) return _fromCamelot(int.parse(camelot[1]!), camelot[2]!.toUpperCase() == 'A');
  final open = RegExp(r'^(\d{1,2})\s*([mMdD])$').firstMatch(s);
  if (open != null) {
    // Open Key n = Camelot n + 7 (1d is C major, Camelot 8B).
    final n = int.parse(open[1]!);
    return _fromCamelot((n + 6) % 12 + 1, open[2]!.toLowerCase() == 'm');
  }
  final m = RegExp(r'^([A-Ga-g])([#♯b♭]?)\s*(m|min|minor)?$').firstMatch(s);
  if (m == null) return -1;
  const natural = {'C': 0, 'D': 2, 'E': 4, 'F': 5, 'G': 7, 'A': 9, 'B': 11};
  var pc = natural[m[1]!.toUpperCase()]!;
  final accidental = m[2] ?? '';
  if (accidental == '#' || accidental == '♯') pc += 1;
  if (accidental == 'b' || accidental == '♭') pc -= 1;
  pc %= 12;
  return m[3] != null ? 12 + pc : pc;
}

int _fromCamelot(int n, bool minor) {
  if (n < 1 || n > 12) return -1;
  final major = camelotMajor.indexOf('${n}B');
  if (major < 0) return -1;
  // Camelot nA is the relative minor of nB, a minor third below.
  return minor ? 12 + (major + 9) % 12 : major;
}
