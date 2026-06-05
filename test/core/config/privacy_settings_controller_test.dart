import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:talkflix_flutter/core/config/privacy_settings_controller.dart';

void main() {
  group('PrivacySettingsController direct call preferences', () {
    test('defaults voice and video receiving to enabled', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(privacySettingsControllerProvider.notifier);
      await Future<void>.delayed(Duration.zero);

      final state = container.read(privacySettingsControllerProvider);
      expect(state.receiveVoiceCalls, isTrue);
      expect(state.receiveVideoCalls, isTrue);
      expect(state.showOnlineStatus, isTrue);
    });

    test('persists the online status visibility toggle', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(
        privacySettingsControllerProvider.notifier,
      );
      await Future<void>.delayed(Duration.zero);

      await notifier.setShowOnlineStatus(false);

      expect(
        container.read(privacySettingsControllerProvider).showOnlineStatus,
        isFalse,
      );
    });

    test('persists the age visibility toggle', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(
        privacySettingsControllerProvider.notifier,
      );
      await Future<void>.delayed(Duration.zero);

      await notifier.setShowAge(true);

      expect(container.read(privacySettingsControllerProvider).showAge, isTrue);
    });

    test('respects the global call toggles', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(
        privacySettingsControllerProvider.notifier,
      );
      await Future<void>.delayed(Duration.zero);

      await notifier.setReceiveVoiceCalls(true);
      await notifier.setReceiveVideoCalls(true);

      expect(
        await notifier.canReceiveDirectChatCall(userId: 'user-1', video: false),
        isTrue,
      );
      expect(
        await notifier.canReceiveDirectChatCall(userId: 'user-1', video: true),
        isTrue,
      );
      await notifier.setReceiveVoiceCalls(false);
      await notifier.setReceiveVideoCalls(false);
      expect(
        await notifier.canReceiveDirectChatCall(userId: 'user-1', video: false),
        isFalse,
      );
      expect(
        await notifier.canReceiveDirectChatCall(userId: 'user-1', video: true),
        isFalse,
      );
    });
  });
}
