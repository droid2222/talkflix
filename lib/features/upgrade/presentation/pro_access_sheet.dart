import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/session_controller.dart';
import '../../../core/widgets/talkflix_pro_badge.dart';

class ProFeatureBadge extends StatelessWidget {
  const ProFeatureBadge({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    return TalkflixProBadge(compact: compact);
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
  if (me.isProLike) {
    onUnlocked?.call();
    return;
  }

  final encodedFeature = Uri.encodeQueryComponent(featureName.trim());
  if (!context.mounted) return;
  context.go('/app/upgrade?feature=$encodedFeature');
}
