import 'dart:typed_data';

/// Reader for rekordbox analysis files (`ANLZ0000.DAT` / `.EXT`): the beat grid
/// and the cues. Ported from rbxport's reader (https://github.com/chrisle/rbxport,
/// crates/rbl-anlz, GPL-2.0-or-later), cross-checked against Deep Symmetry's
/// "Rekordbox export structure analysis". Big-endian; a `PMAI` header followed
/// by tagged sections.
class AnlzBeat {
  const AnlzBeat(this.beatInBar, this.tempo, this.timeSec);

  /// 1..4, where 1 is the downbeat.
  final int beatInBar;

  /// Local tempo in BPM.
  final double tempo;
  final double timeSec;
}

class AnlzCue {
  const AnlzCue({
    required this.hotCue,
    required this.timeSec,
    this.loopEndSec,
  });

  /// 0 for a memory cue, 1 for hot cue A, 2 for B, ...
  final int hotCue;
  final double timeSec;

  /// Set for a loop.
  final double? loopEndSec;

  bool get isLoop => loopEndSec != null;
}

class AnlzFile {
  AnlzFile({required this.beats, required this.cues});

  /// Beat by beat, so a grid can change tempo or restart its bar count.
  final List<AnlzBeat> beats;
  final List<AnlzCue> cues;

  /// Whether the file had an extended cue list (PCO2), which supersedes PCOB.
  bool extendedCues = false;
}

class AnlzReader {
  AnlzReader(Uint8List bytes) : _b = ByteData.sublistView(bytes), _len = bytes.length;

  final ByteData _b;
  final int _len;

  /// Parses what it recognises and skips the rest; null if it is not an ANLZ file.
  AnlzFile? read() {
    if (_len < 12 || _fourcc(0) != 'PMAI') return null;
    final beats = <AnlzBeat>[];
    final legacy = <AnlzCue>[];
    final extended = <AnlzCue>[];
    var at = _u32(4); // header length
    while (at + 12 <= _len) {
      final tag = _fourcc(at);
      final lenHeader = _u32(at + 4);
      final lenTag = _u32(at + 8);
      if (lenTag < 12 || at + lenTag > _len) break;
      switch (tag) {
        case 'PQTZ':
          _beatGrid(at, lenHeader, beats);
        case 'PCOB':
          _legacyCues(at, lenHeader, lenTag, legacy);
        case 'PCO2':
          _extendedCues(at, lenHeader, lenTag, extended);
      }
      at += lenTag;
    }
    final file = AnlzFile(beats: beats, cues: extended.isNotEmpty ? extended : legacy);
    file.extendedCues = extended.isNotEmpty;
    return file;
  }

  // PQTZ: u32 0, u32 (unclear; rbxport reads a grid-shift offset in its low
  // 16 bits, not applied here until a real stick confirms it), u32 beat count,
  // then 8 bytes per beat: u16 beat in bar, u16 tempo x 100, u32 time in ms.
  void _beatGrid(int at, int lenHeader, List<AnlzBeat> out) {
    final count = _u32(at + 20);
    var e = at + lenHeader;
    for (var i = 0; i < count && e + 8 <= _len; i++, e += 8) {
      out.add(AnlzBeat(_u16(e), _u16(e + 2) / 100.0, _u32(e + 4) / 1000.0));
    }
  }

  // PCOB: u32 list type (1 hot, 0 memory) at 0x0C, u16 count at 0x12, then
  // PCPT entries: hot cue u32 at 0x0C (0 = memory, 1 = A), kind u8 at 0x1C
  // (1 cue, 2 loop), time ms u32 at 0x20, loop end ms u32 at 0x24.
  void _legacyCues(int at, int lenHeader, int lenTag, List<AnlzCue> out) {
    final count = _u16(at + 0x12);
    var e = at + lenHeader;
    final end = at + lenTag;
    for (var i = 0; i < count && e + 0x28 <= end; i++) {
      if (_fourcc(e) != 'PCPT') break;
      final lenEntry = _u32(e + 8);
      out.add(_cue(_u32(e + 0x0C), _u8(e + 0x1C), _u32(e + 0x20), _u32(e + 0x24)));
      if (lenEntry < 0x28) break;
      e += lenEntry;
    }
  }

  // PCO2: u32 list type at 0x0C, u16 count at 0x10, then PCP2 entries:
  // hot cue u32 at 0x0C, kind u8 at 0x10, time ms u32 at 0x14, loop end ms
  // u32 at 0x18 (colour and comment follow; not used yet).
  void _extendedCues(int at, int lenHeader, int lenTag, List<AnlzCue> out) {
    final count = _u16(at + 0x10);
    var e = at + lenHeader;
    final end = at + lenTag;
    for (var i = 0; i < count && e + 0x1C <= end; i++) {
      if (_fourcc(e) != 'PCP2') break;
      final lenEntry = _u32(e + 8);
      out.add(_cue(_u32(e + 0x0C), _u8(e + 0x10), _u32(e + 0x14), _u32(e + 0x18)));
      if (lenEntry < 0x1C) break;
      e += lenEntry;
    }
  }

  AnlzCue _cue(int hotCue, int kind, int timeMs, int loopEndMs) {
    final isLoop = kind == 2 && loopEndMs != 0xFFFFFFFF && loopEndMs > timeMs;
    return AnlzCue(
      hotCue: hotCue,
      timeSec: timeMs / 1000.0,
      loopEndSec: isLoop ? loopEndMs / 1000.0 : null,
    );
  }

  String _fourcc(int at) =>
      at + 4 <= _len ? String.fromCharCodes(Uint8List.sublistView(_b, at, at + 4)) : '';
  int _u8(int at) => at < _len ? _b.getUint8(at) : 0;
  int _u16(int at) => at + 2 <= _len ? _b.getUint16(at, Endian.big) : 0;
  int _u32(int at) => at + 4 <= _len ? _b.getUint32(at, Endian.big) : 0;
}
