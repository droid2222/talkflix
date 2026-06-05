import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../../app/localization/talkflix_localizations.dart';
import '../../../core/auth/session_controller.dart';
import '../../../core/widgets/feature_scaffold.dart';
import '../data/signup_options.dart';
import 'auth_shell.dart';
import 'signup_controller.dart';

class SignupScreen extends ConsumerStatefulWidget {
  const SignupScreen({super.key});

  @override
  ConsumerState<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends ConsumerState<SignupScreen> {
  final _picker = ImagePicker();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _codeController = TextEditingController();
  final _displayNameController = TextEditingController();
  final _dobController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _emailController.addListener(() {
      ref
          .read(signupControllerProvider.notifier)
          .updateEmail(_emailController.text);
    });
    _passwordController.addListener(() {
      ref
          .read(signupControllerProvider.notifier)
          .updatePassword(_passwordController.text);
    });
    _codeController.addListener(() {
      ref
          .read(signupControllerProvider.notifier)
          .updateCode(_codeController.text);
    });
    _displayNameController.addListener(() {
      ref
          .read(signupControllerProvider.notifier)
          .updateDisplayName(_displayNameController.text);
    });
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _codeController.dispose();
    _displayNameController.dispose();
    _dobController.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    final file = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1600,
      imageQuality: 88,
    );
    if (file == null) return;
    final bytes = await file.readAsBytes();
    ref
        .read(signupControllerProvider.notifier)
        .setProfilePhoto(
          bytes: bytes,
          mimeType: file.mimeType ?? 'image/jpeg',
          name: file.name,
        );
  }

  Future<void> _submit() async {
    final result = await ref.read(signupControllerProvider.notifier).submit();
    if (result == null || !mounted) return;
    await ref
        .read(sessionControllerProvider.notifier)
        .setAuthenticated(
          token: result.token,
          sessionId: result.sessionId,
          user: result.user,
        );
    if (!mounted) return;
    final next = GoRouterState.of(context).uri.queryParameters['next'] ?? '';
    Uri? target;
    try {
      target = Uri.tryParse(Uri.decodeComponent(next));
    } catch (_) {
      target = null;
    }
    if (target != null &&
        target.hasAbsolutePath &&
        !target.path.startsWith('//')) {
      context.go(target.toString());
      return;
    }
    context.go('/app/content');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = ref.watch(signupControllerProvider);
    final controller = ref.read(signupControllerProvider.notifier);
    _syncController(_emailController, state.email);
    _syncController(_passwordController, state.password);
    _syncController(_codeController, state.code);
    _syncController(_displayNameController, state.displayName);
    _syncController(_dobController, state.dob);

    final backAction = state.step == SignupStep.account
        ? () => context.go('/login')
        : controller.previousStep;

    return AuthShell(
      showBackButton: true,
      onBack: state.busy ? null : backAction,
      maxCardWidth: 560,
      brandPanel: AuthBrandPanel(
        title: l10n.createAccount,
        copy: l10n.authBrandCopy,
      ),
      cardChild: LayoutBuilder(
        builder: (context, constraints) {
          final roomy = constraints.maxWidth >= 500;
          final stepChildren = <Widget>[
            if (state.step == SignupStep.account) ...[
              SectionCard(
                title: l10n.accountVerification,
                subtitle: l10n.accountVerificationSubtitle,
                child: const SizedBox.shrink(),
              ),
              if (roomy)
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _emailController,
                        keyboardType: TextInputType.emailAddress,
                        decoration: InputDecoration(labelText: l10n.email),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _passwordController,
                        obscureText: true,
                        decoration: InputDecoration(
                          labelText: l10n.passwordMinSixLabel,
                        ),
                      ),
                    ),
                  ],
                )
              else ...[
                TextField(
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  decoration: InputDecoration(labelText: l10n.email),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _passwordController,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: l10n.passwordMinSixLabel,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              if (roomy)
                Row(
                  children: [
                    Expanded(child: _SendCodeButton(state: state)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _codeController,
                        decoration: InputDecoration(
                          labelText: l10n.verificationCode,
                        ),
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: state.busy ? null : controller.verifyCode,
                        child: Text(
                          state.verified ? l10n.verified : l10n.verifyCode,
                        ),
                      ),
                    ),
                  ],
                )
              else ...[
                _SendCodeButton(state: state),
                const SizedBox(height: 12),
                TextField(
                  controller: _codeController,
                  decoration: InputDecoration(labelText: l10n.verificationCode),
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: state.busy ? null : controller.verifyCode,
                    child: Text(
                      state.verified ? l10n.verified : l10n.verifyCode,
                    ),
                  ),
                ),
              ],
            ],
            if (state.step == SignupStep.profile) ...[
              if (roomy)
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _displayNameController,
                        decoration: InputDecoration(
                          labelText: l10n.displayName,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        decoration: InputDecoration(
                          labelText: l10n.dateOfBirth,
                        ),
                        readOnly: true,
                        controller: _dobController,
                        onTap: () => unawaited(_pickDob(controller)),
                      ),
                    ),
                  ],
                )
              else ...[
                TextField(
                  controller: _displayNameController,
                  decoration: InputDecoration(labelText: l10n.displayName),
                ),
                const SizedBox(height: 12),
                TextField(
                  decoration: InputDecoration(labelText: l10n.dateOfBirth),
                  readOnly: true,
                  controller: _dobController,
                  onTap: () => unawaited(_pickDob(controller)),
                ),
              ],
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<String>(
                  emptySelectionAllowed: true,
                  segments: [
                    ButtonSegment(value: 'male', label: Text(l10n.male)),
                    ButtonSegment(value: 'female', label: Text(l10n.female)),
                  ],
                  selected: state.gender.isEmpty ? const {} : {state.gender},
                  onSelectionChanged: (selection) {
                    if (selection.isNotEmpty) {
                      controller.updateGender(selection.first);
                    }
                  },
                ),
              ),
            ],
            if (state.step == SignupStep.languages) ...[
              DropdownButtonFormField<String>(
                initialValue: state.fromCountry.isEmpty
                    ? null
                    : state.fromCountry,
                items: countryOptions
                    .map(
                      (option) => DropdownMenuItem<String>(
                        value: option['code'],
                        child: Text(option['label']!),
                      ),
                    )
                    .toList(),
                onChanged: (value) => controller.updateFromCountry(value ?? ''),
                decoration: InputDecoration(labelText: l10n.whereYouAreFrom),
              ),
              const SizedBox(height: 12),
              if (roomy)
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: state.firstLanguage.isEmpty
                            ? null
                            : state.firstLanguage,
                        items: languageOptions
                            .map(
                              (option) => DropdownMenuItem<String>(
                                value: option,
                                child: Text(option),
                              ),
                            )
                            .toList(),
                        onChanged: (value) =>
                            controller.updateFirstLanguage(value ?? ''),
                        decoration: InputDecoration(
                          labelText: l10n.firstLanguage,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: state.learnLanguage.isEmpty
                            ? null
                            : state.learnLanguage,
                        items: languageOptions
                            .map(
                              (option) => DropdownMenuItem<String>(
                                value: option,
                                child: Text(option),
                              ),
                            )
                            .toList(),
                        onChanged: (value) =>
                            controller.updateLearnLanguage(value ?? ''),
                        decoration: InputDecoration(
                          labelText: l10n.languageToLearn,
                        ),
                      ),
                    ),
                  ],
                )
              else ...[
                DropdownButtonFormField<String>(
                  initialValue: state.firstLanguage.isEmpty
                      ? null
                      : state.firstLanguage,
                  items: languageOptions
                      .map(
                        (option) => DropdownMenuItem<String>(
                          value: option,
                          child: Text(option),
                        ),
                      )
                      .toList(),
                  onChanged: (value) =>
                      controller.updateFirstLanguage(value ?? ''),
                  decoration: InputDecoration(labelText: l10n.firstLanguage),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: state.learnLanguage.isEmpty
                      ? null
                      : state.learnLanguage,
                  items: languageOptions
                      .map(
                        (option) => DropdownMenuItem<String>(
                          value: option,
                          child: Text(option),
                        ),
                      )
                      .toList(),
                  onChanged: (value) =>
                      controller.updateLearnLanguage(value ?? ''),
                  decoration: InputDecoration(labelText: l10n.languageToLearn),
                ),
              ],
            ],
            if (state.step == SignupStep.photo) ...[
              SectionCard(
                title: l10n.profilePhoto,
                subtitle: l10n.profilePhotoSubtitle,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (state.profilePhotoBytes != null)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(20),
                        child: Image.memory(
                          state.profilePhotoBytes!,
                          height: 180,
                          width: 180,
                          fit: BoxFit.cover,
                        ),
                      ),
                    const SizedBox(height: 12),
                    OutlinedButton(
                      onPressed: _pickPhoto,
                      child: Text(
                        state.profilePhotoBytes == null
                            ? l10n.choosePhoto
                            : l10n.replacePhoto,
                      ),
                    ),
                    if (state.profilePhotoBytes != null)
                      TextButton(
                        onPressed: controller.removeProfilePhoto,
                        child: Text(l10n.removePhoto),
                      ),
                  ],
                ),
              ),
            ],
          ];

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                l10n.createAccount,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                l10n.stepOf(state.step.index + 1, 4),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 16),
              LinearProgressIndicator(value: (state.step.index + 1) / 4),
              const SizedBox(height: 20),
              if (state.errorMessage != null) ...[
                _SignupMessage(text: state.errorMessage!, isError: true),
                const SizedBox(height: 12),
              ],
              if (state.statusMessage != null) ...[
                _SignupMessage(text: state.statusMessage!),
                const SizedBox(height: 12),
              ],
              ...stepChildren,
              const SizedBox(height: 20),
              Row(
                children: [
                  if (state.step != SignupStep.account)
                    Expanded(
                      child: OutlinedButton(
                        onPressed: state.busy ? null : controller.previousStep,
                        child: Text(l10n.back),
                      ),
                    ),
                  if (state.step != SignupStep.account)
                    const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: state.busy
                          ? null
                          : state.step == SignupStep.photo
                          ? _submit
                          : state.canContinue
                          ? controller.nextStep
                          : null,
                      child: Text(
                        state.busy
                            ? l10n.working
                            : state.step == SignupStep.photo
                            ? l10n.createAccountButton
                            : l10n.continueAction,
                      ),
                    ),
                  ),
                ],
              ),
              if (state.step == SignupStep.account) ...[
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () => context.go('/login'),
                  child: Text(l10n.alreadyHaveAccountLogin),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  Future<void> _pickDob(SignupController controller) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(now.year - 18),
      firstDate: DateTime(1900),
      lastDate: DateTime(now.year - 13, now.month, now.day),
    );
    if (picked != null) {
      controller.updateDob(picked.toIso8601String().split('T').first);
    }
  }

  void _syncController(TextEditingController controller, String value) {
    if (controller.text == value) return;
    controller.value = controller.value.copyWith(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
      composing: TextRange.empty,
    );
  }
}

class _SendCodeButton extends ConsumerWidget {
  const _SendCodeButton({required this.state});

  final SignupState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final controller = ref.read(signupControllerProvider.notifier);
    return OutlinedButton(
      onPressed: state.busy || !state.canResendCode
          ? null
          : controller.sendCode,
      child: Text(
        state.busy
            ? l10n.sending
            : state.resendCooldownSeconds > 0
            ? l10n.resendIn(_formatCooldown(state.resendCooldownSeconds))
            : state.statusMessage != null ||
                  state.verified ||
                  state.emailVerificationToken.isNotEmpty
            ? l10n.resendVerificationCode
            : l10n.sendVerificationCode,
      ),
    );
  }

  String _formatCooldown(int seconds) {
    final minutes = (seconds ~/ 60).toString().padLeft(1, '0');
    final remainingSeconds = (seconds % 60).toString().padLeft(2, '0');
    return '$minutes:$remainingSeconds';
  }
}

class _SignupMessage extends StatelessWidget {
  const _SignupMessage({required this.text, this.isError = false});

  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color:
            (isError ? scheme.errorContainer : scheme.surfaceContainerHighest)
                .withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: isError ? scheme.onErrorContainer : scheme.onSurfaceVariant,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
