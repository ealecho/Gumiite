import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:sidedeck/engine/analysis_cache.dart';
import 'package:sidedeck/engine/history_store.dart';
import 'package:sidedeck/engine/music_utils.dart';
import 'package:sidedeck/engine/track_analyzer.dart';
import 'package:sidedeck/rekordbox/rekordbox_import.dart';
import 'package:sidedeck/rekordbox/rekordbox_store.dart';
import 'package:sidedeck/state/dj_controller.dart';
import 'package:sidedeck/state/library_controller.dart';
import 'package:sidedeck/subsonic/subsonic_client.dart';
import 'package:sidedeck/theme/sidedeck_theme.dart';
import 'package:sidedeck/ui/deck_panel.dart' show GridWarningBadge;

/// Modal library overlay (opened from the Library button).
class LibraryOverlay extends StatefulWidget {
  const LibraryOverlay({
    super.key,
    required this.dj,
    required this.library,
    this.onOpenSettings,
  });

  final DjController dj;
  final LibraryController library;
  final VoidCallback? onOpenSettings;

  @override
  State<LibraryOverlay> createState() => _LibraryOverlayState();
}

class _LibraryOverlayState extends State<LibraryOverlay> {
  SubsonicClient? _client;
  List<SubsonicTrack> _remote = [];
  List<SubsonicPlaylist> _playlists = [];
  SubsonicPlaylist? _openPlaylist;
  bool _searching = false;
  bool _remoteLoading = false;
  String? _remoteError;
  String? _remoteBusyId;
  String? _remoteBusyLabel;
  final Map<String, TrackAnalysis> _remoteMeta = {};
  final _cache = AnalysisCache.instance;
  final _search = TextEditingController();
  int _tab = 0;

  // USB tab: the last imported rekordbox stick.
  List<StickTrack> _stick = const [];
  List<StickPlaylist> _stickLists = const [];
  int? _stickPlaylist; // null: all tracks
  String? _stickStatus;
  bool _stickBusy = false;

  @override
  void initState() {
    super.initState();
    // The library keeps its filter across openings of this sheet; show it, or
    // an empty box would sit over a filtered list that clearing can't reset.
    _search.text = widget.library.query;
    _loadClient();
    _loadStick();
    widget.library.addListener(_onLib);
    widget.dj.addListener(_onLib);
  }

  void _onLib() {
    if (mounted) setState(() {});
  }

  Future<void> _loadClient() async {
    _client = await SubsonicClient.fromPrefs();
    if (!mounted) return;
    setState(() {});
    if (_client != null) await _loadPlaylists();
  }

  @override
  void dispose() {
    widget.library.removeListener(_onLib);
    widget.dj.removeListener(_onLib);
    _search.dispose();
    super.dispose();
  }

  Future<void> _hydrateRemoteMeta(List<SubsonicTrack> tracks) async {
    for (final t in tracks) {
      final path = await _client?.cachedPathIfPresent(t);
      if (path == null) continue;
      try {
        final stat = await File(path).stat();
        final cached = await _cache.get(
          path,
          stat.size,
          stat.modified.millisecondsSinceEpoch,
        );
        if (cached != null) {
          _remoteMeta[t.id] = cached;
        }
      } catch (_) {}
    }
  }

  Future<void> _loadPlaylists() async {
    if (_client == null) return;
    setState(() {
      _remoteLoading = true;
      _remoteError = null;
      _searching = false;
      _openPlaylist = null;
      _remote = [];
    });
    try {
      final lists = await _client!.playlists();
      lists.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      if (!mounted) return;
      setState(() => _playlists = lists);
    } catch (e) {
      if (!mounted) return;
      setState(() => _remoteError = e.toString());
    } finally {
      if (mounted) setState(() => _remoteLoading = false);
    }
  }

  Future<void> _openRemotePlaylist(SubsonicPlaylist playlist) async {
    if (_client == null) return;
    setState(() {
      _remoteLoading = true;
      _remoteError = null;
      _searching = false;
      _openPlaylist = playlist;
      _remote = [];
    });
    try {
      final tracks = await _client!.playlistTracks(playlist.id);
      await _hydrateRemoteMeta(tracks);
      if (!mounted) return;
      setState(() => _remote = tracks);
    } catch (e) {
      if (!mounted) return;
      setState(() => _remoteError = e.toString());
    } finally {
      if (mounted) setState(() => _remoteLoading = false);
    }
  }

  void _onSearchChanged(String v) {
    if (_tab == 0) widget.library.setQuery(v);
    // The USB and History lists filter on the box directly.
    if (_tab == 2 || _tab == 3) setState(() {});
    if (_tab == 1 && v.trim().isEmpty && _searching) {
      _loadPlaylists();
    }
  }

  Future<void> _searchRemote(String q) async {
    if (_client == null) return;
    final query = q.trim();
    if (query.isEmpty) {
      await _loadPlaylists();
      return;
    }
    setState(() {
      _remoteLoading = true;
      _remoteError = null;
      _searching = true;
      _openPlaylist = null;
    });
    try {
      final tracks = await _client!.search(query);
      await _hydrateRemoteMeta(tracks);
      if (!mounted) return;
      setState(() => _remote = tracks);
    } catch (e) {
      if (!mounted) return;
      setState(() => _remoteError = e.toString());
    } finally {
      if (mounted) setState(() => _remoteLoading = false);
    }
  }

  Future<void> _loadRemote(SubsonicTrack track, int deck) async {
    if (_client == null) return;
    setState(() {
      _remoteBusyId = track.id;
      _remoteBusyLabel = 'Downloading…';
    });
    try {
      final path = await _client!.cacheTrack(track);
      if (mounted) {
        setState(() => _remoteBusyLabel = 'Loading…');
      }
      final ok = await widget.dj.loadFile(
        deck,
        path,
        title: track.title,
        artist: track.artist,
      );
      if (ok) {
        widget.library.upsertAnalysis(
          path,
          bpm: widget.dj.deck(deck).bpm,
          key: widget.dj.deck(deck).key,
        );
        _remoteMeta[track.id] = TrackAnalysis(
          bpm: widget.dj.deck(deck).bpm,
          key: widget.dj.deck(deck).key,
          beatOffset: widget.dj.deck(deck).beatOffset,
        );
        if (mounted) Navigator.pop(context);
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(widget.dj.engineError ?? 'Load failed')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Load failed: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _remoteBusyId = null;
          _remoteBusyLabel = null;
        });
      }
    }
  }

  Future<void> _analyzeRemote(SubsonicTrack track) async {
    if (_client == null || _remoteBusyId != null) return;
    setState(() {
      _remoteBusyId = track.id;
      _remoteBusyLabel = 'Downloading…';
    });
    try {
      final path = await _client!.cacheTrack(track);
      if (mounted) setState(() => _remoteBusyLabel = 'Analyzing…');
      final result = await analyzeTrackFileOffUi(path);
      if (result == null) {
        throw Exception('Analyze failed');
      }
      try {
        final stat = await File(path).stat();
        await _cache.put(
          path: path,
          size: stat.size,
          mtime: stat.modified.millisecondsSinceEpoch,
          bpm: result.bpm,
          key: result.key,
          beatOffset: result.beatOffset,
          gridConfidence: result.gridConfidence,
        );
      } catch (_) {}
      if (!mounted) return;
      setState(() => _remoteMeta[track.id] = result);
      await widget.dj.reloadIfLoaded(
        path,
        title: track.title,
        artist: track.artist,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Analyze failed: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _remoteBusyId = null;
          _remoteBusyLabel = null;
        });
      }
    }
  }

  Future<void> _analyzeLocal(LibraryTrack t) async {
    final analyzed = await widget.library.analyzePath(t.path);
    await _reloadAnalyzedDecks(analyzed);
  }

  Future<void> _reloadAnalyzedDecks(List<String> paths) async {
    for (final path in paths) {
      await widget.dj.reloadIfLoaded(path);
    }
  }

  Future<void> _loadStick() async {
    final tracks = await RekordboxStore.instance.tracks();
    final lists = await RekordboxStore.instance.playlists();
    if (!mounted) return;
    setState(() {
      _stick = tracks;
      _stickLists = lists;
      if (_stickPlaylist != null && !lists.any((l) => l.id == _stickPlaylist)) _stickPlaylist = null;
    });
  }

  Future<void> _importStick() async {
    setState(() {
      _stickBusy = true;
      _stickStatus = 'Reading USB…';
    });
    try {
      final r = await RekordboxImporter.pickAndImport();
      if (r != null) {
        await _loadStick();
        _stickStatus = 'Imported ${r.tracks} tracks, ${r.playlists} playlists · '
            '${r.withGrid} grids${r.variableGrids > 0 ? ' (${r.variableGrids} with tempo changes: check grid)' : ''} · '
            '${r.withCues} with cues';
      } else {
        _stickStatus = null;
      }
    } catch (e) {
      _stickStatus = 'Import failed: $e';
    } finally {
      if (mounted) setState(() => _stickBusy = false);
    }
  }

  Future<void> _loadStickTrack(StickTrack t, int deck) async {
    setState(() => _stickStatus = 'Opening from USB…');
    final open = await RekordboxImporter.playablePath(t);
    if (!mounted) return;
    if (open == null) {
      setState(() => _stickStatus = "Can't open ${t.title} from the stick. Is it plugged in?");
      return;
    }
    setState(() => _stickStatus = null);
    final ok = await widget.dj.loadFile(
      deck,
      t.path,
      title: t.title,
      artist: t.artist,
      openPath: open == t.path ? null : open,
    );
    if (ok && mounted) Navigator.pop(context);
  }

  /// Playlists for the picker, folders shown as path prefixes.
  List<(int, String)> _stickPlaylistNames() {
    final byId = {for (final l in _stickLists) l.id: l};
    String name(StickPlaylist l) {
      final parent = byId[l.parentId];
      return parent == null ? l.name : '${name(parent)} / ${l.name}';
    }

    final lists = _stickLists.where((l) => !l.isFolder).toList()
      ..sort((a, b) => name(a).toLowerCase().compareTo(name(b).toLowerCase()));
    return [for (final l in lists) (l.id, name(l))];
  }

  Widget _stickList() {
    if (_stick.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Plug in a USB stick exported from rekordbox (through a USB-C hub),\n'
            'tap the USB icon and pick the stick. Its tracks, playlists, beat grids\n'
            'and cues come in; the grids and cues you set in rekordbox are kept.',
            textAlign: TextAlign.center,
            style: TextStyle(color: SideDeckTheme.muted),
          ),
        ),
      );
    }
    var tracks = _stick;
    final playlist = _stickPlaylist;
    if (playlist != null) {
      final byPath = {for (final t in _stick) t.path: t};
      final order = _stickLists.firstWhere((l) => l.id == playlist).trackPaths;
      tracks = [for (final path in order) ?byPath[path]];
    }
    final q = _search.text.trim().toLowerCase();
    if (q.isNotEmpty) {
      tracks = tracks
          .where((t) => t.title.toLowerCase().contains(q) || t.artist.toLowerCase().contains(q))
          .toList();
    }
    // A playlist keeps its own order; "all tracks" follows the sort menu.
    if (playlist == null) {
      tracks = _sorted(tracks, (t) => (title: t.title, artist: t.artist, bpm: t.bpm, key: t.key));
    }
    final busy = widget.dj.loadingDeck != null || _stickBusy;
    return ListView.builder(
      itemCount: tracks.length,
      itemBuilder: (context, i) {
        final t = tracks[i];
        final loadingThis = widget.dj.loadingPath == t.path;
        return _songRow(
          busyThis: false,
          analyzeTooltip: 'Grid and cues from rekordbox',
          onAnalyze: null,
          title: t.title,
          artist: t.artist,
          bpm: t.bpm > 0 ? t.bpm : null,
          key: t.key >= 0 ? t.key : null,
          gridUnsure: t.gridConfidence >= 0 && t.gridConfidence < TrackAnalysis.unsureBelow,
          played: widget.dj.playedPaths.contains(t.path),
          durationSec: t.durationSec.toDouble(),
          actions: [
            _deckBtn('A', busy ? null : () => _loadStickTrack(t, 0), loadingThis && widget.dj.loadingDeck == 0),
            const SizedBox(width: 8),
            _deckBtn('B', busy ? null : () => _loadStickTrack(t, 1), loadingThis && widget.dj.loadingDeck == 1),
          ],
        );
      },
    );
  }

  Future<void> _loadLocal(LibraryTrack t, int deck) async {
    final ok = await widget.dj.loadFile(
      deck,
      t.path,
      title: t.title,
      artist: t.artist,
    );
    if (ok) {
      widget.library.upsertAnalysis(
        t.path,
        bpm: widget.dj.deck(deck).bpm,
        key: widget.dj.deck(deck).key,
      );
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tracks = _sorted(
      widget.library.filtered,
      (t) => (title: t.title, artist: t.artist, bpm: t.bpm, key: t.key),
    );
    final lib = widget.library;

    return Material(
      color: SideDeckTheme.panel,
      child: SafeArea(
        left: false,
        right: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
              child: Row(
                children: [
                  _tabBtn('Local', 0),
                  _tabBtn('Remote', 1),
                  _tabBtn('USB', 2),
                  _tabBtn('History', 3),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SizedBox(
                      height: 36,
                      child: TextField(
                        controller: _search,
                        style: const TextStyle(fontSize: 13),
                        decoration: InputDecoration(
                          hintText: _tab == 1 ? 'Search server, or browse playlists' : 'Filter…',
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                          prefixIcon: const Icon(Icons.search, size: 18),
                          prefixIconConstraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                          suffixIcon: ValueListenableBuilder<TextEditingValue>(
                            valueListenable: _search,
                            builder: (context, value, _) => value.text.isEmpty
                                ? const SizedBox.shrink()
                                : IconButton(
                                    tooltip: 'Clear',
                                    icon: const Icon(Icons.close, size: 16),
                                    padding: EdgeInsets.zero,
                                    onPressed: () {
                                      _search.clear();
                                      _onSearchChanged('');
                                    },
                                  ),
                          ),
                          suffixIconConstraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        onChanged: _onSearchChanged,
                        onSubmitted: (v) {
                          if (_tab == 1) _searchRemote(v);
                        },
                      ),
                    ),
                  ),
                  if (_tab == 3)
                    IconButton(
                      tooltip: 'Clear history',
                      visualDensity: VisualDensity.compact,
                      onPressed: widget.dj.history.isEmpty ? null : _confirmClearHistory,
                      icon: const Icon(Icons.delete_sweep_outlined, size: 22),
                    )
                  else
                  PopupMenuButton<TrackSort>(
                    tooltip: 'Sort',
                    padding: EdgeInsets.zero,
                    icon: const Icon(Icons.sort, size: 22),
                    onSelected: widget.library.setSort,
                    itemBuilder: (context) => [
                      _sortItem(TrackSort.name, 'Name'),
                      _sortItem(TrackSort.bpm, 'BPM'),
                      _sortItem(TrackSort.key, 'Key'),
                    ],
                  ),
                  if (_tab == 2) ...[
                    PopupMenuButton<int>(
                      tooltip: 'Playlist',
                      enabled: _stickLists.isNotEmpty,
                      padding: EdgeInsets.zero,
                      icon: Icon(
                        Icons.queue_music,
                        size: 22,
                        color: _stickPlaylist != null ? SideDeckTheme.deckLit : null,
                      ),
                      onSelected: (id) => setState(() => _stickPlaylist = id < 0 ? null : id),
                      itemBuilder: (context) => [
                        CheckedPopupMenuItem(value: -1, checked: _stickPlaylist == null, child: const Text('All tracks')),
                        for (final (id, name) in _stickPlaylistNames())
                          CheckedPopupMenuItem(value: id, checked: _stickPlaylist == id, child: Text(name)),
                      ],
                    ),
                    IconButton(
                      tooltip: 'Import a rekordbox USB',
                      visualDensity: VisualDensity.compact,
                      onPressed: _stickBusy ? null : _importStick,
                      icon: const Icon(Icons.usb, size: 22),
                    ),
                  ],
                  if (_tab == 0) ...[
                    if (lib.analyzing)
                      IconButton(
                        tooltip: 'Stop analysis',
                        visualDensity: VisualDensity.compact,
                        onPressed: lib.cancelAnalyze,
                        icon: const Icon(Icons.stop, size: 22),
                      )
                    else
                      PopupMenuButton<String>(
                        tooltip: 'Analyze BPM / grid',
                        enabled: lib.tracks.isNotEmpty,
                        padding: EdgeInsets.zero,
                        icon: const Icon(Icons.graphic_eq, size: 22),
                        onSelected: (v) async {
                          if (v == 'missing') {
                            await _reloadAnalyzedDecks(await lib.analyzeMissing());
                          } else if (v == 'all') {
                            await _reloadAnalyzedDecks(await lib.analyzeAll());
                          }
                        },
                        itemBuilder: (context) => [
                          PopupMenuItem(
                            value: 'missing',
                            enabled: lib.unanalyzedCount > 0,
                            child: Text(
                              lib.unanalyzedCount > 0
                                  ? 'Analyze missing (${lib.unanalyzedCount})'
                                  : 'Analyze missing',
                            ),
                          ),
                          const PopupMenuItem(
                            value: 'all',
                            child: Text('Re-analyze all'),
                          ),
                        ],
                      ),
                    IconButton(
                      tooltip: 'Pick files',
                      visualDensity: VisualDensity.compact,
                      onPressed: lib.loading || lib.analyzing ? null : lib.pickFiles,
                      icon: const Icon(Icons.audio_file, size: 22),
                    ),
                    IconButton(
                      tooltip: 'Pick folder',
                      visualDensity: VisualDensity.compact,
                      onPressed: lib.loading || lib.analyzing ? null : lib.pickFolder,
                      icon: const Icon(Icons.folder_open, size: 22),
                    ),
                  ],
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close, size: 22),
                  ),
                ],
              ),
            ),
            if (lib.analyzing || widget.dj.loadingDeck != null || lib.error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                child: _statusLine(lib),
              ),
            if (_tab == 1 && _openPlaylist != null) _playlistHeader(),
            if (_tab == 2 && _stickStatus != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                child: Text(_stickStatus!, style: const TextStyle(fontSize: 12, color: SideDeckTheme.muted)),
              ),
            Expanded(
              child: switch (_tab) {
                0 => _localList(tracks),
                1 => _remoteList(),
                2 => _stickList(),
                _ => _historyList(),
              },
            ),
          ],
        ),
      ),
    );
  }

  CheckedPopupMenuItem<TrackSort> _sortItem(TrackSort value, String label) {
    return CheckedPopupMenuItem(
      value: value,
      checked: widget.library.sort == value,
      child: Text(label),
    );
  }

  List<T> _sorted<T>(
    List<T> src,
    ({String title, String artist, double? bpm, int? key}) Function(T) meta,
  ) {
    final list = List<T>.from(src);
    list.sort((a, b) {
      final x = meta(a);
      final y = meta(b);
      return compareTrackSort(
        widget.library.sort,
        x.title,
        x.artist,
        x.bpm,
        x.key,
        y.title,
        y.artist,
        y.bpm,
        y.key,
      );
    });
    return list;
  }

  Widget? _trackArtist(String artist, {String? status}) {
    final line = (status == null || status.isEmpty)
        ? artist
        : (artist.isEmpty ? status : '$artist · $status');
    if (line.isEmpty) return null;
    return Text(
      line,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(color: SideDeckTheme.muted, fontSize: 12),
    );
  }

  Color? _compatibleKeyColor(int? key) {
    if (key == null || key < 0) return null;
    Color? color;
    for (var i = 0; i < 2; i++) {
      final d = widget.dj.deck(i);
      if (!d.loaded || d.key < 0 || !keysCompatible(d.key, key)) continue;
      final accent = i == 0 ? SideDeckTheme.accentA : SideDeckTheme.accentB;
      if (color != null && color != accent) return SideDeckTheme.text;
      color = accent;
    }
    return color;
  }

  Widget _trackMeta(double? bpm, int? key, double durationSec, {bool gridUnsure = false}) {
    final hasBpm = bpm != null && bpm > 0;
    final hasKey = key != null && key >= 0;
    final keyColor = _compatibleKeyColor(key);
    return Padding(
      padding: const EdgeInsets.only(left: 4, right: 2),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (gridUnsure) ...[
                const GridWarningBadge(label: 'CHECK GRID'),
                const SizedBox(width: 4),
              ],
              Text(
                hasBpm ? bpm.toStringAsFixed(1) : '—',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: hasBpm ? SideDeckTheme.text : SideDeckTheme.muted,
                ),
              ),
            ],
          ),
          if (durationSec > 0 || hasKey)
            Text.rich(
              TextSpan(
                style: const TextStyle(color: SideDeckTheme.muted, fontSize: 11),
                children: [
                  if (durationSec > 0) TextSpan(text: formatDuration(durationSec)),
                  if (durationSec > 0 && hasKey) const TextSpan(text: '  '),
                  if (hasKey)
                    TextSpan(
                      text: formatKey(key),
                      style: keyColor == null
                          ? null
                          : TextStyle(color: keyColor, fontWeight: FontWeight.w700),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _tabBtn(String label, int i) {
    final on = _tab == i;
    return Padding(
      padding: const EdgeInsets.only(right: 2),
      child: TextButton(
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 32),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          visualDensity: VisualDensity.compact,
          foregroundColor: on ? Colors.white : SideDeckTheme.muted,
          backgroundColor: on ? SideDeckTheme.panelAlt : Colors.transparent,
        ),
        onPressed: () {
          setState(() => _tab = i);
          // One box serves both tabs; back on Local it must show the filter
          // that is actually applied.
          if (i == 0 && _search.text != widget.library.query) {
            _search.text = widget.library.query;
          }
          if (i == 1 && _client != null && !_searching && _openPlaylist == null && _playlists.isEmpty) {
            _loadPlaylists();
          }
        },
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: on ? FontWeight.w800 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _statusLine(LibraryController lib) {
    if (lib.error != null) {
      return Text(
        lib.error!,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.redAccent, fontSize: 12),
      );
    }
    if (lib.analyzing) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LinearProgressIndicator(
            minHeight: 2,
            value: lib.analyzeTotal == 0 ? null : lib.analyzeDone / lib.analyzeTotal,
          ),
          const SizedBox(height: 2),
          Text(
            'Analyzing ${lib.analyzeDone + 1}/${lib.analyzeTotal}'
            '${lib.analyzingPath == null ? '' : ' — ${p.basename(lib.analyzingPath!)}'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, color: SideDeckTheme.muted),
          ),
        ],
      );
    }
    return Row(
      children: [
        const SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Loading ${widget.dj.loadingTitle ?? 'track'} → '
            '${widget.dj.loadingDeck == 0 ? 'A' : 'B'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, color: SideDeckTheme.muted),
          ),
        ),
      ],
    );
  }

  Widget _songRow({
    required bool busyThis,
    required String analyzeTooltip,
    required VoidCallback? onAnalyze,
    required String title,
    required String artist,
    String? status,
    required double? bpm,
    required int? key,
    required double durationSec,
    required List<Widget> actions,
    bool gridUnsure = false,
    bool played = false,
    Widget? lead,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 4, 8, 4),
      child: Row(
        children: [
          // A lead (the history's number and time) takes the analyze slot.
          if (lead != null)
            lead
          else
          SizedBox(
            width: 32,
            height: 32,
            child: busyThis
                ? const Padding(
                    padding: EdgeInsets.all(6),
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : IconButton(
                    tooltip: analyzeTooltip,
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(width: 32, height: 32),
                    onPressed: onAnalyze,
                    icon: const Icon(Icons.graphic_eq, size: 20),
                  ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Played this session: ticked and dimmed, as in Mixxx.
                Row(
                  children: [
                    if (played) ...[
                      const Tooltip(
                        message: 'Played this session',
                        child: Icon(Icons.check, size: 14, color: SideDeckTheme.muted),
                      ),
                      const SizedBox(width: 4),
                    ],
                    Flexible(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: played ? const TextStyle(color: SideDeckTheme.muted) : null,
                      ),
                    ),
                  ],
                ),
                ?_trackArtist(artist, status: status),
              ],
            ),
          ),
          _trackMeta(bpm, key, durationSec, gridUnsure: gridUnsure),
          const SizedBox(width: 6),
          ...actions,
        ],
      ),
    );
  }

  Widget _localList(List<LibraryTrack> tracks) {
    final lib = widget.library;
    if (lib.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (tracks.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Tap the folder icon, choose your music folder.\n'
            'Then Analyze (waveform icon) for BPM/key, or tap A / B to load.',
            textAlign: TextAlign.center,
            style: TextStyle(color: SideDeckTheme.muted),
          ),
        ),
      );
    }
    return ListView.builder(
      itemCount: tracks.length,
      itemBuilder: (context, i) {
        final t = tracks[i];
        final analyzingThis = lib.analyzingPath == t.path;
        final loadingThis = widget.dj.loadingPath == t.path;
        final busy = lib.analyzing || widget.dj.loadingDeck != null;
        return _songRow(
          busyThis: analyzingThis,
          analyzeTooltip: t.hasAnalysis
              ? 'Re-analyze BPM / grid'
              : 'Analyze BPM / key',
          onAnalyze: busy ? null : () => _analyzeLocal(t),
          title: t.title,
          artist: t.artist,
          bpm: t.bpm,
          key: t.key,
          gridUnsure: t.gridUnsure,
          played: widget.dj.playedPaths.contains(t.path),
          durationSec: t.durationMs / 1000.0,
          actions: [
            _deckBtn('A', busy ? null : () => _loadLocal(t, 0), loadingThis && widget.dj.loadingDeck == 0),
            const SizedBox(width: 8),
            _deckBtn('B', busy ? null : () => _loadLocal(t, 1), loadingThis && widget.dj.loadingDeck == 1),
          ],
        );
      },
    );
  }

  Widget _deckBtn(String label, VoidCallback? onPressed, [bool loading = false]) {
    return FilledButton(
      style: FilledButton.styleFrom(
        minimumSize: const Size(36, 32),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
      ),
      onPressed: onPressed,
      child: loading
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Text(label),
    );
  }

  Widget _playlistHeader() {
    final pl = _openPlaylist!;
    final count = pl.songCount > 0 ? '${pl.songCount}' : '${_remote.length}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 12, 4),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Playlists',
            visualDensity: VisualDensity.compact,
            onPressed: _loadPlaylists,
            icon: const Icon(Icons.arrow_back, size: 20),
          ),
          Expanded(
            child: Text(
              pl.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          Text(
            '$count tracks',
            style: const TextStyle(color: SideDeckTheme.muted, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _playlistList() {
    if (_playlists.isEmpty) {
      return const Center(
        child: Text(
          'No playlists on this server yet.\n'
          'Search and press enter to find tracks.',
          textAlign: TextAlign.center,
          style: TextStyle(color: SideDeckTheme.muted),
        ),
      );
    }
    return ListView.builder(
      itemCount: _playlists.length,
      itemBuilder: (context, i) {
        final pl = _playlists[i];
        final subtitle = [
          if (pl.owner.isNotEmpty) pl.owner,
          if (pl.songCount > 0) '${pl.songCount} tracks',
          if (pl.duration > 0) formatDuration(pl.duration.toDouble()),
        ].join(' · ');
        return ListTile(
          dense: true,
          leading: const Icon(Icons.queue_music, size: 22),
          title: Text(pl.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: subtitle.isEmpty
              ? null
              : Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: SideDeckTheme.muted, fontSize: 12),
                ),
          trailing: const Icon(Icons.chevron_right, size: 20, color: SideDeckTheme.muted),
          onTap: () => _openRemotePlaylist(pl),
        );
      },
    );
  }

  Widget _remoteList() {
    if (_client == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Set up a Subsonic server in Settings first.',
              style: TextStyle(color: SideDeckTheme.muted),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: widget.onOpenSettings,
              child: const Text('Open settings'),
            ),
          ],
        ),
      );
    }
    if (_remoteLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_remoteError != null) {
      return Center(
        child: Text(_remoteError!, style: const TextStyle(color: Colors.redAccent)),
      );
    }
    if (!_searching && _openPlaylist == null) {
      return _playlistList();
    }
    if (_remote.isEmpty) {
      return Center(
        child: Text(
          _searching
              ? 'No matching tracks.\nClear the box to go back to playlists.'
              : 'This playlist is empty.',
          textAlign: TextAlign.center,
          style: const TextStyle(color: SideDeckTheme.muted),
        ),
      );
    }
    final remote = _sorted(
      _remote,
      (t) {
        final m = _remoteMeta[t.id];
        return (title: t.title, artist: t.artist, bpm: m?.bpm, key: m?.key);
      },
    );
    return ListView.builder(
      itemCount: remote.length,
      itemBuilder: (context, i) {
        final t = remote[i];
        final meta = _remoteMeta[t.id];
        final busyThis = _remoteBusyId == t.id;
        final busy = _remoteBusyId != null || widget.dj.loadingDeck != null;
        return _songRow(
          busyThis: busyThis,
          analyzeTooltip: meta == null
              ? 'Download & analyze'
              : 'Re-analyze BPM / grid',
          onAnalyze: busy ? null : () => _analyzeRemote(t),
          title: t.title,
          artist: t.artist,
          status: busyThis ? _remoteBusyLabel : null,
          bpm: meta?.bpm,
          key: meta?.key,
          gridUnsure: meta?.gridUnsure ?? false,
          durationSec: t.duration.toDouble(),
          actions: [
            _deckBtn('A', busy ? null : () => _loadRemote(t, 0)),
            const SizedBox(width: 8),
            _deckBtn('B', busy ? null : () => _loadRemote(t, 1)),
          ],
        );
      },
    );
  }

  Future<void> _confirmClearHistory() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear play history?'),
        content: const Text('Every logged session is removed, and the played marks in the library go too.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Clear')),
        ],
      ),
    );
    if (ok == true) await widget.dj.clearHistory();
  }

  /// Back onto a deck from the history: a stick track opens through the
  /// stick, anything else by its path if the file is still there.
  Future<void> _loadHistoryTrack(PlayedTrack t, int deck) async {
    final stick = await RekordboxStore.instance.track(t.path);
    if (!mounted) return;
    if (stick != null) {
      await _loadStickTrack(stick, deck);
      return;
    }
    if (!await File(t.path).exists()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${t.title} is no longer on the phone.')),
      );
      return;
    }
    final ok = await widget.dj.loadFile(deck, t.path, title: t.title, artist: t.artist);
    if (ok && mounted) Navigator.pop(context);
  }

  static String _clock(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  static String _sessionDay(DateTime start, DateTime now) {
    final day = DateTime(start.year, start.month, start.day);
    final today = DateTime(now.year, now.month, now.day);
    final ago = today.difference(day).inDays;
    if (ago == 0) return 'Today';
    if (ago == 1) return 'Yesterday';
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return '${days[start.weekday - 1]} ${start.day} ${months[start.month - 1]}'
        '${start.year == now.year ? '' : ' ${start.year}'}';
  }

  Widget _historyList() {
    final now = DateTime.now();
    final sessions = HistoryStore.sessions(widget.dj.history);
    if (sessions.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Tracks you play show up here, grouped into sessions.\n'
            'A track counts once it has been heard for 30 seconds.',
            textAlign: TextAlign.center,
            style: TextStyle(color: SideDeckTheme.muted),
          ),
        ),
      );
    }
    final q = _search.text.trim().toLowerCase();
    final current = HistoryStore.currentSession(widget.dj.history, now);
    final busy = widget.dj.loadingDeck != null || _stickBusy;
    final items = <Widget>[];
    for (final s in sessions) {
      var plays = s.tracks;
      if (q.isNotEmpty) {
        plays = plays
            .where((t) => t.title.toLowerCase().contains(q) || t.artist.toLowerCase().contains(q))
            .toList();
        if (plays.isEmpty) continue;
      }
      final live = current != null && s.start == current.start;
      items.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
          child: Text(
            '${_sessionDay(s.start, now).toUpperCase()} · ${_clock(s.start)}–${_clock(s.end)}'
            ' · ${s.tracks.length} track${s.tracks.length == 1 ? '' : 's'}'
            '${live ? ' · NOW' : ''}',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: live ? SideDeckTheme.deckLit : SideDeckTheme.muted,
            ),
          ),
        ),
      );
      // Newest play first within a session, numbered in play order.
      for (var i = plays.length - 1; i >= 0; i--) {
        final t = plays[i];
        final n = s.tracks.indexOf(t) + 1;
        final loadingThis = widget.dj.loadingPath == t.path;
        items.add(
          _songRow(
            lead: SizedBox(
              width: 58,
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: '$n',
                      style: const TextStyle(fontWeight: FontWeight.w700, color: SideDeckTheme.text),
                    ),
                    TextSpan(text: '  ${_clock(t.playedAt)}'),
                  ],
                ),
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 11, color: SideDeckTheme.muted),
              ),
            ),
            busyThis: false,
            analyzeTooltip: '',
            onAnalyze: null,
            title: t.title,
            artist: t.artist,
            status: 'deck ${t.deck == 0 ? 'A' : 'B'}',
            bpm: t.bpm > 0 ? t.bpm : null,
            key: t.key >= 0 ? t.key : null,
            durationSec: 0,
            actions: [
              _deckBtn('A', busy ? null : () => _loadHistoryTrack(t, 0), loadingThis && widget.dj.loadingDeck == 0),
              const SizedBox(width: 8),
              _deckBtn('B', busy ? null : () => _loadHistoryTrack(t, 1), loadingThis && widget.dj.loadingDeck == 1),
            ],
          ),
        );
      }
    }
    if (items.isEmpty) {
      return const Center(
        child: Text('No played tracks match.', style: TextStyle(color: SideDeckTheme.muted)),
      );
    }
    return ListView(children: items);
  }
}
