import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:intl/intl.dart';

import '../../../core/auth/session_controller.dart';
import '../../../core/config/app_config.dart';
import '../../../app/theme/app_theme.dart';
import '../data/pro_purchase_repository.dart';
import 'pro_purchase_controller.dart';

class UpgradeScreen extends ConsumerStatefulWidget {
  const UpgradeScreen({super.key, this.featureName = ''});

  final String featureName;

  @override
  ConsumerState<UpgradeScreen> createState() => _UpgradeScreenState();
}

class _UpgradeScreenState extends ConsumerState<UpgradeScreen> {
  String _selectedProductId = '';
  late final PageController _featurePageController;
  late int _featurePageIndex;

  @override
  void initState() {
    super.initState();
    _featurePageIndex = _featureIndexFor(widget.featureName);
    _featurePageController = PageController(
      initialPage: _featurePageIndex,
      viewportFraction: 0.88,
    );
    if (kIsWeb && Uri.base.queryParameters['checkout'] == 'success') {
      Future<void>.microtask(() async {
        try {
          await ref.read(sessionControllerProvider.notifier).refreshProfile();
        } catch (_) {
          // Stripe webhooks can arrive shortly after the browser redirect.
        }
      });
    }
  }

  @override
  void dispose() {
    _featurePageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionControllerProvider);
    final user = session.user;
    final purchaseState = ref.watch(proPurchaseControllerProvider);
    final purchaseController = ref.read(proPurchaseControllerProvider.notifier);
    final theme = Theme.of(context);
    final isProLike = user?.isProLike == true;
    final plans = kIsWeb
        ? _stripePlanOptions(purchaseState.webPlans)
        : _planOptions(purchaseState.products);
    final selectedPlan = _selectedPlan(plans);
    final selectedProduct = selectedPlan?.product;
    final topPadding = MediaQuery.paddingOf(context).top;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset(
            'assets/images/live_room_bg.png',
            fit: BoxFit.cover,
            alignment: Alignment.topCenter,
          ),
          Container(color: Colors.black.withValues(alpha: 0.58)),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0x88000000), Color(0xDD000000)],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
          ),
          SafeArea(
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      22,
                      math.max(8, 18 - topPadding),
                      22,
                      24,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Align(
                          alignment: Alignment.centerLeft,
                          child: IconButton.filledTonal(
                            onPressed: () {
                              if (context.canPop()) {
                                context.pop();
                              } else {
                                context.go('/app/content');
                              }
                            },
                            icon: const Icon(Icons.close_rounded),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Image.asset(
                          'assets/images/talkflix_logo.png',
                          height: 50,
                          fit: BoxFit.contain,
                        ),
                        const SizedBox(height: 18),
                        Text(
                          'Talkflix Pro',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.displaySmall?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w900,
                            height: 0.98,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Remove the daily waits and keep language practice moving.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: Colors.white.withValues(alpha: 0.78),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 24),
                        _FeatureCarousel(
                          controller: _featurePageController,
                          currentIndex: _featurePageIndex,
                          onPageChanged: (index) {
                            setState(() {
                              _featurePageIndex = index;
                            });
                          },
                        ),
                        const SizedBox(height: 24),
                        if (isProLike) ...[
                          const _StatusBanner(
                            text: 'Talkflix Pro is active on this account.',
                            color: Color(0xFF34D399),
                          ),
                          const SizedBox(height: 14),
                        ],
                        if (purchaseState.message != null) ...[
                          _StatusBanner(
                            text: purchaseState.message!,
                            color: const Color(0xFF34D399),
                          ),
                          const SizedBox(height: 14),
                        ],
                        if (purchaseState.error != null) ...[
                          _StatusBanner(
                            text: purchaseState.error!,
                            color: const Color(0xFFFF6B75),
                          ),
                          const SizedBox(height: 14),
                        ],
                        if (purchaseState.loadingProducts) ...[
                          const SizedBox(height: 28),
                          const CircularProgressIndicator(color: Colors.white),
                          const SizedBox(height: 28),
                        ] else if (!purchaseState.storeAvailable) ...[
                          _StoreUnavailable(
                            text: AppConfig.paidUpgradeEnabled
                                ? kIsWeb
                                      ? 'Stripe checkout is not available right now.'
                                      : 'Pro plans are not available from the store on this device right now.'
                                : 'Paid upgrades are disabled for this build.',
                            onRetry: purchaseState.busy
                                ? null
                                : purchaseController.loadProducts,
                          ),
                        ] else if (plans.isEmpty) ...[
                          _StoreUnavailable(
                            text: kIsWeb
                                ? 'The API did not return web Pro plans yet. Confirm the Stripe Pro plan configuration.'
                                : 'The store did not return the configured Pro plans yet. Confirm the product IDs in App Store Connect and Play Console.',
                            onRetry: purchaseState.busy
                                ? null
                                : purchaseController.loadProducts,
                          ),
                        ] else ...[
                          for (final plan in plans) ...[
                            _PlanCard(
                              plan: plan,
                              selected: plan.id == selectedPlan?.id,
                              busy:
                                  purchaseState.buyingProductId == plan.id ||
                                  purchaseState.processingPurchase,
                              disabled: purchaseState.busy || isProLike,
                              onTap: () {
                                setState(() {
                                  _selectedProductId = plan.id;
                                });
                              },
                            ),
                            const SizedBox(height: 12),
                          ],
                        ],
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            onPressed:
                                selectedPlan == null ||
                                    (!kIsWeb && selectedProduct == null) ||
                                    purchaseState.busy ||
                                    isProLike
                                ? null
                                : () => kIsWeb
                                      ? purchaseController.startWebCheckout(
                                          selectedPlan.id,
                                        )
                                      : purchaseController.buy(
                                          selectedProduct!,
                                        ),
                            style: FilledButton.styleFrom(
                              backgroundColor: talkflixPrimary,
                              foregroundColor: Colors.white,
                              minimumSize: const Size.fromHeight(58),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(999),
                              ),
                              textStyle: const TextStyle(
                                fontWeight: FontWeight.w900,
                                fontSize: 17,
                              ),
                            ),
                            child: Text(
                              purchaseState.processingPurchase ||
                                      purchaseState.buyingProductId.isNotEmpty
                                  ? 'Processing...'
                                  : 'Upgrade to Pro',
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        if (!kIsWeb) ...[
                          TextButton(
                            onPressed: purchaseState.busy
                                ? null
                                : purchaseController.restore,
                            child: Text(
                              purchaseState.restoring
                                  ? 'Restoring...'
                                  : 'Restore purchases',
                              style: const TextStyle(color: Colors.white),
                            ),
                          ),
                        ],
                        const SizedBox(height: 14),
                        Text(
                          kIsWeb
                              ? 'Checkout is handled securely by Stripe. Your Pro access is activated after Stripe confirms the subscription payment.'
                              : 'Your store account will be charged at confirmation of purchase. Subscriptions renew automatically unless canceled in your App Store or Google Play account before the renewal period.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.white.withValues(alpha: 0.66),
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  int _featureIndexFor(String rawFeature) {
    final value = rawFeature.toLowerCase();
    if (value.trim().isEmpty) return 0;
    if (_containsAny(value, const ['watch', 'video', 'podcast', 'content'])) {
      return 1;
    }
    if (_containsAny(value, const ['call'])) return 2;
    if (_containsAny(value, const [
      'room',
      'broadcast',
      'speaker',
      'stage',
      'host',
      'audience',
      'private',
    ])) {
      return 3;
    }
    if (_containsAny(value, const ['translate', 'paraphrase'])) {
      return 4;
    }
    if (_containsAny(value, const [
      'search',
      'nearby',
      'partner',
      'language',
      'filter',
    ])) {
      return 5;
    }
    return 0;
  }

  bool _containsAny(String value, List<String> needles) {
    return needles.any(value.contains);
  }

  List<_PlanOption> _planOptions(List<ProductDetails> products) {
    final sorted = [...products]
      ..sort((a, b) {
        final aIndex = AppConfig.proProductIds.indexOf(a.id);
        final bIndex = AppConfig.proProductIds.indexOf(b.id);
        final safeA = aIndex == -1 ? 999 : aIndex;
        final safeB = bIndex == -1 ? 999 : bIndex;
        return safeA.compareTo(safeB);
      });
    return sorted.map(_planOptionFor).toList(growable: false);
  }

  List<_PlanOption> _stripePlanOptions(List<ProStripePlan> plans) {
    final sorted = [...plans]
      ..sort((a, b) {
        final aIndex = AppConfig.proProductIds.indexOf(a.id);
        final bIndex = AppConfig.proProductIds.indexOf(b.id);
        final safeA = aIndex == -1 ? 999 : aIndex;
        final safeB = bIndex == -1 ? 999 : bIndex;
        return safeA.compareTo(safeB);
      });
    return sorted
        .map(
          (plan) => _PlanOption(
            id: plan.id,
            label: plan.label,
            months: plan.months,
            price: plan.price,
            monthlyPrice: plan.monthlyPrice,
            popular: plan.popular,
          ),
        )
        .toList(growable: false);
  }

  _PlanOption? _selectedPlan(List<_PlanOption> plans) {
    if (plans.isEmpty) return null;
    for (final plan in plans) {
      if (plan.id == _selectedProductId) return plan;
    }
    final yearly = plans.where((plan) => plan.months == 12).firstOrNull;
    return yearly ?? plans.first;
  }

  _PlanOption _planOptionFor(ProductDetails product) {
    final id = product.id.toLowerCase();
    final months = id.contains('year')
        ? 12
        : id.contains('6')
        ? 6
        : 1;
    final label = months == 12
        ? '12 MONTHS'
        : months == 6
        ? '6 MONTHS'
        : '1 MONTH';
    final monthlyPrice = _monthlyPrice(product, months);
    return _PlanOption(
      id: product.id,
      product: product,
      label: label,
      months: months,
      price: product.price,
      monthlyPrice: monthlyPrice,
      popular: months == 12,
    );
  }

  String _monthlyPrice(ProductDetails product, int months) {
    if (product.rawPrice <= 0 || months <= 1) return product.price;
    final symbol = product.currencySymbol.trim().isNotEmpty
        ? product.currencySymbol
        : '${product.currencyCode} ';
    final formatter = NumberFormat.currency(symbol: symbol, decimalDigits: 2);
    return formatter.format(product.rawPrice / months);
  }
}

class _FeatureCarousel extends StatelessWidget {
  const _FeatureCarousel({
    required this.controller,
    required this.currentIndex,
    required this.onPageChanged,
  });

  final PageController controller;
  final int currentIndex;
  final ValueChanged<int> onPageChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        SizedBox(
          height: 178,
          child: PageView.builder(
            controller: controller,
            itemCount: _proFeatures.length,
            onPageChanged: onPageChanged,
            itemBuilder: (context, index) {
              final feature = _proFeatures[index];
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.13),
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.28),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 58,
                          height: 58,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: talkflixPrimary,
                          ),
                          child: Icon(
                            feature.icon,
                            color: Colors.white,
                            size: 30,
                          ),
                        ),
                        const SizedBox(height: 14),
                        Text(
                          feature.title,
                          style: theme.textTheme.headlineSmall?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          feature.subtitle,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: Colors.white.withValues(alpha: 0.78),
                            height: 1.25,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var index = 0; index < _proFeatures.length; index++) ...[
              AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                width: index == currentIndex ? 22 : 7,
                height: 7,
                margin: const EdgeInsets.symmetric(horizontal: 3),
                decoration: BoxDecoration(
                  color: index == currentIndex
                      ? talkflixPrimary
                      : Colors.white.withValues(alpha: 0.42),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.plan,
    required this.selected,
    required this.busy,
    required this.disabled,
    required this.onTap,
  });

  final _PlanOption plan;
  final bool selected;
  final bool busy;
  final bool disabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final borderColor = selected
        ? talkflixPrimary
        : Colors.white.withValues(alpha: 0.72);
    final fillColor = selected
        ? talkflixPrimary
        : Colors.white.withValues(alpha: 0.10);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        InkWell(
          onTap: disabled ? null : onTap,
          borderRadius: BorderRadius.circular(22),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
            decoration: BoxDecoration(
              color: fillColor,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: borderColor, width: 1.6),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        plan.label,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: Colors.white.withValues(alpha: 0.92),
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        plan.price,
                        style: theme.textTheme.titleLarge?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ],
                  ),
                ),
                if (busy) ...[
                  const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.4,
                      color: Colors.white,
                    ),
                  ),
                ] else ...[
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        plan.monthlyPrice,
                        style: theme.textTheme.titleLarge?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      Text(
                        'per month',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: Colors.white.withValues(alpha: 0.78),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
        if (plan.popular)
          Positioned(
            top: -13,
            left: 32,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                'MOST POPULAR',
                style: TextStyle(
                  color: talkflixPrimary,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _StoreUnavailable extends StatelessWidget {
  const _StoreUnavailable({required this.text, required this.onRetry});

  final String text;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.32)),
      ),
      child: Column(
        children: [
          Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: onRetry,
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: const BorderSide(color: Colors.white),
            ),
            child: const Text('Try again'),
          ),
        ],
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.36)),
      ),
      child: Text(text, style: TextStyle(color: color)),
    );
  }
}

class _PlanOption {
  const _PlanOption({
    required this.id,
    required this.label,
    required this.months,
    required this.price,
    required this.monthlyPrice,
    required this.popular,
    this.product,
  });

  final String id;
  final ProductDetails? product;
  final String label;
  final int months;
  final String price;
  final String monthlyPrice;
  final bool popular;
}

class _ProFeature {
  const _ProFeature({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;
}

const _proFeatures = <_ProFeature>[
  _ProFeature(
    icon: Icons.bolt_rounded,
    title: 'Unlimited access',
    subtitle:
        'Use Talkflix without daily waits, hard stops, or short sessions.',
  ),
  _ProFeature(
    icon: Icons.play_circle_fill_rounded,
    title: 'Videos and podcasts',
    subtitle: 'Watch and listen without the free daily content limit.',
  ),
  _ProFeature(
    icon: Icons.call_rounded,
    title: 'Direct calling',
    subtitle: 'Start direct voice and video calls without the free daily cap.',
  ),
  _ProFeature(
    icon: Icons.groups_2_rounded,
    title: 'Audio and video rooms',
    subtitle:
        'Join rooms, host rooms, and stay on stage without daily time caps.',
  ),
  _ProFeature(
    icon: Icons.translate_rounded,
    title: 'Chat translations',
    subtitle: 'Translate and paraphrase direct chats without daily limits.',
  ),
  _ProFeature(
    icon: Icons.travel_explore_rounded,
    title: 'Partner discovery',
    subtitle: 'Unlock advanced discovery filters and nearby partner search.',
  ),
];
