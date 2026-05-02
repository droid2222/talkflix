import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import 'media_utils.dart';

class AudioMessagePlayer extends StatefulWidget {
  const AudioMessagePlayer({
    super.key,
    required this.source,
    required this.durationSeconds,
    this.mine = false,
    this.autoplayToken = 0,
    this.onPlaybackStarted,
    this.onPlaybackCompleted,
  });

  final String source;
  final int durationSeconds;
  final bool mine;
  final int autoplayToken;
  final VoidCallback? onPlaybackStarted;
  final VoidCallback? onPlaybackCompleted;

  @override
  State<AudioMessagePlayer> createState() => _AudioMessagePlayerState();
}

class _AudioMessagePlayerState extends State<AudioMessagePlayer> {
  final AudioPlayer _player = AudioPlayer();

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _loading = true;
  bool _playing = false;
  String? _localPath;
  int _lastAutoplayToken = 0;

  @override
  void initState() {
    super.initState();
    _lastAutoplayToken = widget.autoplayToken;
    _bindPlayer();
    _load();
  }

  @override
  void didUpdateWidget(covariant AudioMessagePlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) {
      _load();
    }
    if (widget.autoplayToken > _lastAutoplayToken) {
      _lastAutoplayToken = widget.autoplayToken;
      unawaited(_autoplayIfReady());
    }
  }

  void _bindPlayer() {
    _player.positionStream.listen((value) {
      if (!mounted) return;
      setState(() => _position = value);
    });
    _player.durationStream.listen((value) {
      if (!mounted || value == null) return;
      setState(() => _duration = value);
    });
    _player.playerStateStream.listen((state) {
      if (!mounted) return;
      setState(() {
        _playing = state.playing;
        if (state.processingState == ProcessingState.completed) {
          _position = Duration.zero;
          _playing = false;
          widget.onPlaybackCompleted?.call();
        }
      });
    });
  }

  Future<void> _load() async {
    final previousLocalPath = _localPath;
    _localPath = null;
    setState(() {
      _loading = true;
      _position = Duration.zero;
      _duration = Duration(seconds: widget.durationSeconds);
    });

    try {
      if (previousLocalPath != null) {
        final previousFile = File(previousLocalPath);
        unawaited(previousFile.delete().catchError((_) => previousFile));
      }
      if (widget.source.startsWith('data:')) {
        final bytes = tryDecodeDataUrl(widget.source);
        if (bytes == null) {
          throw StateError('Invalid audio data');
        }
        final tempDir = Directory.systemTemp;
        final file = File(
          '${tempDir.path}/voice_${DateTime.now().microsecondsSinceEpoch}_${identityHashCode(this)}.m4a',
        );
        await file.writeAsBytes(bytes, flush: true);
        _localPath = file.path;
        await _player.setFilePath(file.path);
      } else {
        await _player.setUrl(resolveMediaUrl(widget.source));
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
      });
      return;
    }

    if (!mounted) return;
    setState(() {
      _loading = false;
      _duration = _player.duration ?? Duration(seconds: widget.durationSeconds);
    });
    if (widget.autoplayToken > 0) {
      unawaited(_autoplayIfReady());
    }
  }

  Future<void> _autoplayIfReady() async {
    if (_loading) return;
    if (_player.playing) return;
    if (_player.processingState == ProcessingState.completed) {
      await _player.seek(Duration.zero);
    }
    widget.onPlaybackStarted?.call();
    await _player.play();
  }

  Future<void> _toggle() async {
    if (_loading) return;
    if (_player.playing) {
      await _player.pause();
      return;
    }
    if (_player.processingState == ProcessingState.completed) {
      await _player.seek(Duration.zero);
    }
    widget.onPlaybackStarted?.call();
    await _player.play();
  }

  @override
  void dispose() {
    _player.dispose();
    final localPath = _localPath;
    if (localPath != null) {
      unawaited(File(localPath).delete().catchError((_) => File(localPath)));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shownDuration = _duration.inMilliseconds > 0
        ? _duration
        : Duration(seconds: widget.durationSeconds);
    final progress = shownDuration.inMilliseconds == 0
        ? 0.0
        : (_position.inMilliseconds / shownDuration.inMilliseconds).clamp(
            0.0,
            1.0,
          );

    final surfaceColor = widget.mine
        ? Theme.of(
            context,
          ).colorScheme.onPrimaryContainer.withValues(alpha: 0.08)
        : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.06);

    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 220, maxWidth: 320),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: surfaceColor,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton.filledTonal(
                onPressed: _toggle,
                icon: Icon(
                  _loading
                      ? Icons.hourglass_empty_outlined
                      : _playing
                      ? Icons.pause
                      : Icons.play_arrow,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: 7,
                        backgroundColor: Colors.black12,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Text(
                          _formatDuration(_position),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const Spacer(),
                        Text(
                          _formatDuration(shownDuration),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDuration(Duration value) {
    final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}
