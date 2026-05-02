import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/auth/session_controller.dart';
import '../../../core/config/storage_keys.dart';
import '../../../core/network/api_exception.dart';
import 'auth_shell.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  var _remember = false;
  var _submitting = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    Future<void>.microtask(_loadRememberedEmail);
  }

  Future<void> _loadRememberedEmail() async {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    final rememberSaved = prefs.getBool(StorageKeys.rememberLogin) ?? false;
    if (!mounted) return;
    setState(() {
      _remember = rememberSaved;
      if (rememberSaved) {
        _emailController.text = prefs.getString(StorageKeys.savedEmail) ?? '';
      }
    });
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (email.isEmpty) {
      setState(() => _error = 'Please enter your email.');
      return;
    }
    if (password.trim().isEmpty) {
      setState(() => _error = 'Please enter your password.');
      return;
    }

    setState(() {
      _submitting = true;
      _error = '';
    });

    try {
      await ref
          .read(sessionControllerProvider.notifier)
          .signIn(email: email, password: password);

      if (!mounted) return;

      final prefs = await ref.read(sharedPreferencesProvider.future);
      await prefs.setBool(StorageKeys.rememberLogin, _remember);
      if (_remember) {
        await prefs.setString(StorageKeys.savedEmail, email);
      } else {
        await prefs.remove(StorageKeys.savedEmail);
      }
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
    } catch (_) {
      if (!mounted) return;
      setState(
        () => _error = 'We could not sign you in right now. Please try again.',
      );
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AuthShell(
      brandPanel: const AuthBrandPanel(
        title: 'Talkflix',
        copy:
            'Connect with people worldwide, practice languages naturally, and continue your conversations across chat, voice, and video.',
      ),
      cardChild: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Center(
            child: Column(
              children: [
                Text(
                  'Welcome back',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontSize: 28.8,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Sign in to continue your chats and matches.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontSize: 15.2,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          _AuthInput(
            controller: _emailController,
            keyboardType: TextInputType.emailAddress,
            hintText: 'Email',
          ),
          const SizedBox(height: 14),
          _AuthInput(
            controller: _passwordController,
            obscureText: true,
            hintText: 'Password',
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  children: [
                    Checkbox(
                      value: _remember,
                      onChanged: (value) =>
                          setState(() => _remember = value ?? false),
                    ),
                    Text(
                      'Remember email',
                      style: theme.textTheme.bodySmall?.copyWith(fontSize: 14),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: () => context.go('/forgot-password'),
                style: TextButton.styleFrom(
                  foregroundColor: talkflixPrimary,
                  padding: EdgeInsets.zero,
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('Forgot password?'),
              ),
            ],
          ),
          if (_error.isNotEmpty) ...[
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: talkflixPrimary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                _error,
                style: const TextStyle(color: talkflixPrimary),
              ),
            ),
          ],
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _submitting ? null : _submit,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                textStyle: const TextStyle(fontWeight: FontWeight.w800),
              ),
              child: Text(_submitting ? 'Signing in...' : 'Sign In'),
            ),
          ),
          const SizedBox(height: 19),
          Center(
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  'New here? ',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: 14.4,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                TextButton(
                  onPressed: () => context.go('/signup'),
                  style: TextButton.styleFrom(
                    foregroundColor: talkflixPrimary,
                    padding: EdgeInsets.zero,
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('Create an account'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AuthInput extends StatelessWidget {
  const _AuthInput({
    required this.controller,
    required this.hintText,
    this.keyboardType,
    this.obscureText = false,
  });

  final TextEditingController controller;
  final String hintText;
  final TextInputType? keyboardType;
  final bool obscureText;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      obscureText: obscureText,
      decoration: InputDecoration(hintText: hintText),
    );
  }
}
