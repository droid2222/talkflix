import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/session_controller.dart';
import 'direct_call_backend_service.dart';
import 'direct_call_registration_controller.dart';

final directCallServerReadinessProvider =
    FutureProvider<DirectCallServerReadiness?>((ref) async {
      final session = ref.watch(sessionControllerProvider);
      if (!session.isAuthenticated || session.user == null) {
        return null;
      }
      return ref.read(directCallBackendServiceProvider).fetchReadiness();
    });

final directCallReadinessProvider = Provider<DirectCallReadinessState>((ref) {
  final session = ref.watch(sessionControllerProvider);
  final registration = ref.watch(directCallRegistrationControllerProvider);
  final serverReadiness = ref.watch(directCallServerReadinessProvider);

  if (kIsWeb || !registration.supported) {
    return const DirectCallReadinessState(
      supported: false,
      serverVerified: true,
      blocker: DirectCallReadinessBlocker.unsupportedPlatform,
    );
  }

  if (!session.isAuthenticated || session.user == null) {
    return const DirectCallReadinessState(
      supported: true,
      serverVerified: false,
      blocker: DirectCallReadinessBlocker.notAuthenticated,
    );
  }

  final readiness = serverReadiness.valueOrNull;
  if (serverReadiness.hasError) {
    return DirectCallReadinessState(
      supported: true,
      serverVerified: false,
      registration: registration,
      blocker: DirectCallReadinessBlocker.serverCheckFailed,
    );
  }

  if (serverReadiness.isLoading || readiness == null) {
    return DirectCallReadinessState(
      supported: true,
      loading: true,
      serverVerified: false,
      registration: registration,
      blocker: DirectCallReadinessBlocker.serverCheckPending,
    );
  }

  if (readiness.relayRequired && !readiness.hasRelay) {
    return DirectCallReadinessState(
      supported: true,
      serverVerified: true,
      registration: registration,
      relayRequired: true,
      relayAvailable: false,
      serverSummary: readiness.deviceSummary,
      blocker: DirectCallReadinessBlocker.relayUnavailable,
    );
  }

  if (!registration.registeredForCurrentToken) {
    return DirectCallReadinessState(
      supported: true,
      serverVerified: true,
      registration: registration,
      relayRequired: readiness.relayRequired,
      relayAvailable: readiness.hasRelay,
      serverSummary: readiness.deviceSummary,
      blocker: DirectCallReadinessBlocker.deviceNotRegistered,
    );
  }

  if (!registration.backgroundCallable) {
    return DirectCallReadinessState(
      supported: true,
      serverVerified: true,
      registration: registration,
      relayRequired: readiness.relayRequired,
      relayAvailable: readiness.hasRelay,
      serverSummary: readiness.deviceSummary,
      blocker: DirectCallReadinessBlocker.backgroundUnavailable,
    );
  }

  final currentDevice = registration.currentDevice;
  if (currentDevice != null && currentDevice.consecutiveFailures >= 3) {
    return DirectCallReadinessState(
      supported: true,
      serverVerified: true,
      registration: registration,
      relayRequired: readiness.relayRequired,
      relayAvailable: readiness.hasRelay,
      serverSummary: readiness.deviceSummary,
      blocker: DirectCallReadinessBlocker.pushHealthDegraded,
    );
  }

  return DirectCallReadinessState(
    supported: true,
    serverVerified: true,
    registration: registration,
    relayRequired: readiness.relayRequired,
    relayAvailable: readiness.hasRelay,
    serverSummary: readiness.deviceSummary,
  );
});

enum DirectCallReadinessBlocker {
  unsupportedPlatform,
  notAuthenticated,
  serverCheckPending,
  serverCheckFailed,
  relayUnavailable,
  deviceNotRegistered,
  backgroundUnavailable,
  pushHealthDegraded,
}

class DirectCallReadinessState {
  const DirectCallReadinessState({
    required this.supported,
    required this.serverVerified,
    this.loading = false,
    this.registration = const DirectCallRegistrationState(
      supported: false,
      platform: '',
      expectedPushProvider: '',
    ),
    this.relayRequired = true,
    this.relayAvailable = false,
    this.serverSummary = const DirectCallDeviceSummary(),
    this.blocker,
  });

  final bool supported;
  final bool serverVerified;
  final bool loading;
  final DirectCallRegistrationState registration;
  final bool relayRequired;
  final bool relayAvailable;
  final DirectCallDeviceSummary serverSummary;
  final DirectCallReadinessBlocker? blocker;

  bool get canUseDirectCalls => supported && serverVerified && blocker == null;
  bool get canUseForegroundDirectCalls {
    if (!supported || !serverVerified) return false;
    switch (blocker) {
      case null:
      case DirectCallReadinessBlocker.deviceNotRegistered:
      case DirectCallReadinessBlocker.backgroundUnavailable:
      case DirectCallReadinessBlocker.pushHealthDegraded:
        return true;
      case DirectCallReadinessBlocker.unsupportedPlatform:
      case DirectCallReadinessBlocker.notAuthenticated:
      case DirectCallReadinessBlocker.serverCheckPending:
      case DirectCallReadinessBlocker.serverCheckFailed:
      case DirectCallReadinessBlocker.relayUnavailable:
        return false;
    }
  }

  String get userMessage {
    switch (blocker) {
      case DirectCallReadinessBlocker.unsupportedPlatform:
        return 'Direct calling is unavailable on this platform.';
      case DirectCallReadinessBlocker.notAuthenticated:
        return 'Sign in again before using direct calls.';
      case DirectCallReadinessBlocker.serverCheckPending:
        return 'Checking direct-call readiness. Try again in a moment.';
      case DirectCallReadinessBlocker.serverCheckFailed:
        return 'Direct calling is temporarily unavailable right now.';
      case DirectCallReadinessBlocker.relayUnavailable:
        return 'Direct calling is unavailable until relay transport is configured.';
      case DirectCallReadinessBlocker.deviceNotRegistered:
        return 'This device is not registered for direct calls yet.';
      case DirectCallReadinessBlocker.backgroundUnavailable:
        return 'This device is not ready to receive direct calls in the background.';
      case DirectCallReadinessBlocker.pushHealthDegraded:
        return 'Direct calling is paused on this device until call delivery recovers.';
      case null:
        return 'Direct calling is ready.';
    }
  }

  String get foregroundUserMessage {
    if (canUseForegroundDirectCalls) return 'Direct calling is ready.';
    return userMessage;
  }
}
