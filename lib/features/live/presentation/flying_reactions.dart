import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

/// A self-contained widget that renders floating emoji reactions similar to
/// TikTok Live / Instagram Live floating hearts.
///
/// Each emission on [stream] spawns a new emoji that floats upward from the
/// bottom-right area, drifting horizontally with a sine wave, fading out and
/// scaling down as it rises. At most [maxVisible] emojis are shown at once;
/// older ones are discarded when the limit is exceeded.
class FlyingReactions extends StatefulWidget {
  const FlyingReactions({super.key, required this.stream, this.maxVisible = 20});

  /// Stream of emoji strings. Each emission triggers a new floating emoji.
  final Stream<String> stream;

  /// Maximum number of concurrently visible emojis.
  final int maxVisible;

  @override
  State<FlyingReactions> createState() => _FlyingReactionsState();
}

class _FlyingReactionsState extends State<FlyingReactions>
    with TickerProviderStateMixin {
  final _rng = Random();
  final _entries = <_ReactionEntry>[];
  StreamSubscription<String>? _subscription;

  @override
  void initState() {
    super.initState();
    _subscription = widget.stream.listen(_onEmoji);
  }

  @override
  void didUpdateWidget(FlyingReactions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.stream != widget.stream) {
      _subscription?.cancel();
      _subscription = widget.stream.listen(_onEmoji);
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    for (final entry in _entries) {
      entry.controller.dispose();
    }
    _entries.clear();
    super.dispose();
  }

  void _onEmoji(String emoji) {
    if (!mounted || emoji.isEmpty) return;

    // Trim oldest entries when limit exceeded.
    while (_entries.length >= widget.maxVisible) {
      final oldest = _entries.removeAt(0);
      oldest.controller.dispose();
    }

    final duration = Duration(milliseconds: 2000 + _rng.nextInt(1000));
    final controller = AnimationController(vsync: this, duration: duration);
    final startX = _rng.nextDouble() * 0.6; // 0..0.6 fraction of width
    final driftAmplitude = 8.0 + _rng.nextDouble() * 16.0; // px
    final driftPhaseOffset = _rng.nextDouble() * 2 * pi;

    final entry = _ReactionEntry(
      emoji: emoji,
      controller: controller,
      startX: startX,
      driftAmplitude: driftAmplitude,
      driftPhaseOffset: driftPhaseOffset,
    );

    setState(() => _entries.add(entry));

    controller
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) {
          if (!mounted) return;
          setState(() => _entries.remove(entry));
          controller.dispose();
        }
      })
      ..forward();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: Stack(
        children: [
          for (final entry in _entries)
            _FlyingEmoji(entry: entry),
        ],
      ),
    );
  }
}

/// Internal data holder for each floating emoji instance.
class _ReactionEntry {
  _ReactionEntry({
    required this.emoji,
    required this.controller,
    required this.startX,
    required this.driftAmplitude,
    required this.driftPhaseOffset,
  });

  final String emoji;
  final AnimationController controller;

  /// Horizontal start position as a fraction of the container width (0..1).
  final double startX;

  /// Amplitude of the sine-wave horizontal drift in logical pixels.
  final double driftAmplitude;

  /// Phase offset for the sine wave so each emoji drifts differently.
  final double driftPhaseOffset;
}

/// Animated widget for a single floating emoji.
class _FlyingEmoji extends AnimatedWidget {
  _FlyingEmoji({required this.entry}) : super(listenable: entry.controller);

  final _ReactionEntry entry;

  @override
  Widget build(BuildContext context) {
    final t = entry.controller.value; // 0 → 1
    final size = (context.findRenderObject() as RenderBox?)?.size;
    final containerW = size?.width ?? 120;
    final containerH = size?.height ?? 400;

    // Vertical: bottom → top
    final y = containerH * (1.0 - t) - 20; // start 20px above bottom

    // Horizontal: startX with sine drift
    final baseX = entry.startX * containerW;
    final drift = sin(t * 2 * pi + entry.driftPhaseOffset) * entry.driftAmplitude;
    final x = baseX + drift;

    // Fade: fully visible first 60%, then fade out
    final opacity = t < 0.6 ? 1.0 : (1.0 - (t - 0.6) / 0.4).clamp(0.0, 1.0);

    // Scale: 1.0 → 0.6
    final scale = 1.0 - 0.4 * t;

    return Positioned(
      left: x,
      top: y,
      child: Opacity(
        opacity: opacity,
        child: Transform.scale(
          scale: scale,
          child: Text(
            entry.emoji,
            style: const TextStyle(fontSize: 28),
          ),
        ),
      ),
    );
  }
}
