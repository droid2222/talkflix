import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/auth/session_controller.dart';
import '../../../core/widgets/feature_scaffold.dart';
import '../data/signup_options.dart';
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
    if (mounted) context.go('/app/talk');
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(signupControllerProvider);
    final controller = ref.read(signupControllerProvider.notifier);
    _syncController(_emailController, state.email);
    _syncController(_passwordController, state.password);
    _syncController(_codeController, state.code);
    _syncController(_displayNameController, state.displayName);
    _syncController(_dobController, state.dob);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: state.busy
              ? null
              : state.step == SignupStep.account
              ? () => context.go('/login')
              : controller.previousStep,
          icon: const Icon(Icons.arrow_back_ios_new_rounded),
          tooltip: state.step == SignupStep.account ? 'Back to login' : 'Back',
        ),
        title: const Text('Create account'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            'Step ${state.step.index + 1} of 4',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          LinearProgressIndicator(value: (state.step.index + 1) / 4),
          const SizedBox(height: 20),
          if (state.errorMessage != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                state.errorMessage!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (state.statusMessage != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(state.statusMessage!),
            ),
          if (state.step == SignupStep.account) ...[
            const SectionCard(
              title: 'Account verification',
              subtitle:
                  'Use a real email so you can verify your account and recover your password later.',
              child: SizedBox.shrink(),
            ),
            TextField(
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: 'Email'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passwordController,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Password (min 6)'),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: state.busy || !state.canResendCode
                  ? null
                  : controller.sendCode,
              child: Text(
                state.busy
                    ? 'Sending...'
                    : state.resendCooldownSeconds > 0
                    ? 'Resend in ${_formatCooldown(state.resendCooldownSeconds)}'
                    : state.statusMessage != null ||
                          state.verified ||
                          state.emailVerificationToken.isNotEmpty
                    ? 'Resend verification code'
                    : 'Send verification code',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _codeController,
              decoration: const InputDecoration(labelText: 'Verification code'),
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: state.busy ? null : controller.verifyCode,
              child: Text(state.verified ? 'Verified' : 'Verify code'),
            ),
          ],
          if (state.step == SignupStep.profile) ...[
            TextField(
              controller: _displayNameController,
              decoration: const InputDecoration(labelText: 'Display name'),
            ),
            const SizedBox(height: 12),
            TextField(
              decoration: const InputDecoration(labelText: 'Date of birth'),
              readOnly: true,
              controller: _dobController,
              onTap: () async {
                final now = DateTime.now();
                final picked = await showDatePicker(
                  context: context,
                  initialDate: DateTime(now.year - 18),
                  firstDate: DateTime(1900),
                  lastDate: DateTime(now.year - 13, now.month, now.day),
                );
                if (picked != null) {
                  controller.updateDob(
                    picked.toIso8601String().split('T').first,
                  );
                }
              },
            ),
            const SizedBox(height: 12),
            SegmentedButton<String>(
              emptySelectionAllowed: true,
              segments: const [
                ButtonSegment(value: 'male', label: Text('Male')),
                ButtonSegment(value: 'female', label: Text('Female')),
              ],
              selected: state.gender.isEmpty ? const {} : {state.gender},
              onSelectionChanged: (selection) {
                if (selection.isNotEmpty) {
                  controller.updateGender(selection.first);
                }
              },
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
              decoration: const InputDecoration(
                labelText: 'Where you are from',
              ),
            ),
            const SizedBox(height: 12),
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
              onChanged: (value) => controller.updateFirstLanguage(value ?? ''),
              decoration: const InputDecoration(labelText: 'First language'),
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
              onChanged: (value) => controller.updateLearnLanguage(value ?? ''),
              decoration: const InputDecoration(labelText: 'Language to learn'),
            ),
          ],
          if (state.step == SignupStep.photo) ...[
            SectionCard(
              title: 'Profile photo',
              subtitle:
                  'Optional for now. You can upload one later from your profile.',
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
                          ? 'Choose photo'
                          : 'Replace photo',
                    ),
                  ),
                  if (state.profilePhotoBytes != null)
                    TextButton(
                      onPressed: controller.removeProfilePhoto,
                      child: const Text('Remove photo'),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 20),
          Row(
            children: [
              if (state.step != SignupStep.account)
                Expanded(
                  child: OutlinedButton(
                    onPressed: state.busy ? null : controller.previousStep,
                    child: const Text('Back'),
                  ),
                ),
              if (state.step != SignupStep.account) const SizedBox(width: 12),
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
                        ? 'Working...'
                        : state.step == SignupStep.photo
                        ? 'Create account'
                        : 'Continue',
                  ),
                ),
              ),
            ],
          ),
          if (state.step == SignupStep.account)
            TextButton(
              onPressed: () => context.go('/login'),
              child: const Text('Already have an account? Login'),
            ),
        ],
      ),
    );
  }

  void _syncController(TextEditingController controller, String value) {
    if (controller.text == value) return;
    controller.value = controller.value.copyWith(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
      composing: TextRange.empty,
    );
  }

  String _formatCooldown(int seconds) {
    final minutes = (seconds ~/ 60).toString().padLeft(1, '0');
    final remainingSeconds = (seconds % 60).toString().padLeft(2, '0');
    return '$minutes:$remainingSeconds';
  }
}
