import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

import 'media_utils.dart';

enum SharedVideoSurface { inlinePreview, fullscreenPreview }

class SharedVideoPlayerLease {
  SharedVideoPlayerLease._(this._pool, this._entry);

  final SharedVideoPlayerPool _pool;
  final _PooledVideoEntry _entry;
  bool _released = false;

  VideoPlayerController? get controller => _entry.controller;

  bool get isInitialized => _entry.controller?.value.isInitialized ?? false;

  Future<VideoPlayerController> ensureInitialized() {
    return _entry.ensureInitialized();
  }

  void release() {
    if (_released) return;
    _released = true;
    _pool._release(_entry.key);
  }
}

class SharedVideoPlayerPool {
  SharedVideoPlayerPool._();

  static final SharedVideoPlayerPool instance = SharedVideoPlayerPool._();

  static const Duration _idleTtl = Duration(minutes: 2);
  static const int _maxEntries = 8;

  final Map<String, _PooledVideoEntry> _entries = <String, _PooledVideoEntry>{};

  Future<SharedVideoPlayerLease> acquire({
    required String source,
    required SharedVideoSurface surface,
    bool looping = true,
    double initialVolume = 0,
  }) async {
    final resolvedUrl = resolveMediaUrl(source);
    final key = '${surface.name}::$resolvedUrl';
    final entry = _entries.putIfAbsent(
      key,
      () => _PooledVideoEntry(
        key: key,
        uri: Uri.parse(resolvedUrl),
        looping: looping,
        initialVolume: initialVolume,
      ),
    );
    entry.retain();
    _trimIdleEntries();
    return SharedVideoPlayerLease._(this, entry);
  }

  void _release(String key) {
    final entry = _entries[key];
    if (entry == null) return;
    entry.release(idleTtl: _idleTtl, onExpire: () => _disposeEntry(key, entry));
    _trimIdleEntries();
  }

  void _disposeEntry(String key, _PooledVideoEntry entry) {
    if (_entries[key] != entry || entry.refCount > 0) return;
    _entries.remove(key);
    unawaited(entry.disposeNow());
  }

  void _trimIdleEntries() {
    if (_entries.length <= _maxEntries) return;
    final idleEntries =
        _entries.values
            .where((entry) => entry.refCount == 0)
            .toList(growable: false)
          ..sort((a, b) => a.lastReleasedAt.compareTo(b.lastReleasedAt));
    for (final entry in idleEntries) {
      if (_entries.length <= _maxEntries) break;
      _disposeEntry(entry.key, entry);
    }
  }
}

class _PooledVideoEntry {
  _PooledVideoEntry({
    required this.key,
    required this.uri,
    required this.looping,
    required this.initialVolume,
  });

  final String key;
  final Uri uri;
  final bool looping;
  final double initialVolume;

  VideoPlayerController? controller;
  Future<VideoPlayerController>? _initializeFuture;
  Timer? _disposeTimer;
  int refCount = 0;
  DateTime lastReleasedAt = DateTime.now();

  void retain() {
    refCount += 1;
    _disposeTimer?.cancel();
    _disposeTimer = null;
  }

  void release({required Duration idleTtl, required VoidCallback onExpire}) {
    if (refCount > 0) {
      refCount -= 1;
    }
    if (refCount != 0) return;
    lastReleasedAt = DateTime.now();
    final current = controller;
    if (current != null && current.value.isInitialized) {
      unawaited(current.pause());
    }
    _disposeTimer?.cancel();
    _disposeTimer = Timer(idleTtl, onExpire);
  }

  Future<VideoPlayerController> ensureInitialized() async {
    final current = controller;
    if (current != null && current.value.isInitialized) {
      return current;
    }
    final pending = _initializeFuture;
    if (pending != null) {
      return pending;
    }
    final future = _createAndInitialize();
    _initializeFuture = future;
    try {
      return await future;
    } finally {
      _initializeFuture = null;
    }
  }

  Future<VideoPlayerController> _createAndInitialize() async {
    final stale = controller;
    controller = null;
    if (stale != null) {
      await stale.dispose();
    }
    final next = VideoPlayerController.networkUrl(uri);
    try {
      await next.initialize();
      await next.setLooping(looping);
      await next.setVolume(initialVolume);
      controller = next;
      return next;
    } catch (_) {
      await next.dispose();
      rethrow;
    }
  }

  Future<void> disposeNow() async {
    _disposeTimer?.cancel();
    _disposeTimer = null;
    final current = controller;
    controller = null;
    if (current != null) {
      await current.dispose();
    }
  }
}
