import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import '../../../core/auth/app_user.dart';
import '../../../core/auth/session_identity.dart';
import '../../../core/config/app_config.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../auth/data/auth_repository.dart';

final proPurchaseRepositoryProvider = Provider<ProPurchaseRepository>((ref) {
  return ProPurchaseRepository(ref);
});

class ProPurchaseRepository {
  ProPurchaseRepository(this._ref, {InAppPurchase? inAppPurchase})
    : _inAppPurchase = inAppPurchase ?? InAppPurchase.instance;

  final Ref _ref;
  final InAppPurchase _inAppPurchase;

  Stream<List<PurchaseDetails>> get purchaseStream =>
      _inAppPurchase.purchaseStream;

  bool get supportedPlatform {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.android;
  }

  String get platform {
    if (defaultTargetPlatform == TargetPlatform.iOS) return 'ios';
    if (defaultTargetPlatform == TargetPlatform.android) return 'android';
    return 'unsupported';
  }

  Future<ProProductQueryResult> queryProducts() async {
    if (!AppConfig.paidUpgradeEnabled || !supportedPlatform) {
      return const ProProductQueryResult(
        storeAvailable: false,
        products: <ProductDetails>[],
        notFoundIds: <String>[],
      );
    }

    final available = await _inAppPurchase.isAvailable();
    if (!available) {
      return const ProProductQueryResult(
        storeAvailable: false,
        products: <ProductDetails>[],
        notFoundIds: <String>[],
      );
    }

    final response = await _inAppPurchase.queryProductDetails(
      AppConfig.proProductIds.toSet(),
    );
    final order = <String, int>{
      for (final entry in AppConfig.proProductIds.indexed) entry.$2: entry.$1,
    };
    final products = response.productDetails.toList(growable: false)
      ..sort((a, b) {
        final aIndex = order[a.id] ?? 9999;
        final bIndex = order[b.id] ?? 9999;
        if (aIndex != bIndex) return aIndex.compareTo(bIndex);
        return a.rawPrice.compareTo(b.rawPrice);
      });

    return ProProductQueryResult(
      storeAvailable: true,
      products: products,
      notFoundIds: response.notFoundIDs,
      error: response.error?.message,
    );
  }

  Future<bool> buyProduct({
    required ProductDetails product,
    String applicationUserName = '',
  }) {
    final purchaseParam = PurchaseParam(
      productDetails: product,
      applicationUserName: applicationUserName.isEmpty
          ? null
          : applicationUserName,
    );
    return _inAppPurchase.buyNonConsumable(purchaseParam: purchaseParam);
  }

  Future<void> restorePurchases({String applicationUserName = ''}) {
    return _inAppPurchase.restorePurchases(
      applicationUserName: applicationUserName.isEmpty
          ? null
          : applicationUserName,
    );
  }

  Future<VerifiedProPurchase> verifyPurchase(
    PurchaseDetails purchase, {
    required bool restored,
  }) async {
    final data = await _ref
        .read(apiClientProvider)
        .postJson(
          '/billing/iap/verify',
          body: <String, dynamic>{
            'platform': platform,
            'productId': purchase.productID,
            'purchaseId': purchase.purchaseID ?? '',
            'transactionDate': purchase.transactionDate ?? '',
            'status': purchase.status.name,
            'restored': restored,
            'verificationData': <String, dynamic>{
              'source': purchase.verificationData.source,
              'serverVerificationData':
                  purchase.verificationData.serverVerificationData,
              'localVerificationData':
                  purchase.verificationData.localVerificationData,
            },
          },
          timeout: const Duration(seconds: 30),
          retries: 0,
        );

    final token = data['token']?.toString() ?? '';
    final sessionIdentity = parseSessionIdentityFromToken(token);
    final sessionId =
        data['sessionId']?.toString() ??
        (sessionIdentity.isValid ? sessionIdentity.sessionId : '');
    if (token.isEmpty || sessionId.isEmpty) {
      throw const ApiException(
        'Purchase verified, but session refresh failed.',
      );
    }

    final userJson = data['user'] as Map<String, dynamic>? ?? {};
    final user = userJson.isEmpty
        ? await _ref.read(authRepositoryProvider).fetchMe(tokenOverride: token)
        : AppUser.fromJson(userJson);

    return VerifiedProPurchase(
      token: token,
      sessionId: sessionId,
      user: user,
      productId: data['productId']?.toString() ?? purchase.productID,
      expiresAt: data['expiresAt']?.toString() ?? '',
    );
  }

  Future<void> completePurchase(PurchaseDetails purchase) {
    return _inAppPurchase.completePurchase(purchase);
  }
}

class ProProductQueryResult {
  const ProProductQueryResult({
    required this.storeAvailable,
    required this.products,
    required this.notFoundIds,
    this.error,
  });

  final bool storeAvailable;
  final List<ProductDetails> products;
  final List<String> notFoundIds;
  final String? error;
}

class VerifiedProPurchase {
  const VerifiedProPurchase({
    required this.token,
    required this.sessionId,
    required this.user,
    required this.productId,
    required this.expiresAt,
  });

  final String token;
  final String sessionId;
  final AppUser user;
  final String productId;
  final String expiresAt;
}
