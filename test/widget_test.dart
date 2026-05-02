// ignore_for_file: prefer_const_constructors

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:talkflix_flutter/core/auth/app_user.dart';
import 'package:talkflix_flutter/core/auth/session_controller.dart';
import 'package:talkflix_flutter/core/auth/session_state.dart';
import 'package:talkflix_flutter/core/network/api_client.dart';
import 'package:talkflix_flutter/core/realtime/socket_service.dart';
import 'package:talkflix_flutter/core/widgets/feature_scaffold.dart';
import 'package:talkflix_flutter/core/widgets/realtime_status_banner.dart';
import 'package:talkflix_flutter/core/widgets/realtime_warning_banner.dart';
import 'package:talkflix_flutter/core/widgets/session_status_bar.dart';
import 'package:talkflix_flutter/core/widgets/status_pill.dart';
import 'package:talkflix_flutter/features/profile/presentation/diagnostics_screen.dart';
import 'package:talkflix_flutter/features/profile/presentation/qa_checklist_data.dart';
import 'package:talkflix_flutter/features/profile/presentation/qa_checklist_screen.dart';
import 'package:talkflix_flutter/features/profile/presentation/profile_screen.dart';

void main() {
  testWidgets('realtime banner stays hidden while connected by default', (
    tester,
  ) async {
    final socket = _FakeSocketService(status: 'connected', connected: true);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [socketServiceProvider.overrideWith((ref) => socket)],
        child: const MaterialApp(
          home: Scaffold(
            body: RealtimeStatusBanner(compactLabel: 'Chat service'),
          ),
        ),
      ),
    );

    expect(find.text('Chat service connected'), findsNothing);
    expect(find.text('Details'), findsNothing);
  });

  testWidgets('realtime banner shows offline state and details action', (
    tester,
  ) async {
    final socket = _FakeSocketService(status: 'disconnected');

    await tester.pumpWidget(
      ProviderScope(
        overrides: [socketServiceProvider.overrideWith((ref) => socket)],
        child: const MaterialApp(
          home: Scaffold(
            body: RealtimeStatusBanner(compactLabel: 'Chat service'),
          ),
        ),
      ),
    );

    expect(find.text('Chat service offline'), findsOneWidget);
    expect(find.text('Details'), findsOneWidget);
  });

  testWidgets('feature scaffold adds pull-to-refresh only when provided', (
    tester,
  ) async {
    var refreshed = false;

    await tester.pumpWidget(
      MaterialApp(
        home: FeatureScaffold(
          title: 'Test',
          onRefresh: () async {
            refreshed = true;
          },
          children: const [Text('Body')],
        ),
      ),
    );

    expect(find.byType(RefreshIndicator), findsOneWidget);

    await tester.fling(find.text('Body'), const Offset(0, 300), 1000);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(refreshed, isTrue);
  });

  testWidgets('status pill renders shared QA chip text', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(child: StatusPill(text: 'Socket: connected')),
        ),
      ),
    );

    expect(find.text('Socket: connected'), findsOneWidget);
  });

  testWidgets('realtime warning banner renders scoped disconnect copy', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: RealtimeWarningBanner(
            status: 'disconnected',
            scopeLabel: 'Chat',
          ),
        ),
      ),
    );

    expect(
      find.text('Chat disconnected. Trying to recover...'),
      findsOneWidget,
    );
  });

  testWidgets('session status bar renders items and actions together', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SessionStatusBar(
            items: [
              SessionStatusItem(label: 'Socket', value: 'connected'),
              SessionStatusItem(label: 'Partner', value: 'Online'),
            ],
            actions: [Text('Reconnect')],
          ),
        ),
      ),
    );

    expect(find.text('Socket: connected'), findsOneWidget);
    expect(find.text('Partner: Online'), findsOneWidget);
    expect(find.text('Reconnect'), findsOneWidget);
  });

  testWidgets('diagnostics screen shows session and socket details', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final socket = _FakeSocketService(status: 'connecting');
    final session = _FakeSessionController(_authenticatedState);
    final apiClient = _FakeApiClient(response: {'ok': true, 'db': true});

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          socketServiceProvider.overrideWith((ref) => socket),
          sessionControllerProvider.overrideWith((ref) => session),
          apiClientProvider.overrideWith((ref) => apiClient),
        ],
        child: const MaterialApp(home: DiagnosticsScreen()),
      ),
    );

    expect(find.text('Diagnostics'), findsOneWidget);
    expect(find.text('Session status'), findsOneWidget);
    expect(find.text('authenticated'), findsOneWidget);
    expect(find.text('Socket status'), findsOneWidget);
    expect(find.text('connecting'), findsOneWidget);
    expect(find.text('Test User'), findsOneWidget);
    expect(find.text('user-1'), findsOneWidget);
    expect(find.text('pro'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Copy API URL'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('Reconnect socket'), findsOneWidget);
    expect(find.text('Copy user ID'), findsOneWidget);
    expect(find.text('Copy API URL'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Open Talk'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Checklist progress: 0/$qaChecklistTotalItems'),
      findsOneWidget,
    );
    expect(
      find.text(
        'Open media preview before call or live-room testing to verify permissions, local preview, and camera switching.',
      ),
      findsOneWidget,
    );
    expect(find.text('Open QA checklist'), findsOneWidget);
    expect(find.text('Open media preview'), findsOneWidget);
    expect(find.text('Open Talk'), findsOneWidget);
    expect(find.text('Open Anonymous'), findsOneWidget);
  });

  testWidgets('diagnostics health check renders success message', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final socket = _FakeSocketService(status: 'connected', connected: true);
    final session = _FakeSessionController(_authenticatedState);
    final apiClient = _FakeApiClient(response: {'ok': true, 'db': true});

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          socketServiceProvider.overrideWith((ref) => socket),
          sessionControllerProvider.overrideWith((ref) => session),
          apiClientProvider.overrideWith((ref) => apiClient),
        ],
        child: const MaterialApp(home: DiagnosticsScreen()),
      ),
    );

    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Check backend health'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Healthy (API and database look up)'), findsOneWidget);
  });

  testWidgets(
    'diagnostics reconnect and disconnect actions update socket state',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final socket = _FakeSocketService(status: 'disconnected');
      final session = _FakeSessionController(_authenticatedState);
      final apiClient = _FakeApiClient(response: {'ok': true, 'db': true});

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            socketServiceProvider.overrideWith((ref) => socket),
            sessionControllerProvider.overrideWith((ref) => session),
            apiClientProvider.overrideWith((ref) => apiClient),
          ],
          child: const MaterialApp(home: DiagnosticsScreen()),
        ),
      );

      await tester.drag(find.byType(ListView), const Offset(0, -500));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Reconnect socket'));
      await tester.pumpAndSettle();

      expect(socket.connectCalls, 1);
      expect(socket.status, 'connected');
      expect(socket.isConnected, isTrue);

      await tester.tap(find.text('Disconnect socket'));
      await tester.pumpAndSettle();

      expect(socket.disconnectCalls, 1);
      expect(socket.status, 'disconnected');
      expect(socket.isConnected, isFalse);
    },
  );

  testWidgets('qa checklist screen renders progress and checklist items', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: QaChecklistScreen())),
    );
    await tester.pumpAndSettle();

    expect(find.text('QA checklist'), findsOneWidget);
    expect(
      find.text('0 of $qaChecklistTotalItems checks completed'),
      findsOneWidget,
    );
    expect(find.text('Open diagnostics'), findsOneWidget);
    expect(find.text('Open media preview'), findsOneWidget);
    expect(find.text('Startup'), findsOneWidget);
    expect(
      find.text(
        'Confirm the API base URL matches the current simulator, emulator, or device setup.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('qa checklist updates progress when an item is checked', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: QaChecklistScreen())),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(CheckboxListTile).first);
    await tester.pumpAndSettle();

    expect(
      find.text('1 of $qaChecklistTotalItems checks completed'),
      findsOneWidget,
    );
  });

  testWidgets('diagnostics reads persisted qa checklist progress', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      qaChecklistItemKey(0, 0): true,
    });
    final socket = _FakeSocketService(status: 'connected', connected: true);
    final session = _FakeSessionController(_authenticatedState);
    final apiClient = _FakeApiClient(response: {'ok': true, 'db': true});

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          socketServiceProvider.overrideWith((ref) => socket),
          sessionControllerProvider.overrideWith((ref) => session),
          apiClientProvider.overrideWith((ref) => apiClient),
        ],
        child: const MaterialApp(home: DiagnosticsScreen()),
      ),
    );

    await tester.scrollUntilVisible(
      find.text('Open Talk'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Checklist progress: 1/$qaChecklistTotalItems'),
      findsOneWidget,
    );
  });

  testWidgets('qa checklist reset clears saved progress', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      qaChecklistItemKey(0, 0): true,
    });

    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: QaChecklistScreen())),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('1 of $qaChecklistTotalItems checks completed'),
      findsOneWidget,
    );

    await tester.tap(find.byTooltip('Reset checklist'));
    await tester.pumpAndSettle();

    expect(
      find.text('0 of $qaChecklistTotalItems checks completed'),
      findsOneWidget,
    );
  });

  testWidgets('diagnostics reset qa checklist clears shared progress', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      qaChecklistItemKey(0, 0): true,
    });
    final socket = _FakeSocketService(status: 'connected', connected: true);
    final session = _FakeSessionController(_authenticatedState);
    final apiClient = _FakeApiClient(response: {'ok': true, 'db': true});

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          socketServiceProvider.overrideWith((ref) => socket),
          sessionControllerProvider.overrideWith((ref) => session),
          apiClientProvider.overrideWith((ref) => apiClient),
        ],
        child: const MaterialApp(home: DiagnosticsScreen()),
      ),
    );

    await tester.scrollUntilVisible(
      find.text('Reset QA checklist'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Checklist progress: 1/$qaChecklistTotalItems'),
      findsOneWidget,
    );

    await tester.tap(find.text('Reset QA checklist'));
    await tester.pumpAndSettle();

    expect(
      find.text('Checklist progress: 0/$qaChecklistTotalItems'),
      findsOneWidget,
    );
  });

  testWidgets('own profile shows settings entry and account details', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      qaChecklistItemKey(0, 0): true,
    });
    final session = _FakeSessionController(_authenticatedState);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [sessionControllerProvider.overrideWith((ref) => session)],
        child: const MaterialApp(home: ProfileScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Test User'), findsOneWidget);
    expect(find.text('Talkflix Pro'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('English'), findsOneWidget);
    expect(find.text('Learning Spanish'), findsOneWidget);
  });
}

final _authenticatedState = SessionState.authenticated(
  token: 'test_token_1234567890',
  sessionId: 'session-123',
  user: const AppUser(
    id: 'user-1',
    email: 'test@example.com',
    displayName: 'Test User',
    username: 'testuser',
    firstLanguage: 'English',
    learnLanguage: 'Spanish',
    role: 'user',
    plan: 'pro',
    trialUsed: true,
    meetLanguages: ['English', 'Spanish'],
    city: 'Los Angeles',
    country: 'USA',
    countryCode: 'US',
    nationalityCode: 'US',
    nationalityName: 'American',
    profilePhotoUrl: '',
    bioText: '',
    bioAudioUrl: '',
    bioAudioDuration: 0,
    followersCount: 2,
    followingCount: 3,
    postsCount: 0,
    isFollowing: false,
  ),
);

class _FakeSocketService extends SocketService {
  _FakeSocketService({required String status, bool connected = false})
    : _status = status,
      _connected = connected;

  String _status;
  bool _connected;
  int connectCalls = 0;
  int disconnectCalls = 0;

  @override
  String get status => _status;

  @override
  bool get isConnected => _connected;

  @override
  bool get hasVerifiedIdentity => _connected;

  @override
  void connect(
    String token, {
    required String expectedUserId,
    required String expectedSessionId,
  }) {
    connectCalls += 1;
    _status = 'connected';
    _connected = true;
    notifyListeners();
  }

  @override
  Future<bool> ensureSessionIdentity({
    required String token,
    required String expectedUserId,
    required String expectedSessionId,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    connect(
      token,
      expectedUserId: expectedUserId,
      expectedSessionId: expectedSessionId,
    );
    return true;
  }

  @override
  bool isVerifiedFor({
    required String userId,
    required String sessionId,
  }) => _connected;

  @override
  void disconnect() {
    disconnectCalls += 1;
    _status = 'disconnected';
    _connected = false;
    notifyListeners();
  }
}

class _FakeSessionController extends SessionController {
  _FakeSessionController(SessionState initialState)
    : _initialState = initialState,
      super(_DummyRef()) {
    state = initialState;
  }

  final SessionState _initialState;

  @override
  Future<void> bootstrap() async {
    state = _initialState;
  }

  @override
  Future<void> refreshProfile() async {
    state = _initialState;
  }
}

class _FakeApiClient extends ApiClient {
  _FakeApiClient({required Map<String, dynamic> response})
    : _response = response,
      super(baseUrl: 'http://localhost:4000', token: 'token');

  final Map<String, dynamic> _response;

  @override
  Future<Map<String, dynamic>> getJson(
    String path, {
    Map<String, String>? queryParameters,
    Duration? timeout,
    int? retries,
  }) async {
    return _response;
  }
}

class _DummyRef implements Ref {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
