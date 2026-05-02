import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

final webRtcServiceProvider = Provider<WebRtcService>((ref) {
  final service = WebRtcService();
  ref.onDispose(service.disposeLocalStream);
  return service;
});

class WebRtcService {
  MediaStream? _localStream;

  MediaStream? get localStream => _localStream;

  bool get hasAudioTrack => (_localStream?.getAudioTracks().isNotEmpty ?? false);

  bool get hasVideoTrack => (_localStream?.getVideoTracks().isNotEmpty ?? false);

  bool get isMicrophoneEnabled =>
      _localStream?.getAudioTracks().any((track) => track.enabled) ?? false;

  bool get isCameraEnabled =>
      _localStream?.getVideoTracks().any((track) => track.enabled) ?? false;

  Future<MediaStream> createLocalStream({
    required bool audio,
    required bool video,
    String facingMode = 'user',
  }) async {
    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': audio,
      'video': video ? {'facingMode': facingMode} : false,
    });
    return _localStream!;
  }

  Future<void> disposeLocalStream() async {
    final stream = _localStream;
    _localStream = null;
    for (final track in stream?.getTracks() ?? const <MediaStreamTrack>[]) {
      await track.stop();
    }
    await stream?.dispose();
  }

  Future<bool> switchCamera() async {
    final stream = _localStream;
    if (stream == null) return false;
    final videoTracks = stream.getVideoTracks();
    if (videoTracks.isEmpty) return false;
    await Helper.switchCamera(videoTracks.first);
    return true;
  }

  bool toggleMicrophone() {
    final stream = _localStream;
    if (stream == null) return false;
    final audioTracks = stream.getAudioTracks();
    if (audioTracks.isEmpty) return false;
    final track = audioTracks.first;
    track.enabled = !track.enabled;
    return track.enabled;
  }

  bool toggleCamera() {
    final stream = _localStream;
    if (stream == null) return false;
    final videoTracks = stream.getVideoTracks();
    if (videoTracks.isEmpty) return false;
    final track = videoTracks.first;
    track.enabled = !track.enabled;
    return track.enabled;
  }
}
