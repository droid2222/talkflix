import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/auth/app_user.dart';
import '../../../core/auth/session_controller.dart';
import '../../../core/network/api_exception.dart';
import '../../auth/data/auth_repository.dart';

class ProFeatureBadge extends StatelessWidget {
  const ProFeatureBadge({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 10 : 12,
        vertical: compact ? 5 : 6,
      ),
      decoration: BoxDecoration(
        color: const Color(0xFF64B5FF),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.workspace_premium_rounded,
            size: compact ? 16 : 18,
            color: Colors.white,
          ),
          const SizedBox(width: 5),
          Text(
            'Pro',
            style: TextStyle(
              color: Colors.white,
              fontSize: compact ? 12 : 13,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> showProAccessSheet({
  required BuildContext context,
  required WidgetRef ref,
  required String featureName,
  VoidCallback? onUnlocked,
}) async {
  final me = ref.read(sessionControllerProvider).user;
  if (me == null) return;

  await showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (dialogContext) {
      return _ProAccessDialog(
        user: me,
        featureName: featureName,
        onUnlocked: onUnlocked,
      );
    },
  );
}

class _ProAccessDialog extends ConsumerStatefulWidget {
  const _ProAccessDialog({
    required this.user,
    required this.featureName,
    this.onUnlocked,
  });

  final AppUser user;
  final String featureName;
  final VoidCallback? onUnlocked;

  @override
  ConsumerState<_ProAccessDialog> createState() => _ProAccessDialogState();
}

class _ProAccessDialogState extends ConsumerState<_ProAccessDialog> {
  bool _loading = false;
  String? _error;

  Future<void> _startTrial() async {
    setState(() {
      _loading = true;
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
      if (!mounted) return;
      Navigator.of(context).pop();
      widget.onUnlocked?.call();
    } on ApiException catch (error) {
      setState(() {
        _loading = false;
        _error = error.message;
      });
    } catch (_) {
      setState(() {
        _loading = false;
        _error = 'Could not start your trial right now.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final showTrial = !widget.user.trialUsed;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(28),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
              decoration: const BoxDecoration(
                borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
                gradient: LinearGradient(
                  colors: [Color(0xFFFFF2F4), Color(0xFFFFE7EB)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: Column(
                children: [
                  Align(
                    alignment: Alignment.topLeft,
                    child: IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ),
                  const ProFeatureBadge(),
                  const SizedBox(height: 10),
                  Text(
                    'Unlock ${widget.featureName}',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    showTrial
                        ? 'Start your 7 days free trial to use this Pro feature now.'
                        : 'This is a Pro-only feature. Upgrade to keep using advanced search tools.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 22),
              child: Column(
                children: [
                  if (_error != null) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0x19E50914),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Text(
                        _error!,
                        style: const TextStyle(color: talkflixPrimary),
                      ),
                    ),
                    const SizedBox(height: 14),
                  ],
                  if (showTrial) ...[
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _loading ? null : _startTrial,
                        child: Text(
                          _loading ? 'Starting...' : 'Start 7 Days Free Trial',
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: _loading
                          ? null
                          : () {
                              Navigator.of(context).pop();
                              if (context.mounted) {
                                context.go('/app/upgrade');
                              }
                            },
                      child: Text(showTrial ? 'See Pro plans' : 'Upgrade to Pro'),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextButton(
                    onPressed: _loading ? null : () => Navigator.of(context).pop(),
                    child: const Text('No thanks'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
