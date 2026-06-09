import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/auth/session_controller.dart';
import '../../../core/config/app_config.dart';
import '../../../core/navigation/public_home_navigation.dart';

class AccountDeletionScreen extends ConsumerWidget {
  const AccountDeletionScreen({super.key});

  Future<void> _openDeletionEmail(BuildContext context) async {
    final opened = await launchUrl(AppConfig.accountDeletionEmailUri);
    if (!context.mounted || opened) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Could not open your email app.')),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final isAuthenticated = ref.watch(
      sessionControllerProvider.select((session) => session.isAuthenticated),
    );
    final accountActionRoute = isAuthenticated
        ? '/app/profile/settings/account'
        : '/login';
    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        title: const Text('Account Deletion'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () {
            if (Navigator.of(context).canPop()) {
              context.pop();
            } else {
              openPublicHome(context);
            }
          },
        ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 920),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 42),
              children: [
                Text(
                  'Delete your Talkflix account',
                  style: textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w900,
                    height: 1.08,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Use this page if you need to delete your account or request deletion without reinstalling the app.',
                  style: textTheme.bodyLarge?.copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.45,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 24),
                _DeletionStepCard(
                  icon: Icons.phone_iphone_rounded,
                  title: 'Delete from inside Talkflix',
                  body:
                      'If you can sign in, open Profile, open Settings, tap Delete Account, enter your current password, type DELETE, and confirm. The app sends the deletion request directly to Talkflix.',
                  action: FilledButton.icon(
                    onPressed: () => context.go(accountActionRoute),
                    icon: const Icon(Icons.login_rounded),
                    label: Text(
                      isAuthenticated ? 'Open settings' : 'Go to login',
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                _DeletionStepCard(
                  icon: Icons.email_outlined,
                  title: 'Request deletion by email',
                  body:
                      'If you cannot access the app, email Talkflix from the email address on your account. Include your account email and username if known. Do not send your password.',
                  action: OutlinedButton.icon(
                    onPressed: () => _openDeletionEmail(context),
                    icon: const Icon(Icons.email_outlined),
                    label: const Text('Email deletion request'),
                  ),
                ),
                const SizedBox(height: 24),
                const _InfoPanel(
                  title: 'What deletion does',
                  paragraphs: [
                    'When an account is deleted in the current app, the account is removed from normal sign-in, public profile access, discovery, direct-call receiving, and visible profile fields.',
                    'Some records may be retained where needed for legal, safety, security, abuse-prevention, backup, dispute-resolution, or legitimate business-record purposes.',
                  ],
                ),
                const SizedBox(height: 14),
                _InfoPanel(
                  title: 'Need privacy help?',
                  paragraphs: const [
                    'For access, correction, deletion, or other privacy requests, contact Talkflix support. We may need to verify that the request belongs to the account owner before acting on it.',
                  ],
                  footer: Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    children: [
                      TextButton.icon(
                        onPressed: () => context.go('/privacy-policy'),
                        icon: const Icon(Icons.privacy_tip_outlined),
                        label: const Text('Privacy Policy'),
                      ),
                      TextButton.icon(
                        onPressed: () => _openDeletionEmail(context),
                        icon: const Icon(Icons.email_outlined),
                        label: const Text(AppConfig.supportEmail),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  '(c) 2026 Talkflix. All rights reserved.',
                  style: textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
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

class _DeletionStepCard extends StatelessWidget {
  const _DeletionStepCard({
    required this.icon,
    required this.title,
    required this.body,
    required this.action,
  });

  final IconData icon;
  final String title;
  final String body;
  final Widget action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: scheme.primary, size: 30),
            const SizedBox(height: 12),
            Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 8),
            Text(
              body,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                height: 1.5,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: 16),
            action,
          ],
        ),
      ),
    );
  }
}

class _InfoPanel extends StatelessWidget {
  const _InfoPanel({
    required this.title,
    required this.paragraphs,
    this.footer,
  });

  final String title;
  final List<String> paragraphs;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 8),
            for (final paragraph in paragraphs) ...[
              Text(
                paragraph,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  height: 1.5,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: 10),
            ],
            if (footer != null) ...[const SizedBox(height: 2), footer!],
          ],
        ),
      ),
    );
  }
}
