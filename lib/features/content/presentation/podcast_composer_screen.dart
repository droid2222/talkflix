// ignore_for_file: use_build_context_synchronously
import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:just_audio/just_audio.dart';
import 'package:record/record.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/media/media_permission_service.dart';
import '../../../core/network/api_exception.dart';
import '../data/content_repository.dart';

class PodcastComposerScreen extends ConsumerStatefulWidget {
  const PodcastComposerScreen({super.key});

  @override
  ConsumerState<PodcastComposerScreen> createState() =>
      _PodcastComposerScreenState();
}

class _PodcastComposerScreenState extends ConsumerState<PodcastComposerScreen> {
  final _titleController = TextEditingController();
  final _summaryController = TextEditingController();
  final _picker = ImagePicker();
  final _audioRecorder = AudioRecorder();
  final _audioPlayer = AudioPlayer();
  final _permissionService = MediaPermissionService();

  XFile? _coverFile;
  XFile? _audioFile;
  bool _recording = false;
  bool _audioPlaying = false;
  bool _submitting = false;
  int _recordedSeconds = 0;
  Timer? _recordingTimer;
  StreamSubscription<PlayerState>? _playerStateSub;

  bool get _canPublish =>
      _titleController.text.trim().isNotEmpty &&
      _summaryController.text.trim().isNotEmpty &&
      _coverFile != null &&
      _audioFile != null;

  @override
  void initState() {
    super.initState();
    _titleController.addListener(() => setState(() {}));
    _summaryController.addListener(() => setState(() {}));
    _playerStateSub = _audioPlayer.playerStateStream.listen((state) {
      if (!mounted) return;
      if (state.processingState == ProcessingState.completed) {
        setState(() => _audioPlaying = false);
      } else {
        setState(() => _audioPlaying = state.playing);
      }
    });
  }

  @override
  void dispose() {
    _recordingTimer?.cancel();
    _playerStateSub?.cancel();
    _titleController.dispose();
    _summaryController.dispose();
    _audioRecorder.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }

  Future<void> _pickCover() async {
    final picked = await _picker.pickImage(source: ImageSource.gallery);
    if (!mounted || picked == null) return;
    setState(() => _coverFile = picked);
  }

  Future<void> _pickAudioFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['mp3', 'm4a', 'aac', 'wav', 'ogg', 'flac'],
    );
    final files = result?.files;
    if (!mounted ||
        files == null ||
        files.isEmpty ||
        files.first.path == null) {
      return;
    }
    await _audioPlayer.stop();
    setState(() {
      _audioPlaying = false;
      _audioFile = XFile(files.first.path!, name: files.first.name);
    });
  }

  Future<void> _startRecording() async {
    final ok = await _permissionService.ensureMicrophone();
    if (!ok || !mounted) return;
    final hasPerms = await _audioRecorder.hasPermission();
    if (!hasPerms || !mounted) return;
    final path =
        '${Directory.systemTemp.path}/talkflix_podcast_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _audioRecorder.start(
      const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 128000),
      path: path,
    );
    setState(() {
      _recording = true;
      _recordedSeconds = 0;
      _audioFile = null;
      _audioPlaying = false;
    });
    _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _recordedSeconds++);
    });
  }

  Future<void> _stopRecording() async {
    _recordingTimer?.cancel();
    final path = await _audioRecorder.stop();
    if (!mounted) return;
    setState(() {
      _recording = false;
      _audioFile = path == null ? null : XFile(path);
    });
  }

  Future<void> _toggleAudioPlayback() async {
    final file = _audioFile;
    if (file == null) return;
    if (_audioPlaying) {
      await _audioPlayer.pause();
      return;
    }
    await _audioPlayer.setFilePath(file.path);
    await _audioPlayer.seek(Duration.zero);
    unawaited(_audioPlayer.play());
  }

  Future<void> _clearAudio() async {
    await _audioPlayer.stop();
    setState(() {
      _audioPlaying = false;
      _recording = false;
      _recordedSeconds = 0;
      _audioFile = null;
    });
  }

  Future<void> _publish() async {
    if (!_canPublish ||
        _submitting ||
        _coverFile == null ||
        _audioFile == null) {
      return;
    }
    unawaited(HapticFeedback.mediumImpact());
    setState(() => _submitting = true);
    try {
      final repo = ref.read(contentRepositoryProvider);
      final podcastId = await repo.createPodcastDraft(
        title: _titleController.text.trim(),
        summary: _summaryController.text.trim(),
      );
      await repo.uploadPodcastCover(
        contentId: podcastId,
        coverFile: _coverFile!,
      );
      await repo.uploadPodcastAudio(
        contentId: podcastId,
        audioFile: _audioFile!,
      );
      await repo.publishPodcast(podcastId);
      ref.invalidate(podcastEpisodesProvider);
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Podcast published.')));
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(userFriendlyMessage(e))));
    } catch (e) {
      if (!mounted) return;
      final message = e.toString().replaceFirst('Exception: ', '').trim();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            message.isEmpty ? 'Could not publish the podcast.' : message,
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('New Podcast'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: _submitting
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  )
                : FilledButton(
                    onPressed: _canPublish ? _publish : null,
                    style: FilledButton.styleFrom(
                      backgroundColor: talkflixPrimary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                    ),
                    child: const Text('Publish'),
                  ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          TextField(
            controller: _titleController,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Podcast title',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _summaryController,
            maxLines: 3,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Short description',
              helperText:
                  'Give listeners a quick idea of what this episode is about.',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 18),
          Text(
            'Cover photo',
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          InkWell(
            borderRadius: BorderRadius.circular(24),
            onTap: _submitting ? null : _pickCover,
            child: Ink(
              height: 190,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: _coverFile == null
                  ? Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(
                          Icons.add_photo_alternate_outlined,
                          size: 34,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Choose cover image',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                      ],
                    )
                  : ClipRRect(
                      borderRadius: BorderRadius.circular(24),
                      child: Image.file(
                        File(_coverFile!.path),
                        fit: BoxFit.cover,
                        width: double.infinity,
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 18),
          Text(
            'Episode audio',
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    FilledButton.icon(
                      onPressed: _submitting || _recording
                          ? null
                          : _pickAudioFile,
                      icon: const Icon(Icons.attach_file_rounded),
                      label: const Text('Attach audio'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _submitting
                          ? null
                          : (_recording ? _stopRecording : _startRecording),
                      icon: Icon(
                        _recording
                            ? Icons.stop_circle_outlined
                            : Icons.mic_none_rounded,
                      ),
                      label: Text(_recording ? 'Stop recording' : 'Record now'),
                    ),
                  ],
                ),
                if (_recording) ...[
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      const Icon(
                        Icons.fiber_manual_record_rounded,
                        color: Colors.red,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Recording ${_formatDuration(_recordedSeconds)}',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ],
                if (_audioFile != null && !_recording) ...[
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: scheme.surface,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Row(
                      children: [
                        IconButton.filledTonal(
                          onPressed: _toggleAudioPlayback,
                          icon: Icon(
                            _audioPlaying
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _audioFile!.name.isEmpty
                                    ? _audioFile!.path.split('/').last
                                    : _audioFile!.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleSmall
                                    ?.copyWith(fontWeight: FontWeight.w800),
                              ),
                              Text(
                                'Long-form podcast audio',
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(color: scheme.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          onPressed: _clearAudio,
                          icon: const Icon(Icons.delete_outline_rounded),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatDuration(int totalSeconds) {
    final duration = Duration(seconds: totalSeconds);
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (hours > 0) {
      return '$hours:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }
}
