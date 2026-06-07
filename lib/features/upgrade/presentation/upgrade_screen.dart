import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/session_controller.dart';
import '../../../core/config/app_config.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/widgets/feature_scaffold.dart';
import '../../auth/data/auth_repository.dart';
import 'pro_purchase_controller.dart';

class UpgradeScreen extends ConsumerStatefulWidget {
  const UpgradeScreen({super.key});

  @override
  ConsumerState<UpgradeScreen> createState() => _UpgradeScreenState();
}

class _UpgradeScreenState extends ConsumerState<UpgradeScreen> {
  bool _loading = false;
  String? _message;
  String? _error;

  Future<void> _startTrial() async {
    setState(() {
      _loading = true;
      _message = null;
      _error = null;
    });

    try {
      final result = await ref.read(authRepositoryProvider).startTrial();
      await ref
          .read(sessionControllerProvider.notifier)
          .setAuthenticated(
            token: result.token,
            sessionId: result.sessionId,
            user: result.user,
          );
      setState(() => _message = 'Trial started successfully.');
    } on ApiException catch (error) {
      setState(() => _error = error.message);
    } catch (_) {
      setState(() => _error = 'Could not reach the backend.');
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionControllerProvider);
    final user = session.user;
    final purchaseState = ref.watch(proPurchaseControllerProvider);
    final purchaseController = ref.read(proPurchaseControllerProvider.notifier);
    final theme = Theme.of(context);
    final isProLike = user?.isProLike == true;
    final canStartTrial = user != null && !user.trialUsed && !isProLike;

    return FeatureScaffold(
      title: 'Upgrade',
      children: [
        SectionCard(
          title: 'Talkflix Pro',
          subtitle:
              'Remove daily limits from the features people use most: content, direct calls, live rooms, hosting, stage time, and chat translation.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (isProLike) ...[
                _StatusBanner(
                  text: user!.plan == 'trial'
                      ? 'Your free trial access is active.'
                      : 'Talkflix Pro is active on this account.',
                  color: const Color(0xFF0F8A4B),
                ),
                const SizedBox(height: 14),
              ],
              if (_message != null) ...[
                _StatusBanner(text: _message!, color: const Color(0xFF0F8A4B)),
                const SizedBox(height: 12),
              ],
              if (purchaseState.message != null) ...[
                _StatusBanner(
                  text: purchaseState.message!,
                  color: const Color(0xFF0F8A4B),
                ),
                const SizedBox(height: 12),
              ],
              if (_error != null) ...[
                _StatusBanner(text: _error!, color: theme.colorScheme.error),
                const SizedBox(height: 12),
              ],
              if (purchaseState.error != null) ...[
                _StatusBanner(
                  text: purchaseState.error!,
                  color: theme.colorScheme.error,
                ),
                const SizedBox(height: 12),
              ],
              const _ProPromiseCard(),
              const SizedBox(height: 16),
              Text(
                'Choose your plan',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Billing, renewal terms, and cancellation are handled by Apple App Store or Google Play before you confirm.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 14),
              if (purchaseState.loadingProducts) ...[
                const Center(child: CircularProgressIndicator()),
                const SizedBox(height: 12),
              ] else if (!purchaseState.storeAvailable) ...[
                Text(
                  AppConfig.paidUpgradeEnabled
                      ? 'Pro plans are not available from the store on this device right now.'
                      : 'Paid upgrades are disabled for this build.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: purchaseState.busy
                      ? null
                      : purchaseController.loadProducts,
                  child: const Text('Try again'),
                ),
                const SizedBox(height: 12),
              ] else if (purchaseState.products.isEmpty) ...[
                Text(
                  'The store did not return available Pro plans yet. Confirm the product IDs are configured in App Store Connect and Play Console.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: purchaseState.busy
                      ? null
                      : purchaseController.loadProducts,
                  child: const Text('Reload plans'),
                ),
                const SizedBox(height: 12),
              ] else ...[
                for (final product in purchaseState.products) ...[
                  _ProPlanCard(
                    title: _planTitle(product.id, product.title),
                    description: product.description.isEmpty
                        ? 'Auto-renewing Talkflix Pro subscription.'
                        : product.description,
                    price: product.price,
                    loading:
                        purchaseState.buyingProductId == product.id ||
                        purchaseState.processingPurchase,
                    disabled: purchaseState.busy || isProLike,
                    onPressed: () => purchaseController.buy(product),
                  ),
                  const SizedBox(height: 12),
                ],
              ],
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: purchaseState.busy
                      ? null
                      : purchaseController.restore,
                  child: Text(
                    purchaseState.restoring
                        ? 'Restoring...'
                        : 'Restore purchases',
                  ),
                ),
              ),
              if (canStartTrial) ...[
                const SizedBox(height: 18),
                Divider(color: theme.colorScheme.outlineVariant),
                const SizedBox(height: 14),
                Text(
                  'Not ready to subscribe?',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Start your one-time free trial first. After it ends, subscribe through the store to keep Pro active.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.tonal(
                  onPressed: _loading ? null : _startTrial,
                  child: Text(_loading ? 'Starting...' : 'Start free trial'),
                ),
              ] else if (!isProLike && user?.trialUsed == true) ...[
                const SizedBox(height: 14),
                Text(
                  'Your free trial has already been used. Choose a Pro plan above to continue.',
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  String _planTitle(String productId, String storeTitle) {
    final normalizedId = productId.toLowerCase();
    if (normalizedId.contains('6') && normalizedId.contains('month')) {
      return 'Talkflix Pro 6 Months';
    }
    if ((normalizedId.contains('3') && normalizedId.contains('month')) ||
        normalizedId.contains('quarter')) {
      return 'Talkflix Pro 3 Months';
    }
    if (normalizedId.contains('year')) return 'Talkflix Pro Yearly';
    if (normalizedId.contains('month')) return 'Talkflix Pro Monthly';
    return storeTitle.trim().isEmpty ? 'Talkflix Pro' : storeTitle.trim();
  }
}

class _ProPromiseCard extends StatelessWidget {
  const _ProPromiseCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(
          colors: [Color(0xFF101827), Color(0xFF263B68)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Uninterrupted Talkflix',
            style: theme.textTheme.titleLarge?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Free users can try the full app, but Pro removes the daily waits and time caps.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: Colors.white.withValues(alpha: 0.82),
            ),
          ),
          const SizedBox(height: 14),
          const Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _ProBenefitPill(
                icon: Icons.play_circle_outline_rounded,
                label: 'Unlimited videos and podcasts',
              ),
              _ProBenefitPill(
                icon: Icons.call_outlined,
                label: 'Unlimited direct calls',
              ),
              _ProBenefitPill(
                icon: Icons.groups_2_outlined,
                label: 'Unlimited live room audience time',
              ),
              _ProBenefitPill(
                icon: Icons.mic_external_on_outlined,
                label: 'Unlimited hosting and stage time',
              ),
              _ProBenefitPill(
                icon: Icons.translate_rounded,
                label: 'Unlimited chat translations',
              ),
              _ProBenefitPill(
                icon: Icons.travel_explore_rounded,
                label: 'Advanced partner discovery',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ProBenefitPill extends StatelessWidget {
  const _ProBenefitPill({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 18),
          const SizedBox(width: 8),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
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
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(text, style: TextStyle(color: color)),
    );
  }
}

class _ProPlanCard extends StatelessWidget {
  const _ProPlanCard({
    required this.title,
    required this.description,
    required this.price,
    required this.loading,
    required this.disabled,
    required this.onPressed,
  });

  final String title;
  final String description;
  final String price;
  final bool loading;
  final bool disabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      description,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Text(
                price,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: disabled ? null : onPressed,
              child: Text(loading ? 'Processing...' : 'Subscribe'),
            ),
          ),
        ],
      ),
    );
  }
}
