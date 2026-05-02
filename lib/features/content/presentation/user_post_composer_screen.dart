import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';

import '../data/content_repository.dart';

class UserPostComposerScreen extends ConsumerStatefulWidget {
  const UserPostComposerScreen({super.key, required this.kind});

  final String kind;

  @override
  ConsumerState<UserPostComposerScreen> createState() => _UserPostComposerScreenState();
}

class _UserPostComposerScreenState extends ConsumerState<UserPostComposerScreen> {
  final _titleController = TextEditingController();
  final _summaryController = TextEditingController();
  final _bodyController = TextEditingController();
  final _picker = ImagePicker();
  XFile? _selectedFile;
  bool _submitting = false;

  bool get _requiresMedia => widget.kind == 'audio' || widget.kind == 'image';

  @override
  void dispose() {
    _titleController.dispose();
    _summaryController.dispose();
    _bodyController.dispose();
    super.dispose();
  }

  Future<void> _pickMedia() async {
    XFile? file;
    if (widget.kind == 'image') {
      file = await _picker.pickImage(source: ImageSource.gallery);
    } else if (widget.kind == 'audio') {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['mp3', 'm4a', 'aac', 'wav', 'ogg'],
      );
      final files = result?.files;
      if (files != null && files.isNotEmpty && files.first.path != null) {
        file = XFile(files.first.path!, name: files.first.name);
      }
    }
    if (!mounted) return;
    setState(() {
      _selectedFile = file;
    });
  }

  Future<void> _submit() async {
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Title is required.')),
      );
      return;
    }
    if (_requiresMedia && _selectedFile == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a media file first.')),
      );
      return;
    }

    final repository = ref.read(contentRepositoryProvider);
    setState(() => _submitting = true);
    try {
      final postId = await repository.createUserPost(
        kind: widget.kind,
        title: title,
        summary: _summaryController.text,
        body: _bodyController.text,
      );
      if (_requiresMedia && _selectedFile != null) {
        await repository.uploadPostMedia(postId: postId, mediaFile: _selectedFile!);
      }
      ref.invalidate(userPostsProvider);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Post published.')),
      );
      Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to publish: $error')));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final kindLabel = widget.kind[0].toUpperCase() + widget.kind.substring(1);
    return Scaffold(
      appBar: AppBar(title: Text('$kindLabel Post')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _titleController,
            decoration: const InputDecoration(
              labelText: 'Title',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _summaryController,
            decoration: const InputDecoration(
              labelText: 'Summary',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _bodyController,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'Body',
              border: OutlineInputBorder(),
            ),
          ),
          if (_requiresMedia) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _submitting ? null : _pickMedia,
              icon: const Icon(Icons.attach_file_rounded),
              label: Text(
                _selectedFile == null ? 'Select file' : 'Selected: ${_selectedFile!.name}',
              ),
            ),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _submitting ? null : _submit,
            child: Text(_submitting ? 'Publishing...' : 'Publish'),
          ),
        ],
      ),
    );
  }
}

