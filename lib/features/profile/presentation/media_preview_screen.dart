import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../../core/media/media_permission_service.dart';
import '../../../core/realtime/webrtc_service.dart';

class MediaPreviewScreen extends ConsumerStatefulWidget {
  const MediaPreviewScreen({super.key});

  @override
  ConsumerState<MediaPreviewScreen> createState() => _MediaPreviewScreenState();
}

class _MediaPreviewScreenState extends ConsumerState<MediaPreviewScreen> {
  final _permissionService = MediaPermissionService();
  final _renderer = RTCVideoRenderer();
  bool _loading = true;
  bool _microphoneEnabled = false;
  bool _cameraEnabled = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    Future<void>.microtask(_loadPreview);
  }

  Future<void> _loadPreview() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final allowed = await _permissionService.ensureCameraAndMicrophone();
      if (!allowed) {
        throw Exception('Camera and microphone permissions are required.');
      }
      await _renderer.initialize();
      final webRtc = ref.read(webRtcServiceProvider);
      await webRtc.disposeLocalStream();
      final stream = await webRtc.createLocalStream(audio: true, video: true);
      _renderer.srcObject = stream;
      _microphoneEnabled = webRtc.isMicrophoneEnabled;
      _cameraEnabled = webRtc.isCameraEnabled;
    } catch (error) {
      _error = error.toString();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _switchCamera() async {
    final switched = await ref.read(webRtcServiceProvider).switchCamera();
    if (!switched || !mounted) return;
    setState(() {});
  }

  void _toggleMicrophone() {
    final enabled = ref.read(webRtcServiceProvider).toggleMicrophone();
    setState(() => _microphoneEnabled = enabled);
  }

  void _toggleCamera() {
    final enabled = ref.read(webRtcServiceProvider).toggleCamera();
    setState(() => _cameraEnabled = enabled);
  }

  @override
  void dispose() {
    _renderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Local media preview'),
        actions: [
          IconButton(
            onPressed: _loading ? null : _loadPreview,
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Restart preview',
          ),
          IconButton(
            onPressed: _loading || _error != null ? null : _toggleMicrophone,
            icon: Icon(
              _microphoneEnabled ? Icons.mic_rounded : Icons.mic_off_rounded,
            ),
            tooltip: _microphoneEnabled ? 'Mute microphone' : 'Unmute microphone',
          ),
          IconButton(
            onPressed: _loading || _error != null ? null : _toggleCamera,
            icon: Icon(
              _cameraEnabled
                  ? Icons.videocam_rounded
                  : Icons.videocam_off_rounded,
            ),
            tooltip: _cameraEnabled ? 'Stop camera' : 'Start camera',
          ),
          IconButton(
            onPressed: _loading || _error != null ? null : _switchCamera,
            icon: const Icon(Icons.cameraswitch_outlined),
            tooltip: 'Switch camera',
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: _loading
              ? const CircularProgressIndicator()
              : _error != null
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _loadPreview,
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('Retry preview'),
                    ),
                  ],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        _StatusChip(
                          label: 'Microphone',
                          value: _microphoneEnabled ? 'On' : 'Off',
                          icon: _microphoneEnabled
                              ? Icons.mic_rounded
                              : Icons.mic_off_rounded,
                        ),
                        _StatusChip(
                          label: 'Camera',
                          value: _cameraEnabled ? 'On' : 'Off',
                          icon: _cameraEnabled
                              ? Icons.videocam_rounded
                              : Icons.videocam_off_rounded,
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    AspectRatio(
                      aspectRatio: 9 / 16,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(20),
                        child: RTCVideoView(_renderer, mirror: true),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Use this preview to verify permissions, local mic/camera state, camera switching, and preview restart before testing calls or live rooms.',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.label,
    required this.value,
    required this.icon,
  });

  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Icon(icon, size: 18),
      label: Text('$label: $value'),
    );
  }
}
