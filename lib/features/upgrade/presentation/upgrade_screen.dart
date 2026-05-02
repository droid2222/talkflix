import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/session_controller.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/widgets/feature_scaffold.dart';
import '../../auth/data/auth_repository.dart';

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
    return FeatureScaffold(
      title: 'Upgrade',
      children: [
        SectionCard(
          title: 'Plan foundation',
          subtitle:
              'The backend already supports a trial start endpoint. Subscription checkout can be layered in once the mobile purchase strategy is defined.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_message != null) ...[
                Text(_message!),
                const SizedBox(height: 12),
              ],
              if (_error != null) ...[
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                const SizedBox(height: 12),
              ],
              FilledButton(
                onPressed: _loading ? null : _startTrial,
                child: Text(_loading ? 'Starting...' : 'Start trial'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
