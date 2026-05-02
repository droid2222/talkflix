import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../data/content_repository.dart';

class CreatorStudioScreen extends ConsumerStatefulWidget {
  const CreatorStudioScreen({super.key});

  @override
  ConsumerState<CreatorStudioScreen> createState() => _CreatorStudioScreenState();
}

class _CreatorStudioScreenState extends ConsumerState<CreatorStudioScreen> {
  final _titleController = TextEditingController();
  final _summaryController = TextEditingController();
  final _localeController = TextEditingController(text: 'en');
  final _translationsController = TextEditingController(text: 'es,fr');
  final _picker = ImagePicker();

  XFile? _selectedVideo;
  bool _submitting = false;
  String _status = 'Fill details and pick a video file.';

  @override
  void dispose() {
    _titleController.dispose();
    _summaryController.dispose();
    _localeController.dispose();
    _translationsController.dispose();
    super.dispose();
  }

  List<String> _parseTargets(String raw) {
    return raw
        .split(',')
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toSet()
        .take(5)
        .toList();
  }

  Future<void> _pickVideo() async {
    final picked = await _picker.pickVideo(source: ImageSource.gallery);
    if (!mounted) return;
    setState(() {
      _selectedVideo = picked;
      if (picked != null) {
        _status = 'Selected video: ${picked.name}';
      }
    });
  }

  Future<void> _publish() async {
    final video = _selectedVideo;
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Title is required.')),
      );
      return;
    }
    if (video == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Please pick a video first.')));
      return;
    }

    final repository = ref.read(contentRepositoryProvider);
    setState(() {
      _submitting = true;
      _status = 'Creating draft...';
    });
    try {
      final draft = await repository.createVideoDraft(
        title: title,
        summary: _summaryController.text.trim(),
        sourceLocale: _localeController.text.trim().isEmpty
            ? 'und'
            : _localeController.text.trim(),
        translationTargets: _parseTargets(_translationsController.text),
      );

      if (!mounted) return;
      setState(() {
        _status = 'Uploading video file...';
      });
      await repository.uploadVideoFile(contentId: draft.id, videoFile: video);

      if (!mounted) return;
      setState(() {
        _status = 'Publishing video...';
      });
      await repository.publishVideo(draft.id);

      ref.invalidate(publishedVideosProvider);
      if (!mounted) return;
      setState(() {
        _status = 'Published successfully.';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Video published successfully.')),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _status = 'Failed: $error';
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Publish failed: $error')));
    } finally {
      if (mounted) {
        setState(() {
          _submitting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Creator Studio')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _titleController,
            decoration: const InputDecoration(
              labelText: 'Video title',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _summaryController,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Summary',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _localeController,
                  decoration: const InputDecoration(
                    labelText: 'Source locale (e.g. en)',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _translationsController,
                  decoration: const InputDecoration(
                    labelText: 'Translations (comma-separated)',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: _submitting ? null : _pickVideo,
            icon: const Icon(Icons.video_library_outlined),
            label: Text(
              _selectedVideo == null ? 'Pick Video' : 'Change Video (${_selectedVideo!.name})',
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _submitting ? null : _publish,
            icon: _submitting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.publish_rounded),
            label: Text(_submitting ? 'Publishing...' : 'Create, Upload, Publish'),
          ),
          const SizedBox(height: 12),
          Text(_status),
        ],
      ),
    );
  }
}

