import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';

final commerceRepositoryProvider = Provider<CommerceRepository>((ref) {
  return CommerceRepository(ref.watch(apiClientProvider));
});

final commerceProductsProvider =
    FutureProvider.autoDispose<List<CommerceProduct>>((ref) {
      return ref.watch(commerceRepositoryProvider).fetchProducts();
    });

final commerceProductProvider = FutureProvider.autoDispose
    .family<CommerceProduct?, String>((ref, slug) {
      return ref.watch(commerceRepositoryProvider).fetchProduct(slug);
    });

class CommerceRepository {
  CommerceRepository(this._apiClient);

  final ApiClient _apiClient;

  Future<List<CommerceProduct>> fetchProducts() async {
    final json = await _apiClient.getJson('/commerce/products');
    final rawProducts = json['products'];
    if (rawProducts is! List) return const <CommerceProduct>[];
    return rawProducts
        .whereType<Map<String, dynamic>>()
        .map(CommerceProduct.fromJson)
        .where((product) => product.active)
        .toList(growable: false);
  }

  Future<CommerceProduct?> fetchProduct(String slug) async {
    final cleanSlug = slug.trim();
    if (cleanSlug.isEmpty) return null;
    final json = await _apiClient.getJson(
      '/commerce/products/${Uri.encodeComponent(cleanSlug)}',
    );
    final rawProduct = json['product'];
    if (rawProduct is! Map<String, dynamic>) return null;
    final product = CommerceProduct.fromJson(rawProduct);
    return product.active ? product : null;
  }

  Future<Uri> createCheckoutSession({
    required String productId,
    String? customerEmail,
    String? customerName,
    String? note,
  }) async {
    final json = await _apiClient.postJson(
      '/commerce/checkout-sessions',
      body: <String, dynamic>{
        'productId': productId,
        if ((customerEmail ?? '').trim().isNotEmpty)
          'customerEmail': customerEmail!.trim(),
        if ((customerName ?? '').trim().isNotEmpty)
          'customerName': customerName!.trim(),
        if ((note ?? '').trim().isNotEmpty) 'note': note!.trim(),
      },
      timeout: const Duration(seconds: 20),
      retries: 0,
    );
    final rawUrl = json['url']?.toString().trim() ?? '';
    final uri = Uri.tryParse(rawUrl);
    if (uri == null || !uri.hasScheme) {
      throw StateError('The checkout session did not return a valid URL.');
    }
    return uri;
  }
}

class CommerceProduct {
  const CommerceProduct({
    required this.id,
    required this.type,
    required this.title,
    required this.subtitle,
    required this.description,
    required this.currency,
    required this.amountCents,
    required this.priceLabel,
    required this.active,
    required this.slug,
    required this.shareUrl,
  });

  final String id;
  final String slug;
  final String type;
  final String title;
  final String subtitle;
  final String description;
  final String currency;
  final int amountCents;
  final String priceLabel;
  final bool active;
  final String shareUrl;

  factory CommerceProduct.fromJson(Map<String, dynamic> json) {
    return CommerceProduct(
      id: json['id']?.toString() ?? '',
      slug: json['slug']?.toString() ?? '',
      type: json['type']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      subtitle: json['subtitle']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      currency: json['currency']?.toString() ?? 'USD',
      amountCents: _intValue(json['amountCents']),
      priceLabel: json['priceLabel']?.toString() ?? '',
      active: json['active'] != false,
      shareUrl: json['shareUrl']?.toString() ?? '',
    );
  }

  static int _intValue(Object? value) {
    if (value is int) return value;
    if (value is num) return value.round();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}
