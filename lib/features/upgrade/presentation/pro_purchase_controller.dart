import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import '../../../core/auth/session_controller.dart';
import '../../../core/config/app_config.dart';
import '../../../core/network/api_exception.dart';
import '../data/pro_purchase_repository.dart';

final proPurchaseControllerProvider =
    StateNotifierProvider<ProPurchaseController, ProPurchaseState>((ref) {
      return ProPurchaseController(ref);
    });

class ProPurchaseState {
  const ProPurchaseState({
    this.loadingProducts = false,
    this.storeAvailable = false,
    this.products = const <ProductDetails>[],
    this.notFoundProductIds = const <String>[],
    this.processingPurchase = false,
    this.pendingStoreConfirmation = false,
    this.restoring = false,
    this.buyingProductId = '',
    this.message,
    this.error,
  });

  final bool loadingProducts;
  final bool storeAvailable;
  final List<ProductDetails> products;
  final List<String> notFoundProductIds;
  final bool processingPurchase;
  final bool pendingStoreConfirmation;
  final bool restoring;
  final String buyingProductId;
  final String? message;
  final String? error;

  bool get busy =>
      loadingProducts ||
      processingPurchase ||
      pendingStoreConfirmation ||
      restoring ||
      buyingProductId.isNotEmpty;

  ProPurchaseState copyWith({
    bool? loadingProducts,
    bool? storeAvailable,
    List<ProductDetails>? products,
    List<String>? notFoundProductIds,
    bool? processingPurchase,
    bool? pendingStoreConfirmation,
    bool? restoring,
    String? buyingProductId,
    String? message,
    String? error,
    bool clearMessage = false,
    bool clearError = false,
  }) {
    return ProPurchaseState(
      loadingProducts: loadingProducts ?? this.loadingProducts,
      storeAvailable: storeAvailable ?? this.storeAvailable,
      products: products ?? this.products,
      notFoundProductIds: notFoundProductIds ?? this.notFoundProductIds,
      processingPurchase: processingPurchase ?? this.processingPurchase,
      pendingStoreConfirmation:
          pendingStoreConfirmation ?? this.pendingStoreConfirmation,
      restoring: restoring ?? this.restoring,
      buyingProductId: buyingProductId ?? this.buyingProductId,
      message: clearMessage ? null : (message ?? this.message),
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class ProPurchaseController extends StateNotifier<ProPurchaseState> {
  ProPurchaseController(this._ref) : super(const ProPurchaseState()) {
    if (AppConfig.paidUpgradeEnabled) {
      _subscription = _repository.purchaseStream.listen(
        _handlePurchaseUpdates,
        onError: (Object error, StackTrace stackTrace) {
          state = state.copyWith(
            processingPurchase: false,
            pendingStoreConfirmation: false,
            buyingProductId: '',
            restoring: false,
            error: 'The store returned an unexpected purchase update.',
            clearMessage: true,
          );
        },
      );
      unawaited(loadProducts());
    }
  }

  final Ref _ref;
  StreamSubscription<List<PurchaseDetails>>? _subscription;
  final Set<String> _processingPurchaseKeys = <String>{};

  ProPurchaseRepository get _repository =>
      _ref.read(proPurchaseRepositoryProvider);

  Future<void> loadProducts() async {
    if (!AppConfig.paidUpgradeEnabled) {
      state = state.copyWith(
        storeAvailable: false,
        products: const <ProductDetails>[],
        notFoundProductIds: const <String>[],
        loadingProducts: false,
        error: 'Paid upgrades are disabled for this build.',
        clearMessage: true,
      );
      return;
    }

    state = state.copyWith(
      loadingProducts: true,
      clearError: true,
      clearMessage: true,
    );
    try {
      final result = await _repository.queryProducts();
      state = state.copyWith(
        loadingProducts: false,
        storeAvailable: result.storeAvailable,
        products: result.products,
        notFoundProductIds: result.notFoundIds,
        error: result.error,
      );
    } catch (_) {
      state = state.copyWith(
        loadingProducts: false,
        storeAvailable: false,
        error: 'Could not load Pro plans from the store.',
        clearMessage: true,
      );
    }
  }

  Future<void> buy(ProductDetails product) async {
    if (state.busy) return;
    final session = _ref.read(sessionControllerProvider);
    if (!session.isAuthenticated || session.user == null) {
      state = state.copyWith(
        error: 'Sign in before upgrading to Pro.',
        clearMessage: true,
      );
      return;
    }

    state = state.copyWith(
      buyingProductId: product.id,
      clearError: true,
      clearMessage: true,
    );
    try {
      final launched = await _repository.buyProduct(
        product: product,
        applicationUserName: session.user!.id,
      );
      if (!launched) {
        state = state.copyWith(
          buyingProductId: '',
          error: 'The store could not start checkout.',
          clearMessage: true,
        );
        return;
      }
      state = state.copyWith(
        buyingProductId: '',
        pendingStoreConfirmation: true,
        message: 'Confirm the purchase in the store to finish upgrading.',
        clearError: true,
      );
    } catch (_) {
      state = state.copyWith(
        buyingProductId: '',
        error: 'Could not start checkout.',
        clearMessage: true,
      );
    }
  }

  Future<void> restore() async {
    if (state.busy) return;
    final session = _ref.read(sessionControllerProvider);
    if (!session.isAuthenticated || session.user == null) {
      state = state.copyWith(
        error: 'Sign in before restoring purchases.',
        clearMessage: true,
      );
      return;
    }

    state = state.copyWith(
      restoring: true,
      clearError: true,
      clearMessage: true,
    );
    try {
      await _repository.restorePurchases(applicationUserName: session.user!.id);
      state = state.copyWith(
        restoring: false,
        pendingStoreConfirmation: true,
        message: 'Checking restored purchases...',
      );
    } catch (_) {
      state = state.copyWith(
        restoring: false,
        error: 'Could not start restore purchases.',
        clearMessage: true,
      );
    }
  }

  Future<void> _handlePurchaseUpdates(
    List<PurchaseDetails> purchaseDetailsList,
  ) async {
    for (final purchase in purchaseDetailsList) {
      if (!AppConfig.proProductIds.contains(purchase.productID)) {
        continue;
      }
      await _handlePurchaseUpdate(purchase);
    }
  }

  Future<void> _handlePurchaseUpdate(PurchaseDetails purchase) async {
    switch (purchase.status) {
      case PurchaseStatus.pending:
        state = state.copyWith(
          pendingStoreConfirmation: true,
          message: 'Purchase pending. We will unlock Pro after confirmation.',
          clearError: true,
        );
        return;
      case PurchaseStatus.error:
        state = state.copyWith(
          pendingStoreConfirmation: false,
          processingPurchase: false,
          buyingProductId: '',
          restoring: false,
          error:
              purchase.error?.message ??
              'The store could not complete the purchase.',
          clearMessage: true,
        );
        return;
      case PurchaseStatus.canceled:
        state = state.copyWith(
          pendingStoreConfirmation: false,
          processingPurchase: false,
          buyingProductId: '',
          restoring: false,
          message: 'Purchase canceled.',
          clearError: true,
        );
        return;
      case PurchaseStatus.purchased:
      case PurchaseStatus.restored:
        break;
    }

    final key = _purchaseKey(purchase);
    if (_processingPurchaseKeys.contains(key)) return;
    _processingPurchaseKeys.add(key);
    state = state.copyWith(
      processingPurchase: true,
      pendingStoreConfirmation: false,
      buyingProductId: '',
      restoring: false,
      message: 'Verifying your Pro purchase...',
      clearError: true,
    );

    try {
      final verified = await _repository.verifyPurchase(
        purchase,
        restored: purchase.status == PurchaseStatus.restored,
      );
      await _ref
          .read(sessionControllerProvider.notifier)
          .setAuthenticated(
            token: verified.token,
            sessionId: verified.sessionId,
            user: verified.user,
          );
      if (purchase.pendingCompletePurchase) {
        await _repository.completePurchase(purchase);
      }
      state = state.copyWith(
        processingPurchase: false,
        pendingStoreConfirmation: false,
        message: verified.expiresAt.isEmpty
            ? 'Talkflix Pro is active.'
            : 'Talkflix Pro is active until ${_formatDate(verified.expiresAt)}.',
        clearError: true,
      );
    } on ApiException catch (error) {
      state = state.copyWith(
        processingPurchase: false,
        pendingStoreConfirmation: false,
        error: error.message,
        clearMessage: true,
      );
    } catch (_) {
      state = state.copyWith(
        processingPurchase: false,
        pendingStoreConfirmation: false,
        error: 'Could not verify this purchase yet. Try restore purchases.',
        clearMessage: true,
      );
    } finally {
      _processingPurchaseKeys.remove(key);
    }
  }

  String _purchaseKey(PurchaseDetails purchase) {
    final verification = purchase.verificationData.serverVerificationData;
    return [
      purchase.verificationData.source,
      purchase.productID,
      purchase.purchaseID ?? '',
      verification.hashCode.toString(),
    ].join(':');
  }

  String _formatDate(String raw) {
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return raw;
    final local = parsed.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    return '${local.year}-$month-$day';
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _subscription = null;
    super.dispose();
  }
}
