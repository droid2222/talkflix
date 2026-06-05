import 'package:flutter/foundation.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';

final class NotificationSoundPlayer {
  NotificationSoundPlayer._();

  static final FlutterRingtonePlayer _player = FlutterRingtonePlayer();

  static Future<void> play() async {
    if (kIsWeb) return;
    try {
      await _player.playNotification(looping: false, asAlarm: false);
    } catch (_) {}
  }
}
