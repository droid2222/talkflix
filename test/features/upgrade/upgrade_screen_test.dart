import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:talkflix_flutter/core/auth/app_user.dart';
import 'package:talkflix_flutter/core/auth/session_controller.dart';
import 'package:talkflix_flutter/core/auth/session_state.dart';
import 'package:talkflix_flutter/features/upgrade/presentation/pro_purchase_controller.dart';
import 'package:talkflix_flutter/features/upgrade/presentation/upgrade_screen.dart';

void main() {
  testWidgets('renders current Pro subscription plan labels', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionControllerProvider.overrideWith(
            (ref) => _FakeSessionController(_authenticatedFreeState),
          ),
          proPurchaseControllerProvider.overrideWith(
            (ref) => _FakeProPurchaseController(),
          ),
        ],
        child: const MaterialApp(home: UpgradeScreen()),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Talkflix Pro Monthly'), findsOneWidget);
    expect(find.text('Talkflix Pro 6 Months'), findsOneWidget);
    expect(find.text('Talkflix Pro Yearly'), findsOneWidget);
  });
}

const _authenticatedFreeState = SessionState.authenticated(
  token: 'test_token_1234567890',
  sessionId: 'session-123',
  user: AppUser(
    id: 'user-1',
    email: 'test@example.com',
    displayName: 'Test User',
    username: 'testuser',
    firstLanguage: 'English',
    learnLanguage: 'Spanish',
    role: 'user',
    plan: 'free',
    trialUsed: false,
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
}

class _FakeProPurchaseController extends StateNotifier<ProPurchaseState>
    implements ProPurchaseController {
  _FakeProPurchaseController()
    : super(ProPurchaseState(storeAvailable: true, products: _testProducts));

  @override
  Future<void> loadProducts() async {}

  @override
  Future<void> buy(ProductDetails product) async {}

  @override
  Future<void> restore() async {}
}

final _testProducts = <ProductDetails>[
  ProductDetails(
    id: 'talkflix_pro_monthly_v2',
    title: 'Talkflix Pro Monthly',
    description: 'Monthly access to Talkflix Pro features.',
    price: r'$9.99',
    rawPrice: 9.99,
    currencyCode: 'USD',
    currencySymbol: r'$',
  ),
  ProductDetails(
    id: 'talkflix_pro_6_months',
    title: 'Talkflix Pro 6 Months',
    description: 'Six months of Talkflix Pro features.',
    price: r'$49.99',
    rawPrice: 49.99,
    currencyCode: 'USD',
    currencySymbol: r'$',
  ),
  ProductDetails(
    id: 'talkflix_pro_yearly',
    title: 'Talkflix Pro Yearly',
    description: 'One year of Talkflix Pro features.',
    price: r'$89.99',
    rawPrice: 89.99,
    currencyCode: 'USD',
    currencySymbol: r'$',
  ),
];

class _DummyRef implements Ref {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
