import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/localization/talkflix_localizations.dart';
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
    final l10n = context.l10n;

    if (email.isEmpty) {
      setState(() => _error = l10n.pleaseEnterEmail);
      return;
    }
    if (password.trim().isEmpty) {
      setState(() => _error = l10n.pleaseEnterPassword);
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
      setState(() => _error = l10n.signInFailed);
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);

    return AuthShell(
      brandPanel: AuthBrandPanel(
        title: l10n.appTitle,
        copy: l10n.authBrandCopy,
      ),
      cardChild: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Center(
            child: Column(
              children: [
                Text(
                  l10n.welcomeBack,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontSize: 28.8,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  l10n.signInSubtitle,
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
            hintText: l10n.email,
          ),
          const SizedBox(height: 14),
          _AuthInput(
            controller: _passwordController,
            obscureText: true,
            hintText: l10n.password,
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
                      l10n.rememberEmail,
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
                child: Text(l10n.forgotPassword),
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
              child: Text(_submitting ? l10n.signingIn : l10n.signIn),
            ),
          ),
          const SizedBox(height: 19),
          Center(
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  '${l10n.newHere} ',
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
                  child: Text(l10n.createAccount),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AuthInput extends StatefulWidget {
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
  State<_AuthInput> createState() => _AuthInputState();
}

class _AuthInputState extends State<_AuthInput> {
  late bool _obscured = widget.obscureText;

  void _toggleObscured() {
    setState(() => _obscured = !_obscured);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return TextField(
      controller: widget.controller,
      keyboardType: widget.keyboardType,
      obscureText: _obscured,
      decoration: InputDecoration(
        hintText: widget.hintText,
        suffixIconConstraints: widget.obscureText
            ? const BoxConstraints(minWidth: 88, minHeight: 0)
            : null,
        suffixIcon: widget.obscureText
            ? TextButton(
                onPressed: _toggleObscured,
                style: TextButton.styleFrom(
                  foregroundColor: talkflixPrimary,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(_obscured ? l10n.show : l10n.hide),
              )
            : null,
      ),
    );
  }
}
