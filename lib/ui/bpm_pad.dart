import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sidedeck/theme/sidedeck_theme.dart';

/// Type an exact BPM on an in-app keypad, beside a large readout. The
/// system keyboard would cover most of a landscape phone screen.
///
/// Returns the BPM to set, or null when cancelled.
Future<double?> showBpmPad(
  BuildContext context, {
  required String title,
  required double current,
  required double trackBpm,
}) {
  return showDialog<double>(
    context: context,
    builder: (_) => _BpmPad(title: title, current: current, trackBpm: trackBpm),
  );
}

class _BpmPad extends StatefulWidget {
  const _BpmPad({required this.title, required this.current, required this.trackBpm});

  final String title;
  final double current;
  final double trackBpm;

  @override
  State<_BpmPad> createState() => _BpmPadState();
}

class _BpmPadState extends State<_BpmPad> {
  late String _text = widget.current.toStringAsFixed(2);
  // Like a selected field: the first key replaces the shown value.
  bool _fresh = true;

  double get _lo => widget.trackBpm * 0.5;
  double get _hi => widget.trackBpm * 2.0;

  double? get _value {
    final v = double.tryParse(_text);
    return v != null && v >= _lo && v <= _hi ? v : null;
  }

  void _key(String k) {
    HapticFeedback.selectionClick();
    setState(() {
      if (k == '⌫') {
        _text = _fresh || _text.isEmpty ? '' : _text.substring(0, _text.length - 1);
        _fresh = false;
        return;
      }
      var t = _fresh ? '' : _text;
      _fresh = false;
      if (k == '.') {
        if (t.contains('.')) return;
        if (t.isEmpty) t = '0';
      } else {
        final dot = t.indexOf('.');
        if (dot >= 0 && t.length - dot > 2) return; // two decimals
        if (dot < 0 && t.length >= 3) return; // up to 999
      }
      _text = t + k;
    });
  }

  Widget _padKey(String k) {
    return Padding(
      padding: const EdgeInsets.all(3),
      child: Material(
        color: SideDeckTheme.deckButton,
        borderRadius: BorderRadius.circular(4),
        child: InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: () => _key(k),
          child: SizedBox(
            width: 62,
            height: 46,
            child: Center(
              child: Text(
                k,
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: SideDeckTheme.buttonText),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ok = _value != null;
    final shown = _text.isEmpty ? '—' : _text;
    // Upright there is no room beside the keypad: readout on top.
    final narrow = MediaQuery.sizeOf(context).width < 560;
    return Dialog(
      backgroundColor: SideDeckTheme.panel,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Flex(
          direction: narrow ? Axis.vertical : Axis.horizontal,
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 220,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        shown,
                        style: TextStyle(
                          fontFamily: SideDeckTheme.displayFont,
                          fontSize: 44,
                          fontWeight: FontWeight.w800,
                          fontFeatures: const [FontFeature.tabularFigures()],
                          color: _fresh ? SideDeckTheme.deckLit : SideDeckTheme.text,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text('BPM', style: TextStyle(fontSize: 14, color: SideDeckTheme.muted)),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Track ${widget.trackBpm.toStringAsFixed(2)} · '
                    '${_lo.toStringAsFixed(1)}–${_hi.toStringAsFixed(1)}',
                    style: TextStyle(
                      fontSize: 12,
                      color: ok || _text.isEmpty ? SideDeckTheme.muted : SideDeckTheme.p.error,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      FilledButton(
                        onPressed: ok ? () => Navigator.pop(context, _value) : null,
                        child: const Text('Set'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(context, widget.trackBpm),
                        child: const Text('Original'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Cancel'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12, height: 12),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final row in const [
                  ['7', '8', '9'],
                  ['4', '5', '6'],
                  ['1', '2', '3'],
                  ['.', '0', '⌫'],
                ])
                  Row(mainAxisSize: MainAxisSize.min, children: [for (final k in row) _padKey(k)]),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
