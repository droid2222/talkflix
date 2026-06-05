import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';

/// Incoming direct-message call audio.
///
/// On **Android**, uses the user’s **default device ringtone**, looping until
/// [stop].
///
/// On **iOS**, uses **system sounds** via `AudioServicesPlaySystemSound` (the
/// same mechanism `flutter_ringtone_player` uses for [FlutterRingtonePlayer.playRingtone],
/// mapped to `IosSounds.electronic`). Each ping is short, so we **re-fire** it on
/// a timer until [stop] — similar in spirit to repeating alert tones. WhatsApp’s
/// full-screen incoming **VoIP** UI uses **CallKit** plus push; that is separate
/// from in-app tone playback and would be the path to match the Phone app exactly.
final class DmIncomingRingtone {
  DmIncomingRingtone._();

  static final FlutterRingtonePlayer _player = FlutterRingtonePlayer();
  static Timer? _iosRingTimer;
  static bool _androidRingActive = false;

  /// Spacing between iOS system-sound pings (~default ring cadence).
  static const _iosRingPulse = Duration(milliseconds: 2700);

  static Future<void> _iosPing() async {
    try {
      await _player.playRingtone(looping: false, asAlarm: false);
    } catch (_) {}
  }

  static Future<void> start() async {
    if (kIsWeb) return;
    await stop();
    if (Platform.isAndroid) {
      _androidRingActive = true;
      try {
        await _player.playRingtone(looping: true, asAlarm: false);
      } catch (_) {
        _androidRingActive = false;
      }
      return;
    }
    if (Platform.isIOS) {
      await _iosPing();
      _iosRingTimer?.cancel();
      _iosRingTimer = Timer.periodic(_iosRingPulse, (_) {
        unawaited(_iosPing());
      });
    }
  }

  static Future<void> stop() async {
    if (kIsWeb) return;
    _iosRingTimer?.cancel();
    _iosRingTimer = null;
    if (Platform.isAndroid && _androidRingActive) {
      try {
        await _player.stop();
      } catch (_) {}
      _androidRingActive = false;
    }
  }
}
