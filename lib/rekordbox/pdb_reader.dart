import 'dart:convert';
import 'dart:typed_data';

/// Reader for rekordbox's device library, `PIONEER/rekordbox/export.pdb`
/// (Pioneer's "DeviceSQL"). Ported from rbxport's reader
/// (https://github.com/chrisle/rbxport, crates/rbl-pdb, GPL-2.0-or-later),
/// cross-checked against Deep Symmetry's "Rekordbox export structure analysis".
///
/// Only what an import needs: tracks, artists, albums, keys and playlists.
/// Little-endian throughout; fixed-size pages, each table a linked list of
/// pages whose rows are found through a row index at the end of the page.
class PdbTrack {
  PdbTrack({
    required this.id,
    required this.title,
    required this.artistId,
    required this.albumId,
    required this.keyId,
    required this.tempo,
    required this.durationSec,
    required this.filePath,
    required this.analyzePath,
  });

  final int id;
  final String title;
  final int artistId;
  final int albumId;
  final int keyId;

  /// BPM at the start of the track (stored as BPM x 100).
  final double tempo;
  final int durationSec;

  /// Audio path relative to the stick root, e.g. `/Contents/A/B/x.mp3`.
  final String filePath;

  /// The track's `.DAT` analysis file, relative to the stick root (may be empty).
  final String analyzePath;
}

class PdbPlaylist {
  PdbPlaylist({
    required this.id,
    required this.parentId,
    required this.name,
    required this.isFolder,
    required this.sortOrder,
  });

  final int id;
  final int parentId;
  final String name;
  final bool isFolder;
  final int sortOrder;
}

class PdbLibrary {
  PdbLibrary({
    required this.tracks,
    required this.artists,
    required this.albums,
    required this.keys,
    required this.playlists,
    required this.playlistTracks,
  });

  final List<PdbTrack> tracks;
  final Map<int, String> artists;
  final Map<int, String> albums;
  final Map<int, String> keys;
  final List<PdbPlaylist> playlists;

  /// Playlist id -> track ids in playlist order.
  final Map<int, List<int>> playlistTracks;
}

class PdbFormatException implements Exception {
  PdbFormatException(this.message);
  final String message;
  @override
  String toString() => 'export.pdb: $message';
}

class PdbReader {
  PdbReader(Uint8List bytes) : _b = ByteData.sublistView(bytes), _len = bytes.length;

  final ByteData _b;
  final int _len;

  static const _tracks = 0;
  static const _artists = 2;
  static const _albums = 3;
  static const _keys = 5;
  static const _playlistTree = 7;
  static const _playlistEntries = 8;

  PdbLibrary read() {
    if (_len < 0x1C) throw PdbFormatException('file too short');
    final pageSize = _u32(0x04);
    final tableCount = _u32(0x08);
    if (pageSize < 0x100 || pageSize > 0x10000 || tableCount > 64) {
      throw PdbFormatException('not a rekordbox export (page size $pageSize)');
    }
    final tables = <int, (int, int)>{};
    for (var i = 0; i < tableCount; i++) {
      final at = 0x1C + i * 16;
      if (at + 16 > _len) break;
      tables[_u32(at)] = (_u32(at + 8), _u32(at + 12)); // first, last page
    }

    final tracks = <PdbTrack>[];
    final artists = <int, String>{};
    final albums = <int, String>{};
    final keys = <int, String>{};
    final playlists = <PdbPlaylist>[];
    final entries = <int, List<(int, int)>>{};

    void each(int type, void Function(int row) visit) {
      final t = tables[type];
      if (t != null) _rows(pageSize, t.$1, t.$2, visit);
    }

    each(_tracks, (r) => tracks.add(_track(r)));
    each(_artists, (r) {
      final subtype = _u16(r);
      final id = _u32(r + 4);
      final nameAt = subtype == 0x64 ? _u16(r + 0x0A) : _u8(r + 9);
      artists[id] = _string(r + nameAt);
    });
    each(_albums, (r) {
      final subtype = _u16(r);
      final id = _u32(r + 0x0C);
      final nameAt = subtype == 0x84 ? _u16(r + 0x16) : _u8(r + 0x15);
      albums[id] = _string(r + nameAt);
    });
    each(_keys, (r) => keys[_u32(r)] = _string(r + 8));
    each(_playlistTree, (r) {
      playlists.add(PdbPlaylist(
        parentId: _u32(r),
        sortOrder: _u32(r + 8),
        id: _u32(r + 12),
        isFolder: _u32(r + 16) != 0,
        name: _string(r + 20),
      ));
    });
    each(_playlistEntries, (r) {
      final entryIndex = _u32(r);
      final trackId = _u32(r + 4);
      final playlistId = _u32(r + 8);
      entries.putIfAbsent(playlistId, () => []).add((entryIndex, trackId));
    });

    final ordered = <int, List<int>>{};
    for (final e in entries.entries) {
      final list = e.value..sort((a, b) => a.$1.compareTo(b.$1));
      ordered[e.key] = [for (final x in list) x.$2];
    }
    return PdbLibrary(
      tracks: tracks,
      artists: artists,
      albums: albums,
      keys: keys,
      playlists: playlists,
      playlistTracks: ordered,
    );
  }

  PdbTrack _track(int r) {
    String slot(int i) => _string(r + _u16(r + 0x5E + 2 * i));
    return PdbTrack(
      keyId: _u32(r + 0x20),
      tempo: _u32(r + 0x38) / 100.0,
      albumId: _u32(r + 0x40),
      artistId: _u32(r + 0x44),
      id: _u32(r + 0x48),
      durationSec: _u16(r + 0x54),
      analyzePath: slot(14),
      title: slot(17),
      filePath: slot(20),
    );
  }

  /// Visits the absolute offset of every live row in a table's data pages.
  void _rows(int pageSize, int first, int last, void Function(int row) visit) {
    var page = first;
    final seen = <int>{};
    while (seen.add(page)) {
      final at = page * pageSize;
      if (at + pageSize > _len) break;
      final flags = _u8(at + 0x1B);
      if (flags & 0x40 == 0) {
        // Low 13 bits of the 24-bit field: row index entries (deleted ones
        // included). rbxport issue #284 came from trusting 0x20/0x22 instead.
        final rowIndexLen = (_u8(at + 0x18) | _u8(at + 0x19) << 8 | _u8(at + 0x1A) << 16) & 0x1FFF;
        final groups = (rowIndexLen + 15) ~/ 16;
        for (var g = 0; g < groups; g++) {
          final base = at + pageSize - g * 0x24;
          final present = _u16(base - 4);
          final inGroup = rowIndexLen - g * 16 < 16 ? rowIndexLen - g * 16 : 16;
          for (var i = 0; i < inGroup; i++) {
            // A deleted row keeps its index entry but points at garbage.
            if (present & (1 << i) == 0) continue;
            final row = at + 0x28 + _u16(base - (6 + 2 * i));
            if (row < at + 0x28 || row >= at + pageSize) continue;
            visit(row);
          }
        }
      }
      if (page == last) break;
      page = _u32(at + 0x0C);
    }
  }

  /// DeviceSQL string at an absolute offset.
  String _string(int at) {
    if (at <= 0 || at >= _len) return '';
    final kind = _u8(at);
    if (kind & 1 == 1) {
      // Short ASCII: the byte holds (length + 1) * 2 + 1.
      final n = (kind >> 1) - 1;
      return _ascii(at + 1, n);
    }
    if (at + 4 > _len) return '';
    final n = _u16(at + 1) - 4; // length includes the 4 header bytes
    if (kind == 0x40) return _ascii(at + 4, n);
    if (kind == 0x90) {
      final units = <int>[];
      for (var i = 0; i + 1 < n && at + 4 + i + 1 < _len; i += 2) {
        final u = _u16(at + 4 + i);
        if (u == 0) break;
        units.add(u);
      }
      return String.fromCharCodes(units);
    }
    return '';
  }

  String _ascii(int at, int n) {
    if (n <= 0) return '';
    final end = at + n > _len ? _len : at + n;
    final bytes = Uint8List.sublistView(_b, at, end);
    return latin1.decode(bytes).replaceAll('\u0000', '');
  }

  int _u8(int at) => at < _len ? _b.getUint8(at) : 0;
  int _u16(int at) => at + 2 <= _len ? _b.getUint16(at, Endian.little) : 0;
  int _u32(int at) => at + 4 <= _len ? _b.getUint32(at, Endian.little) : 0;
}
