import 'package:flutter_test/flutter_test.dart';
import 'package:talkflix_flutter/core/realtime/direct_call_readiness_controller.dart';

void main() {
  group('DirectCallReadinessState foreground calling', () {
    test(
      'allows foreground calls when only background registration is blocked',
      () {
        const blockers = <DirectCallReadinessBlocker>[
          DirectCallReadinessBlocker.deviceNotRegistered,
          DirectCallReadinessBlocker.backgroundUnavailable,
          DirectCallReadinessBlocker.pushHealthDegraded,
        ];

        for (final blocker in blockers) {
          final state = DirectCallReadinessState(
            supported: true,
            serverVerified: true,
            blocker: blocker,
          );

          expect(state.canUseDirectCalls, isFalse);
          expect(state.canUseForegroundDirectCalls, isTrue);
        }
      },
    );

    test('keeps hard blockers for foreground calls', () {
      const blockers = <DirectCallReadinessBlocker>[
        DirectCallReadinessBlocker.unsupportedPlatform,
        DirectCallReadinessBlocker.notAuthenticated,
        DirectCallReadinessBlocker.serverCheckPending,
        DirectCallReadinessBlocker.serverCheckFailed,
        DirectCallReadinessBlocker.relayUnavailable,
      ];

      for (final blocker in blockers) {
        final state = DirectCallReadinessState(
          supported: blocker != DirectCallReadinessBlocker.unsupportedPlatform,
          serverVerified:
              blocker != DirectCallReadinessBlocker.notAuthenticated &&
              blocker != DirectCallReadinessBlocker.serverCheckPending &&
              blocker != DirectCallReadinessBlocker.serverCheckFailed,
          blocker: blocker,
        );

        expect(state.canUseForegroundDirectCalls, isFalse);
      }
    });
  });
}
