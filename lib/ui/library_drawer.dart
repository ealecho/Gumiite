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
    _djSeen = _djView();
    widget.dj.addListener(_onDj);
  }

  void _onLib() {
    if (mounted) setState(() {});
  }

  // The deck controller notifies 20 times a second while a deck plays (the
  // playhead), and every rebuild here re-filters and re-sorts the whole
  // library. Rebuild only when something this sheet shows has changed.
  Object? _djSeen;

  Object _djView() {
    final dj = widget.dj;
    final a = dj.deck(0);
    final b = dj.deck(1);
    return (
      dj.loadingDeck,
      dj.loadingPath,
      dj.loadingTitle,
      dj.engineError,
      dj.history, // replaced, never edited in place
      dj.playedPaths,
      dj.keyNotation,
      (a.loaded, a.key, a.bpm, a.path),
      (b.loaded, b.key, b.bpm, b.path),
    );
  }

  void _onDj() {
    final view = _djView();
    if (view == _djSeen) return;
    _djSeen = view;
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
    widget.dj.removeListener(_onDj);
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
      return Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Plug in a USB stick exported from rekordbox (through a USB-C hub if the '
            'mixer is on the port), then open ⋮ → Import a rekordbox USB and pick the '
            'stick.\n\nIts tracks, playlists, beat grids and cues come in; the grids and '
            'cues you set in rekordbox are kept.',
            textAlign: TextAlign.center,
            style: TextStyle(color: SideDeckTheme.muted),
          ),
        ),
      );
    }
    final tracks = _stickVisible();
    final busy = widget.dj.loadingDeck != null || _stickBusy;
    return ListView.builder(
      itemCount: tracks.length,
      itemBuilder: (context, i) {
        final t = tracks[i];
        return _songRow(
          // The grid and cues come from rekordbox: nothing to analyze.
          analyzeLabel: '',
          title: t.title,
          artist: t.artist,
          bpm: t.bpm > 0 ? t.bpm : null,
          key: t.key >= 0 ? t.key : null,
          gridUnsure: t.gridConfidence >= 0 && t.gridConfidence < TrackAnalysis.unsureBelow,
          played: widget.dj.playedPaths.contains(t.path),
          durationSec: t.durationSec.toDouble(),
          working: widget.dj.loadingPath == t.path,
          onLoad: busy ? null : (deck) => _loadStickTrack(t, deck),
        );
      },
    );
  }

  /// The USB tab's tracks: the picked playlist in its own order, or all
  /// tracks by the sort menu, filtered by the search box.
  List<StickTrack> _stickVisible() {
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
    if (playlist == null) {
      tracks = _sorted(tracks, (t) => (title: t.title, artist: t.artist, bpm: t.bpm, key: t.key));
    }
    return tracks;
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

  // Clean library layout: a top bar (close, title, search, a ⋮ menu with the
  // tab's tools), a line with the count, total time and sort, plain song
  // rows whose ⋮ (or a tap on the row) loads them, and the tabs along the
  // bottom.
  static const _tabs = [
    (Icons.library_music, 'Local'),
    (Icons.cloud_outlined, 'Remote'),
    (Icons.usb, 'USB'),
    (Icons.history, 'History'),
  ];

  bool _searchOpen = false;

  void _selectTab(int i) {
    setState(() => _tab = i);
    // One box serves every tab; back on Local it must show the filter that is
    // actually applied.
    if (i == 0 && _search.text != widget.library.query) {
      _search.text = widget.library.query;
    }
    if (i == 1 && _client != null && !_searching && _openPlaylist == null && _playlists.isEmpty) {
      _loadPlaylists();
    }
  }

  void _closeSearch() {
    setState(() => _searchOpen = false);
    if (_search.text.isNotEmpty) {
      _search.clear();
      _onSearchChanged('');
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
            _topBar(lib),
            _infoLine(tracks),
            Divider(height: 1, color: SideDeckTheme.panelAlt),
            if (lib.analyzing || widget.dj.loadingDeck != null || lib.error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                child: _statusLine(lib),
              ),
            if (_tab == 2 && _stickStatus != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                child: Text(_stickStatus!, style: TextStyle(fontSize: 12, color: SideDeckTheme.muted)),
              ),
            Expanded(
              child: switch (_tab) {
                0 => _localList(tracks),
                1 => _remoteList(),
                2 => _stickList(),
                _ => _historyList(),
              },
            ),
            _bottomNav(),
          ],
        ),
      ),
    );
  }

  String get _title => switch (_tab) {
    0 => 'Local',
    1 => _openPlaylist?.name ?? (_searching ? 'Search' : 'Playlists'),
    2 => 'rekordbox USB',
    _ => 'History',
  };

  Widget _topBar(LibraryController lib) {
    final searching = _searchOpen || _search.text.isNotEmpty;
    return SizedBox(
      height: 52,
      child: Row(
        children: [
          IconButton(
            tooltip: 'Close',
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close),
          ),
          if (_tab == 1 && _openPlaylist != null && !searching)
            IconButton(
              tooltip: 'Playlists',
              onPressed: _loadPlaylists,
              icon: const Icon(Icons.arrow_back),
            ),
          const SizedBox(width: 4),
          Expanded(
            child: searching
                ? TextField(
                    controller: _search,
                    autofocus: _searchOpen,
                    style: const TextStyle(fontSize: 16),
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: _tab == 1 ? 'Search the server' : 'Search',
                      border: InputBorder.none,
                      isDense: true,
                    ),
                    onChanged: _onSearchChanged,
                    onSubmitted: (v) {
                      if (_tab == 1) _searchRemote(v);
                    },
                  )
                : Text(
                    _title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
                  ),
          ),
          if (_tab == 0 && lib.analyzing)
            IconButton(
              tooltip: 'Stop analysis',
              onPressed: lib.cancelAnalyze,
              icon: const Icon(Icons.stop_circle_outlined),
            ),
          IconButton(
            tooltip: searching ? 'Close search' : 'Search',
            onPressed: searching ? _closeSearch : () => setState(() => _searchOpen = true),
            icon: Icon(searching ? Icons.search_off : Icons.search),
          ),
          _toolsMenu(lib),
        ],
      ),
    );
  }

  /// The tab's tools, out of the way in a ⋮ menu.
  Widget _toolsMenu(LibraryController lib) {
    final idle = !lib.loading && !lib.analyzing;
    final items = <PopupMenuEntry<String>>[
      if (_tab == 0) ...[
        PopupMenuItem(value: 'folder', enabled: idle, child: const Text('Add a music folder')),
        PopupMenuItem(value: 'files', enabled: idle, child: const Text('Add files')),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'missing',
          enabled: idle && lib.unanalyzedCount > 0,
          child: Text(
            lib.unanalyzedCount > 0 ? 'Analyze missing (${lib.unanalyzedCount})' : 'Analyze missing',
          ),
        ),
        PopupMenuItem(value: 'all', enabled: idle && lib.tracks.isNotEmpty, child: const Text('Re-analyze all')),
      ],
      if (_tab == 1) ...[
        PopupMenuItem(value: 'playlists', enabled: _client != null, child: const Text('Refresh playlists')),
      ],
      if (_tab == 2)
        PopupMenuItem(value: 'import', enabled: !_stickBusy, child: const Text('Import a rekordbox USB')),
      if (_tab == 3)
        PopupMenuItem(
          value: 'clear',
          enabled: widget.dj.history.isNotEmpty,
          child: const Text('Clear history'),
        ),
      if (widget.onOpenSettings != null) ...[
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'settings', child: Text('Settings')),
      ],
    ];
    return PopupMenuButton<String>(
      tooltip: 'More',
      icon: const Icon(Icons.more_vert),
      color: SideDeckTheme.panelAlt,
      itemBuilder: (_) => items,
      onSelected: (v) async {
        switch (v) {
          case 'folder':
            await lib.pickFolder();
          case 'files':
            await lib.pickFiles();
          case 'missing':
            await _reloadAnalyzedDecks(await lib.analyzeMissing());
          case 'all':
            await _reloadAnalyzedDecks(await lib.analyzeAll());
          case 'playlists':
            await _loadPlaylists();
          case 'import':
            await _importStick();
          case 'clear':
            await _confirmClearHistory();
          case 'settings':
            widget.onOpenSettings?.call();
        }
      },
    );
  }

  static String _totalTime(double sec) {
    final m = (sec / 60).round();
    return m >= 60 ? '${m ~/ 60} h ${m % 60} min' : '$m min';
  }

  static TextStyle get _infoStyle => TextStyle(fontSize: 14, color: SideDeckTheme.text);
  static TextStyle get _infoMuted => TextStyle(fontSize: 14, color: SideDeckTheme.muted);

  /// "58 tracks · 6 h 44 min" and the sort, under the top bar. On USB the
  /// count opens the playlist picker.
  Widget _infoLine(List<LibraryTrack> local) {
    Widget? left;
    var sortable = true;
    switch (_tab) {
      case 0:
        final sec = local.fold(0.0, (s, t) => s + t.durationMs / 1000.0);
        left = Text.rich(
          TextSpan(children: [
            TextSpan(text: '${local.length} tracks', style: _infoStyle),
            if (sec > 0) TextSpan(text: '   ${_totalTime(sec)}', style: _infoMuted),
          ]),
        );
      case 1:
        if (_client == null) return const SizedBox(height: 4);
        if (!_searching && _openPlaylist == null) {
          left = Text('${_playlists.length} playlists', style: _infoStyle);
          sortable = false;
        } else {
          final sec = _remote.fold(0.0, (s, t) => s + t.duration);
          left = Text.rich(
            TextSpan(children: [
              TextSpan(text: '${_remote.length} tracks', style: _infoStyle),
              if (sec > 0) TextSpan(text: '   ${_totalTime(sec)}', style: _infoMuted),
            ]),
          );
        }
      case 2:
        if (_stick.isEmpty) return const SizedBox(height: 4);
        final shown = _stickVisible();
        final sec = shown.fold(0.0, (s, t) => s + t.durationSec);
        final names = _stickPlaylistNames();
        final current = _stickPlaylist == null
            ? 'All tracks'
            : names.firstWhere((e) => e.$1 == _stickPlaylist, orElse: () => (0, 'Playlist')).$2;
        left = PopupMenuButton<int>(
          tooltip: 'Playlist',
          color: SideDeckTheme.panelAlt,
          onSelected: (id) => setState(() => _stickPlaylist = id < 0 ? null : id),
          itemBuilder: (_) => [
            CheckedPopupMenuItem(value: -1, checked: _stickPlaylist == null, child: const Text('All tracks')),
            for (final (id, name) in names)
              CheckedPopupMenuItem(value: id, checked: _stickPlaylist == id, child: Text(name)),
          ],
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text.rich(
                  TextSpan(children: [
                    TextSpan(text: current, style: _infoStyle),
                    TextSpan(text: '   ${shown.length} tracks', style: _infoMuted),
                    if (sec > 0) TextSpan(text: ' · ${_totalTime(sec)}', style: _infoMuted),
                  ]),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Icon(Icons.arrow_drop_down, color: SideDeckTheme.muted),
            ],
          ),
        );
        // A playlist keeps its own order.
        sortable = _stickPlaylist == null;
      default:
        final n = widget.dj.history.length;
        left = Text('$n play${n == 1 ? '' : 's'}', style: _infoStyle);
        sortable = false;
    }
    return SizedBox(
      height: 36,
      child: Padding(
        padding: const EdgeInsets.only(left: 16, right: 4),
        child: Row(
          children: [
            Expanded(child: Align(alignment: Alignment.centerLeft, child: left)),
            if (sortable) _sortMenu(),
          ],
        ),
      ),
    );
  }

  Widget _sortMenu() {
    final label = switch (widget.library.sort) {
      TrackSort.name => 'Name',
      TrackSort.bpm => 'BPM',
      TrackSort.key => 'Key',
    };
    return PopupMenuButton<TrackSort>(
      tooltip: 'Sort',
      color: SideDeckTheme.panelAlt,
      onSelected: widget.library.setSort,
      itemBuilder: (context) => [
        _sortItem(TrackSort.name, 'Name'),
        _sortItem(TrackSort.bpm, 'BPM'),
        _sortItem(TrackSort.key, 'Key'),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: _infoStyle),
            Icon(Icons.arrow_drop_down, color: SideDeckTheme.muted),
          ],
        ),
      ),
    );
  }

  Widget _bottomNav() {
    return Container(
      height: 54,
      decoration: BoxDecoration(
        color: SideDeckTheme.panelAlt,
        border: Border(top: BorderSide(color: SideDeckTheme.flat ? SideDeckTheme.p.divider : const Color(0xFF2A3140))),
      ),
      child: Row(
        children: [
          for (var i = 0; i < _tabs.length; i++)
            Expanded(
              child: InkWell(
                onTap: () => _selectTab(i),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      _tabs[i].$1,
                      size: 22,
                      color: _tab == i ? SideDeckTheme.accentA : SideDeckTheme.muted,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _tabs[i].$2,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: _tab == i ? FontWeight.w700 : FontWeight.w500,
                        color: _tab == i ? SideDeckTheme.accentA : SideDeckTheme.muted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
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
      style: TextStyle(color: SideDeckTheme.muted, fontSize: 13),
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

  /// Right of the title: "116 BPM" over key and length, as in the reference
  /// layout; only the length when there is no analysis yet.
  Widget _trackMeta(double? bpm, int? key, double durationSec, {bool gridUnsure = false}) {
    final hasBpm = bpm != null && bpm > 0;
    final hasKey = key != null && key >= 0;
    final keyColor = _compatibleKeyColor(key);
    final bpmText = hasBpm
        ? ((bpm - bpm.roundToDouble()).abs() < 0.05 ? bpm.round().toString() : bpm.toStringAsFixed(1))
        : null;
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (bpmText != null)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (gridUnsure) ...[const GridWarningBadge(), const SizedBox(width: 4)],
                Text('$bpmText BPM', style: TextStyle(fontSize: 14, color: SideDeckTheme.text)),
              ],
            ),
          if (durationSec > 0 || hasKey)
            Text.rich(
              TextSpan(
                style: TextStyle(color: SideDeckTheme.muted, fontSize: 13),
                children: [
                  if (hasKey)
                    TextSpan(
                      text: formatKey(key),
                      style: TextStyle(
                        color: keyColor ?? SideDeckTheme.muted,
                        fontWeight: keyColor == null ? null : FontWeight.w700,
                      ),
                    ),
                  if (durationSec > 0 && hasKey) const TextSpan(text: '  '),
                  if (durationSec > 0) TextSpan(text: formatDuration(durationSec)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _statusLine(LibraryController lib) {
    if (lib.error != null) {
      return Text(
        lib.error!,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: SideDeckTheme.p.error, fontSize: 12),
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
            style: TextStyle(fontSize: 11, color: SideDeckTheme.muted),
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
            style: TextStyle(fontSize: 11, color: SideDeckTheme.muted),
          ),
        ),
      ],
    );
  }

  /// One song: title and artist, BPM / key / length, and a ⋮ menu (also on a
  /// tap anywhere on the row) to load it on deck A or B or analyze it.
  /// [onLoad] null while something else is loading; [working] shows a
  /// spinner in place of the ⋮.
  Widget _songRow({
    required String title,
    required String artist,
    String? status,
    required double? bpm,
    required int? key,
    required double durationSec,
    required void Function(int deck)? onLoad,
    VoidCallback? onAnalyze,
    String analyzeLabel = 'Analyze',
    bool working = false,
    bool gridUnsure = false,
    bool played = false,
    Widget? lead,
  }) {
    Future<void> menu(Offset at) async {
      final size = MediaQuery.sizeOf(context);
      final v = await showMenu<int>(
        context: context,
        color: SideDeckTheme.panelAlt,
        position: RelativeRect.fromLTRB(at.dx, at.dy, size.width - at.dx, size.height - at.dy),
        items: [
          PopupMenuItem(value: 0, enabled: onLoad != null, child: const Text('Load on deck A')),
          PopupMenuItem(value: 1, enabled: onLoad != null, child: const Text('Load on deck B')),
          if (analyzeLabel.isNotEmpty && (onAnalyze != null || onLoad != null)) ...[
            const PopupMenuDivider(),
            PopupMenuItem(value: 2, enabled: onAnalyze != null, child: Text(analyzeLabel)),
          ],
        ],
      );
      if (v == 0 || v == 1) onLoad?.call(v!);
      if (v == 2) onAnalyze?.call();
    }

    return InkWell(
      onTapUp: (d) => menu(d.globalPosition),
      onTap: () {},
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 0, 8),
        child: Row(
          children: [
            if (lead != null) ...[lead, const SizedBox(width: 10)],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Played this session: ticked and dimmed, as in Mixxx.
                  Row(
                    children: [
                      if (played) ...[
                        Icon(Icons.check, size: 15, color: SideDeckTheme.muted),
                        const SizedBox(width: 4),
                      ],
                      Flexible(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 16,
                            color: played ? SideDeckTheme.muted : SideDeckTheme.text,
                          ),
                        ),
                      ),
                    ],
                  ),
                  ?_trackArtist(artist, status: status),
                ],
              ),
            ),
            _trackMeta(bpm, key, durationSec, gridUnsure: gridUnsure),
            SizedBox(
              width: 44,
              child: working
                  ? const Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : Builder(
                      builder: (bctx) => IconButton(
                        tooltip: 'Track menu',
                        icon: const Icon(Icons.more_vert),
                        onPressed: () {
                          final box = bctx.findRenderObject() as RenderBox;
                          menu(box.localToGlobal(box.size.center(Offset.zero)));
                        },
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _localList(List<LibraryTrack> tracks) {
    final lib = widget.library;
    if (lib.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (tracks.isEmpty) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Open ⋮ and add your music folder.\n\n'
            'Then tap a track to load it on deck A or B, or to analyze it.',
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
        final busy = lib.analyzing || widget.dj.loadingDeck != null;
        return _songRow(
          analyzeLabel: t.hasAnalysis ? 'Re-analyze BPM / grid' : 'Analyze BPM / key',
          onAnalyze: busy ? null : () => _analyzeLocal(t),
          title: t.title,
          artist: t.artist,
          bpm: t.bpm,
          key: t.key,
          gridUnsure: t.gridUnsure,
          played: widget.dj.playedPaths.contains(t.path),
          durationSec: t.durationMs / 1000.0,
          working: lib.analyzingPath == t.path || widget.dj.loadingPath == t.path,
          onLoad: busy ? null : (deck) => _loadLocal(t, deck),
        );
      },
    );
  }

  Widget _playlistList() {
    if (_playlists.isEmpty) {
      return Center(
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
                  style: TextStyle(color: SideDeckTheme.muted, fontSize: 12),
                ),
          trailing: Icon(Icons.chevron_right, size: 20, color: SideDeckTheme.muted),
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
            Text(
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
        child: Text(_remoteError!, style: TextStyle(color: SideDeckTheme.p.error)),
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
          style: TextStyle(color: SideDeckTheme.muted),
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
          analyzeLabel: meta == null ? 'Download & analyze' : 'Re-analyze BPM / grid',
          onAnalyze: busy ? null : () => _analyzeRemote(t),
          title: t.title,
          artist: t.artist,
          status: busyThis ? _remoteBusyLabel : null,
          bpm: meta?.bpm,
          key: meta?.key,
          gridUnsure: meta?.gridUnsure ?? false,
          durationSec: t.duration.toDouble(),
          working: busyThis,
          onLoad: busy ? null : (deck) => _loadRemote(t, deck),
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

  static String _playedFor(Duration d) {
    final m = (d.inSeconds / 60).round();
    if (m < 60) return '$m min';
    return m % 60 == 0 ? '${m ~/ 60} h' : '${m ~/ 60} h ${m % 60} min';
  }

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
      return Center(
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
    // Plays logged before lengths were recorded take them from the library.
    final lengths = <String, double>{
      for (final t in _stick) t.path: t.durationSec.toDouble(),
      for (final t in widget.library.tracks) t.path: t.durationMs / 1000.0,
    };
    double? lengthOf(String path) => lengths[path];
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
            // How long the session played, rather than its clock times.
            '${_sessionDay(s.start, now).toUpperCase()} · ${_playedFor(s.playedLength(now, lengthOf: lengthOf))}'
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
                      style: TextStyle(fontWeight: FontWeight.w700, color: SideDeckTheme.text),
                    ),
                    TextSpan(text: '  ${_clock(t.playedAt)}'),
                  ],
                ),
                textAlign: TextAlign.right,
                style: TextStyle(fontSize: 11, color: SideDeckTheme.muted),
              ),
            ),
            analyzeLabel: '',
            title: t.title,
            artist: t.artist,
            status: 'deck ${t.deck == 0 ? 'A' : 'B'}',
            bpm: t.bpm > 0 ? t.bpm : null,
            key: t.key >= 0 ? t.key : null,
            durationSec: 0,
            working: loadingThis,
            onLoad: busy ? null : (deck) => _loadHistoryTrack(t, deck),
          ),
        );
      }
    }
    if (items.isEmpty) {
      return Center(
        child: Text('No played tracks match.', style: TextStyle(color: SideDeckTheme.muted)),
      );
    }
    return ListView(children: items);
  }
}
