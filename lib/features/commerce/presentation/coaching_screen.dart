import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/config/app_config.dart';
import '../../../core/media/media_utils.dart';
import '../../../core/navigation/public_home_navigation.dart';
import '../../../core/network/api_exception.dart';
import '../../../app/theme/app_theme.dart';
import '../data/commerce_repository.dart';

class CoachingScreen extends ConsumerStatefulWidget {
  const CoachingScreen({super.key, this.productSlug});

  final String? productSlug;

  @override
  ConsumerState<CoachingScreen> createState() => _CoachingScreenState();
}

class _CoachingScreenState extends ConsumerState<CoachingScreen> {
  static const _fallbackProductId = 'one_on_one_coaching';
  final Map<String, int> _quantities = <String, int>{};
  String _catalogQuery = '';
  bool _checkoutBusy = false;

  @override
  Widget build(BuildContext context) {
    final cleanSlug = widget.productSlug?.trim() ?? '';
    final products = cleanSlug.isEmpty
        ? ref.watch(commerceProductsProvider)
        : ref
              .watch(commerceProductProvider(cleanSlug))
              .whenData(
                (product) => product == null
                    ? const <CommerceProduct>[]
                    : <CommerceProduct>[product],
              );
    final productMissing =
        cleanSlug.isNotEmpty &&
        products.hasValue &&
        (products.valueOrNull ?? const <CommerceProduct>[]).isEmpty;
    final scheme = Theme.of(context).colorScheme;

    if (cleanSlug.isEmpty) {
      return Scaffold(
        backgroundColor: scheme.surface,
        body: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: _CommerceCatalogHeader(
                query: _catalogQuery,
                onQueryChanged: (value) {
                  setState(() => _catalogQuery = value);
                },
              ),
            ),
            SliverToBoxAdapter(
              child: _CommerceProductCatalog(
                products: products,
                query: _catalogQuery,
                checkoutBusy: _checkoutBusy,
                quantityFor: _quantityFor,
                onQuantityChanged: _setQuantity,
                onCheckout: (product) {
                  _startCheckout(product, quantity: _quantityFor(product));
                },
              ),
            ),
            const SliverToBoxAdapter(child: _CoachingFooter()),
          ],
        ),
      );
    }

    return Scaffold(
      backgroundColor: scheme.surface,
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: _CoachingHero(
              products: products,
              checkoutBusy: _checkoutBusy,
              productMissing: productMissing,
              quantityFor: _quantityFor,
              onQuantityChanged: _setQuantity,
              onCheckout: (product) {
                _startCheckout(product, quantity: _quantityFor(product));
              },
            ),
          ),
          const SliverToBoxAdapter(child: _CoachingOutcomes()),
          const SliverToBoxAdapter(child: _CoachingDetails()),
          const SliverToBoxAdapter(child: _CoachingFaq()),
          const SliverToBoxAdapter(child: _CoachingFooter()),
        ],
      ),
    );
  }

  int _quantityFor(CommerceProduct? product) {
    final key = product?.id ?? _fallbackProductId;
    return (_quantities[key] ?? 1).clamp(1, 99);
  }

  void _setQuantity(CommerceProduct product, int quantity) {
    setState(() {
      _quantities[product.id] = quantity.clamp(1, 99);
    });
  }

  Future<void> _startCheckout(
    CommerceProduct? product, {
    int quantity = 1,
  }) async {
    if (_checkoutBusy) return;
    setState(() => _checkoutBusy = true);
    try {
      final uri = await ref
          .read(commerceRepositoryProvider)
          .createCheckoutSession(
            productId: product?.id ?? _fallbackProductId,
            quantity: quantity,
          );
      final opened = await launchUrl(uri, webOnlyWindowName: '_self');
      if (!opened) {
        throw StateError('Could not open Stripe Checkout.');
      }
    } catch (error) {
      if (!mounted) return;
      final message = error is ApiException
          ? error.message
          : 'Payment could not be started. Please try again or contact ${AppConfig.supportEmail}.';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted) setState(() => _checkoutBusy = false);
    }
  }
}

class _CoachingHero extends StatelessWidget {
  const _CoachingHero({
    required this.products,
    required this.checkoutBusy,
    required this.productMissing,
    required this.quantityFor,
    required this.onQuantityChanged,
    required this.onCheckout,
  });

  final AsyncValue<List<CommerceProduct>> products;
  final bool checkoutBusy;
  final bool productMissing;
  final int Function(CommerceProduct? product) quantityFor;
  final void Function(CommerceProduct product, int quantity) onQuantityChanged;
  final ValueChanged<CommerceProduct?> onCheckout;

  @override
  Widget build(BuildContext context) {
    final product = products.valueOrNull?.firstOrNull;
    final price = product?.priceLabel.isNotEmpty == true
        ? product!.priceLabel
        : r'$28';
    final checkoutDisabled =
        products.hasError || products.isLoading || productMissing;
    final compact = MediaQuery.sizeOf(context).width < 720;

    return DecoratedBox(
      decoration: const BoxDecoration(
        color: Color(0xFF101113),
        image: DecorationImage(
          image: AssetImage('assets/images/live_room_bg.png'),
          fit: BoxFit.cover,
          opacity: 0.18,
        ),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.68)),
        child: SafeArea(
          bottom: false,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1180),
              child: Padding(
                padding: EdgeInsets.fromLTRB(20, 18, 20, compact ? 52 : 80),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _CoachingTopNav(),
                    SizedBox(height: compact ? 56 : 90),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final desktop = constraints.maxWidth >= 900;
                        final copy = _HeroCopy(product: product, price: price);
                        final card = _CheckoutCard(
                          product: product,
                          price: price,
                          quantity: quantityFor(product),
                          loading: products.isLoading,
                          disabled: checkoutDisabled,
                          busy: checkoutBusy,
                          error: products.hasError,
                          productMissing: productMissing,
                          onQuantityChanged: product == null
                              ? null
                              : (quantity) =>
                                    onQuantityChanged(product, quantity),
                          onCheckout: () => onCheckout(product),
                        );
                        if (!desktop) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [copy, const SizedBox(height: 28), card],
                          );
                        }
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(flex: 6, child: copy),
                            const SizedBox(width: 54),
                            Expanded(flex: 4, child: card),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CommerceCatalogHeader extends StatelessWidget {
  const _CommerceCatalogHeader({
    required this.query,
    required this.onQueryChanged,
  });

  final String query;
  final ValueChanged<String> onQueryChanged;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 720;
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: Color(0xFF101113),
        image: DecorationImage(
          image: AssetImage('assets/images/live_room_bg.png'),
          fit: BoxFit.cover,
          opacity: 0.12,
        ),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.72)),
        child: SafeArea(
          bottom: false,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1180),
              child: Padding(
                padding: EdgeInsets.fromLTRB(20, 18, 20, compact ? 48 : 74),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _CoachingTopNav(),
                    SizedBox(height: compact ? 46 : 74),
                    Text(
                      'Coaching, courses, and digital products',
                      style: Theme.of(context).textTheme.displayLarge?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                        height: 0.98,
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      'Search the catalog and choose the service or product that fits what you need. No single offer owns this page.',
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(
                            color: Colors.white.withValues(alpha: 0.86),
                            fontWeight: FontWeight.w700,
                            height: 1.28,
                          ),
                    ),
                    const SizedBox(height: 30),
                    TextField(
                      controller: TextEditingController(text: query)
                        ..selection = TextSelection.collapsed(
                          offset: query.length,
                        ),
                      onChanged: onQueryChanged,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                      decoration: InputDecoration(
                        hintText: 'Search services, courses, ebooks...',
                        hintStyle: TextStyle(
                          color: Colors.white.withValues(alpha: 0.58),
                        ),
                        prefixIcon: const Icon(
                          Icons.search_rounded,
                          color: Colors.white,
                        ),
                        filled: true,
                        fillColor: Colors.white.withValues(alpha: 0.12),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(
                            color: Colors.white.withValues(alpha: 0.22),
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: const BorderSide(
                            color: talkflixPrimary,
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CommerceProductCatalog extends StatelessWidget {
  const _CommerceProductCatalog({
    required this.products,
    required this.query,
    required this.checkoutBusy,
    required this.quantityFor,
    required this.onQuantityChanged,
    required this.onCheckout,
  });

  final AsyncValue<List<CommerceProduct>> products;
  final String query;
  final bool checkoutBusy;
  final int Function(CommerceProduct product) quantityFor;
  final void Function(CommerceProduct product, int quantity) onQuantityChanged;
  final ValueChanged<CommerceProduct> onCheckout;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _CoachingBand(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionHeader(
            eyebrow: 'Available offers',
            title: 'All available offers',
            copy:
                'Each active item has its own purchase page and Stripe checkout link. Use search to narrow the catalog.',
          ),
          const SizedBox(height: 26),
          products.when(
            loading: () => const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: CircularProgressIndicator(),
              ),
            ),
            error: (_, _) => Text(
              'Products could not be loaded right now.',
              style: TextStyle(
                color: scheme.error,
                fontWeight: FontWeight.w700,
              ),
            ),
            data: (items) {
              final normalizedQuery = query.trim().toLowerCase();
              final visibleItems = normalizedQuery.isEmpty
                  ? items
                  : items
                        .where((product) {
                          final haystack =
                              '${product.title} ${product.subtitle} ${product.description} ${product.type}'
                                  .toLowerCase();
                          return haystack.contains(normalizedQuery);
                        })
                        .toList(growable: false);
              if (visibleItems.isEmpty) {
                return Text(
                  items.isEmpty
                      ? 'No active products are available yet.'
                      : 'No matching products found.',
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                );
              }
              return LayoutBuilder(
                builder: (context, constraints) {
                  final columns = constraints.maxWidth >= 940
                      ? 3
                      : constraints.maxWidth >= 640
                      ? 2
                      : 1;
                  return GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      crossAxisSpacing: 16,
                      mainAxisSpacing: 16,
                      childAspectRatio: columns == 1 ? 1.08 : 0.82,
                    ),
                    itemCount: visibleItems.length,
                    itemBuilder: (context, index) {
                      final product = visibleItems[index];
                      return _CommerceProductTile(
                        product: product,
                        checkoutBusy: checkoutBusy,
                        quantity: quantityFor(product),
                        onQuantityChanged: (quantity) =>
                            onQuantityChanged(product, quantity),
                        onCheckout: () => onCheckout(product),
                      );
                    },
                  );
                },
              );
            },
          ),
        ],
      ),
    );
  }
}

class _CommerceProductTile extends StatelessWidget {
  const _CommerceProductTile({
    required this.product,
    required this.checkoutBusy,
    required this.quantity,
    required this.onQuantityChanged,
    required this.onCheckout,
  });

  final CommerceProduct product;
  final bool checkoutBusy;
  final int quantity;
  final ValueChanged<int> onQuantityChanged;
  final VoidCallback onCheckout;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.07),
            blurRadius: 20,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _CommerceProductImage(product: product, height: 170),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      product.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      product.subtitle.isNotEmpty
                          ? product.subtitle
                          : product.description,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                        height: 1.38,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      product.priceLabel,
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w900),
                    ),
                    const SizedBox(height: 12),
                    _QuantitySelector(
                      quantity: quantity,
                      onChanged: onQuantityChanged,
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton(
                            onPressed: kIsWeb && !checkoutBusy
                                ? onCheckout
                                : null,
                            style: FilledButton.styleFrom(
                              backgroundColor: talkflixPrimary,
                              foregroundColor: Colors.white,
                            ),
                            child: Text(
                              checkoutBusy ? 'Opening...' : 'Buy now',
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        OutlinedButton(
                          onPressed: () =>
                              context.go('/coaching/${product.slug}'),
                          child: const Text('View'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CommerceProductImage extends StatelessWidget {
  const _CommerceProductImage({required this.product, required this.height});

  final CommerceProduct? product;
  final double height;

  @override
  Widget build(BuildContext context) {
    final imageUrl = product?.imageUrl.trim() ?? '';
    if (imageUrl.isEmpty) {
      return Container(
        height: height,
        width: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF18191D), Color(0xFF4A0D12)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: const Center(
          child: Icon(
            Icons.auto_awesome_rounded,
            color: Colors.white,
            size: 42,
          ),
        ),
      );
    }
    return Image.network(
      resolveMediaUrl(imageUrl),
      height: height,
      width: double.infinity,
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => Container(
        height: height,
        width: double.infinity,
        color: const Color(0xFF18191D),
        alignment: Alignment.center,
        child: const Icon(
          Icons.image_not_supported_outlined,
          color: Colors.white,
        ),
      ),
    );
  }
}

class _QuantitySelector extends StatelessWidget {
  const _QuantitySelector({
    required this.quantity,
    required this.onChanged,
    this.foregroundColor,
    this.borderColor,
  });

  final int quantity;
  final ValueChanged<int> onChanged;
  final Color? foregroundColor;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final safeQuantity = quantity.clamp(1, 99);
    final scheme = Theme.of(context).colorScheme;
    final color = foregroundColor ?? scheme.onSurface;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: borderColor ?? scheme.outlineVariant),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              visualDensity: VisualDensity.compact,
              color: color,
              disabledColor: color.withValues(alpha: 0.32),
              onPressed: safeQuantity <= 1
                  ? null
                  : () => onChanged(safeQuantity - 1),
              icon: const Icon(Icons.remove_rounded),
              tooltip: 'Decrease quantity',
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text(
                'Qty $safeQuantity',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              color: color,
              disabledColor: color.withValues(alpha: 0.32),
              onPressed: safeQuantity >= 99
                  ? null
                  : () => onChanged(safeQuantity + 1),
              icon: const Icon(Icons.add_rounded),
              tooltip: 'Increase quantity',
            ),
          ],
        ),
      ),
    );
  }
}

class _CoachingTopNav extends StatelessWidget {
  const _CoachingTopNav();

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 560;
    return Row(
      children: [
        InkWell(
          onTap: () => openPublicHome(context),
          borderRadius: BorderRadius.circular(8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 44,
                height: 44,
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Image.asset('assets/images/talkflix_logo.png'),
              ),
              const SizedBox(width: 12),
              const Text(
                'Talkflix',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
        ),
        const Spacer(),
        if (!compact)
          TextButton(
            onPressed: () => openPublicHome(context),
            style: TextButton.styleFrom(foregroundColor: Colors.white),
            child: const Text('Home'),
          ),
        TextButton(
          onPressed: () => context.go('/login'),
          style: TextButton.styleFrom(foregroundColor: Colors.white),
          child: const Text('Log in'),
        ),
      ],
    );
  }
}

class _HeroCopy extends StatelessWidget {
  const _HeroCopy({required this.product, required this.price});

  final CommerceProduct? product;
  final String price;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          product?.title.isNotEmpty == true
              ? product!.title
              : 'Private 1-on-1 Coaching',
          style: textTheme.displayLarge?.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w900,
            height: 0.98,
          ),
        ),
        const SizedBox(height: 20),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 700),
          child: Text(
            product?.description.isNotEmpty == true
                ? product!.description
                : 'A focused personal session with David Nwako to get clarity, direction, and a practical plan for the next step you need to take.',
            style: textTheme.headlineSmall?.copyWith(
              color: Colors.white.withValues(alpha: 0.9),
              fontWeight: FontWeight.w700,
              height: 1.24,
            ),
          ),
        ),
        const SizedBox(height: 24),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            _HeroPill(label: '$price introductory offer'),
            _HeroPill(
              label: product?.type == 'ebook'
                  ? 'Digital product'
                  : product?.type == 'podcast_subscription'
                  ? 'Podcast access'
                  : '1-on-1 private session',
            ),
            const _HeroPill(label: 'Stripe secure checkout'),
          ],
        ),
      ],
    );
  }
}

class _CheckoutCard extends StatelessWidget {
  const _CheckoutCard({
    required this.product,
    required this.price,
    required this.quantity,
    required this.loading,
    required this.disabled,
    required this.busy,
    required this.error,
    required this.productMissing,
    required this.onQuantityChanged,
    required this.onCheckout,
  });

  final CommerceProduct? product;
  final String price;
  final int quantity;
  final bool loading;
  final bool disabled;
  final bool busy;
  final bool error;
  final bool productMissing;
  final ValueChanged<int>? onQuantityChanged;
  final VoidCallback onCheckout;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.24),
            blurRadius: 28,
            offset: const Offset(0, 18),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              product?.title.isNotEmpty == true
                  ? product!.title
                  : productMissing
                  ? 'Product unavailable'
                  : '1-on-1 Coaching',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: Colors.black,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              product?.subtitle.isNotEmpty == true
                  ? product!.subtitle
                  : productMissing
                  ? 'This purchase link is no longer active.'
                  : 'Personal clarity, strategy, and next-step guidance.',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: Colors.black.withValues(alpha: 0.66),
                height: 1.4,
              ),
            ),
            const SizedBox(height: 22),
            Text(
              price,
              style: Theme.of(context).textTheme.displaySmall?.copyWith(
                color: Colors.black,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 18),
            if (product != null && onQuantityChanged != null) ...[
              _QuantitySelector(
                quantity: quantity,
                onChanged: onQuantityChanged!,
                foregroundColor: Colors.black,
                borderColor: Colors.black.withValues(alpha: 0.16),
              ),
              const SizedBox(height: 18),
            ],
            FilledButton.icon(
              onPressed: disabled || busy || !kIsWeb ? null : onCheckout,
              icon: busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.lock_rounded),
              label: Text(
                busy
                    ? 'Opening Stripe...'
                    : loading
                    ? 'Loading checkout...'
                    : error
                    ? 'Payment setup pending'
                    : kIsWeb
                    ? 'Book with Stripe'
                    : 'Available on web only',
              ),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
                backgroundColor: talkflixPrimary,
                foregroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              error
                  ? 'Stripe checkout is not reachable yet. Contact ${AppConfig.supportEmail} if you need immediate help.'
                  : 'You will be redirected to Stripe Checkout. Talkflix does not store card details.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeroPill extends StatelessWidget {
  const _HeroPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

class _CoachingOutcomes extends StatelessWidget {
  const _CoachingOutcomes();

  @override
  Widget build(BuildContext context) {
    return _CoachingBand(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionHeader(
            eyebrow: 'What you get',
            title: 'A direct session built around your real situation',
            copy:
                'This is not a generic course. The session is for people who want a focused conversation, honest direction, and practical next steps.',
          ),
          const SizedBox(height: 26),
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth >= 900
                  ? 3
                  : constraints.maxWidth >= 620
                  ? 2
                  : 1;
              return GridView.count(
                crossAxisCount: columns,
                crossAxisSpacing: 16,
                mainAxisSpacing: 16,
                childAspectRatio: columns == 1 ? 1.75 : 1.04,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                children: const [
                  _OutcomeCard(
                    icon: Icons.psychology_alt_outlined,
                    title: 'Clarity',
                    copy:
                        'Identify the core issue, remove noise, and define what needs attention first.',
                  ),
                  _OutcomeCard(
                    icon: Icons.route_outlined,
                    title: 'Direction',
                    copy:
                        'Leave with a practical path instead of vague motivation or scattered advice.',
                  ),
                  _OutcomeCard(
                    icon: Icons.task_alt_rounded,
                    title: 'Next steps',
                    copy:
                        'Convert the conversation into clear actions you can start applying immediately.',
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _CoachingDetails extends StatelessWidget {
  const _CoachingDetails();

  @override
  Widget build(BuildContext context) {
    return _CoachingBand(
      tint: true,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final desktop = constraints.maxWidth >= 860;
          const left = _SectionHeader(
            eyebrow: 'How it works',
            title: 'Simple booking, private conversation, clear follow-up',
            copy:
                'Pay securely with Stripe, then use the confirmation details to coordinate the coaching session. This offer is web-only and separate from Talkflix Pro subscriptions.',
          );
          const right = Column(
            children: [
              _StepTile(
                number: '01',
                title: 'Book the session',
                copy:
                    'Use Stripe Checkout to reserve the coaching offer securely.',
              ),
              _StepTile(
                number: '02',
                title: 'Share your focus',
                copy:
                    'Bring the main issue, goal, or decision you want to work through.',
              ),
              _StepTile(
                number: '03',
                title: 'Get direction',
                copy:
                    'Use the session to clarify the path and define practical next actions.',
              ),
            ],
          );
          if (!desktop) {
            return const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [left, SizedBox(height: 28), right],
            );
          }
          return const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 5, child: left),
              SizedBox(width: 48),
              Expanded(flex: 5, child: right),
            ],
          );
        },
      ),
    );
  }
}

class _CoachingFaq extends StatelessWidget {
  const _CoachingFaq();

  @override
  Widget build(BuildContext context) {
    return const _CoachingBand(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionHeader(
            eyebrow: 'FAQ',
            title: 'Important details before you book',
            copy:
                'The first version is intentionally simple so clients can pay quickly while the full Talkflix commerce system grows safely.',
          ),
          SizedBox(height: 24),
          _FaqItem(
            question: 'Is this part of Talkflix Pro?',
            answer:
                'No. Talkflix Pro controls app limits. Private coaching is a separate web-only purchase.',
          ),
          _FaqItem(
            question: 'Is payment handled by Talkflix?',
            answer:
                'Payment is processed by Stripe Checkout. Talkflix never stores card details.',
          ),
          _FaqItem(
            question: 'Can ebooks or podcast subscriptions be added later?',
            answer:
                'Yes. The backend product model is designed for coaching, ebooks, and podcast subscriptions, but only approved active products should be shown publicly.',
          ),
        ],
      ),
    );
  }
}

class _CoachingFooter extends StatelessWidget {
  const _CoachingFooter();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF111113),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1180),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 28, 20, 28),
            child: Wrap(
              spacing: 18,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TextButton(
                  onPressed: () => openPublicHome(context),
                  style: TextButton.styleFrom(foregroundColor: Colors.white),
                  child: const Text('Talkflix home'),
                ),
                TextButton(
                  onPressed: () => context.go('/terms-of-service'),
                  style: TextButton.styleFrom(foregroundColor: Colors.white),
                  child: const Text('Terms of Service'),
                ),
                TextButton(
                  onPressed: () => context.go('/privacy-policy'),
                  style: TextButton.styleFrom(foregroundColor: Colors.white),
                  child: const Text('Privacy Policy'),
                ),
                Text(
                  '(c) 2026 Talkflix. All rights reserved.',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.62),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CoachingBand extends StatelessWidget {
  const _CoachingBand({required this.child, this.tint = false});

  final Widget child;
  final bool tint;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: tint
          ? scheme.surfaceContainerHighest.withValues(alpha: 0.45)
          : scheme.surface,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1180),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 62, 20, 54),
            child: child,
          ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.eyebrow,
    required this.title,
    required this.copy,
  });

  final String eyebrow;
  final String title;
  final String copy;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            eyebrow.toUpperCase(),
            style: textTheme.labelLarge?.copyWith(
              color: talkflixPrimary,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            title,
            style: textTheme.displaySmall?.copyWith(
              fontWeight: FontWeight.w900,
              height: 1.08,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            copy,
            style: textTheme.bodyLarge?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.55,
            ),
          ),
        ],
      ),
    );
  }
}

class _OutcomeCard extends StatelessWidget {
  const _OutcomeCard({
    required this.icon,
    required this.title,
    required this.copy,
  });

  final IconData icon;
  final String title;
  final String copy;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: talkflixPrimary, size: 34),
            const SizedBox(height: 16),
            Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Text(
                copy,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.45,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StepTile extends StatelessWidget {
  const _StepTile({
    required this.number,
    required this.title,
    required this.copy,
  });

  final String number;
  final String title;
  final String copy;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                number,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: talkflixPrimary,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      copy,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FaqItem extends StatelessWidget {
  const _FaqItem({required this.question, required this.answer});

  final String question;
  final String answer;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                question,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 6),
              Text(
                answer,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
