import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/localization/app_language_controller.dart';
import '../../../app/localization/talkflix_localizations.dart';
import '../data/auth_repository.dart';

enum SignupStep { account, profile, languages, photo }

class SignupState {
  const SignupState({
    this.step = SignupStep.account,
    this.email = '',
    this.password = '',
    this.code = '',
    this.emailVerificationToken = '',
    this.verified = false,
    this.displayName = '',
    this.dob = '',
    this.gender = '',
    this.fromCountry = '',
    this.firstLanguage = '',
    this.learnLanguage = '',
    this.profilePhotoBytes,
    this.profilePhotoMimeType,
    this.profilePhotoName,
    this.busy = false,
    this.resendCooldownSeconds = 0,
    this.statusMessage,
    this.errorMessage,
  });

  final SignupStep step;
  final String email;
  final String password;
  final String code;
  final String emailVerificationToken;
  final bool verified;
  final String displayName;
  final String dob;
  final String gender;
  final String fromCountry;
  final String firstLanguage;
  final String learnLanguage;
  final Uint8List? profilePhotoBytes;
  final String? profilePhotoMimeType;
  final String? profilePhotoName;
  final bool busy;
  final int resendCooldownSeconds;
  final String? statusMessage;
  final String? errorMessage;

  bool get canResendCode => resendCooldownSeconds == 0;

  bool get canContinue {
    switch (step) {
      case SignupStep.account:
        return email.trim().isNotEmpty &&
            password.trim().length >= 6 &&
            verified &&
            emailVerificationToken.isNotEmpty;
      case SignupStep.profile:
        return displayName.trim().isNotEmpty &&
            dob.isNotEmpty &&
            (gender == 'male' || gender == 'female');
      case SignupStep.languages:
        return fromCountry.isNotEmpty &&
            firstLanguage.isNotEmpty &&
            learnLanguage.isNotEmpty;
      case SignupStep.photo:
        return true;
    }
  }

  SignupState copyWith({
    SignupStep? step,
    String? email,
    String? password,
    String? code,
    String? emailVerificationToken,
    bool? verified,
    String? displayName,
    String? dob,
    String? gender,
    String? fromCountry,
    String? firstLanguage,
    String? learnLanguage,
    Uint8List? profilePhotoBytes,
    String? profilePhotoMimeType,
    String? profilePhotoName,
    bool? busy,
    int? resendCooldownSeconds,
    String? statusMessage,
    String? errorMessage,
    bool clearError = false,
    bool clearStatus = false,
    bool clearPhoto = false,
  }) {
    return SignupState(
      step: step ?? this.step,
      email: email ?? this.email,
      password: password ?? this.password,
      code: code ?? this.code,
      emailVerificationToken:
          emailVerificationToken ?? this.emailVerificationToken,
      verified: verified ?? this.verified,
      displayName: displayName ?? this.displayName,
      dob: dob ?? this.dob,
      gender: gender ?? this.gender,
      fromCountry: fromCountry ?? this.fromCountry,
      firstLanguage: firstLanguage ?? this.firstLanguage,
      learnLanguage: learnLanguage ?? this.learnLanguage,
      profilePhotoBytes: clearPhoto
          ? null
          : profilePhotoBytes ?? this.profilePhotoBytes,
      profilePhotoMimeType: clearPhoto
          ? null
          : profilePhotoMimeType ?? this.profilePhotoMimeType,
      profilePhotoName: clearPhoto
          ? null
          : profilePhotoName ?? this.profilePhotoName,
      busy: busy ?? this.busy,
      resendCooldownSeconds:
          resendCooldownSeconds ?? this.resendCooldownSeconds,
      statusMessage: clearStatus ? null : statusMessage ?? this.statusMessage,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
    );
  }
}

final signupControllerProvider =
    StateNotifierProvider.autoDispose<SignupController, SignupState>((ref) {
      return SignupController(ref);
    });

class SignupController extends StateNotifier<SignupState> {
  SignupController(this._ref) : super(const SignupState());

  final Ref _ref;
  Timer? _resendTimer;

  TalkflixLocalizations get _l10n =>
      TalkflixLocalizations(_ref.read(effectiveAppLocaleProvider));

  void updateEmail(String value) {
    state = state.copyWith(
      email: value,
      verified: false,
      emailVerificationToken: '',
      resendCooldownSeconds: 0,
      clearError: true,
    );
    _resendTimer?.cancel();
  }

  void updatePassword(String value) =>
      state = state.copyWith(password: value, clearError: true);
  void updateCode(String value) =>
      state = state.copyWith(code: value, clearError: true);
  void updateDisplayName(String value) =>
      state = state.copyWith(displayName: value, clearError: true);
  void updateDob(String value) =>
      state = state.copyWith(dob: value, clearError: true);
  void updateGender(String value) =>
      state = state.copyWith(gender: value, clearError: true);
  void updateFromCountry(String value) =>
      state = state.copyWith(fromCountry: value, clearError: true);
  void updateFirstLanguage(String value) =>
      state = state.copyWith(firstLanguage: value, clearError: true);
  void updateLearnLanguage(String value) =>
      state = state.copyWith(learnLanguage: value, clearError: true);

  void setProfilePhoto({
    required Uint8List bytes,
    required String mimeType,
    required String name,
  }) {
    state = state.copyWith(
      profilePhotoBytes: bytes,
      profilePhotoMimeType: mimeType,
      profilePhotoName: name,
      clearError: true,
    );
  }

  void removeProfilePhoto() => state = state.copyWith(clearPhoto: true);

  void nextStep() {
    if (!state.canContinue) return;
    if (state.step == SignupStep.account) {
      state = state.copyWith(step: SignupStep.profile, clearError: true);
    } else if (state.step == SignupStep.profile) {
      state = state.copyWith(step: SignupStep.languages, clearError: true);
    } else if (state.step == SignupStep.languages) {
      state = state.copyWith(step: SignupStep.photo, clearError: true);
    }
  }

  void previousStep() {
    if (state.step == SignupStep.profile) {
      state = state.copyWith(step: SignupStep.account, clearError: true);
    } else if (state.step == SignupStep.languages) {
      state = state.copyWith(step: SignupStep.profile, clearError: true);
    } else if (state.step == SignupStep.photo) {
      state = state.copyWith(step: SignupStep.languages, clearError: true);
    }
  }

  Future<void> sendCode() async {
    final l10n = _l10n;
    if (!state.canResendCode) return;
    final email = state.email.trim();
    if (email.isEmpty) {
      state = state.copyWith(
        errorMessage: l10n.enterEmailFirst,
        clearStatus: true,
      );
      return;
    }
    if (!email.contains('@') || !email.contains('.')) {
      state = state.copyWith(
        errorMessage: l10n.enterValidEmail,
        clearStatus: true,
      );
      return;
    }
    if (state.password.trim().length < 6) {
      state = state.copyWith(
        errorMessage: l10n.passwordBeforeVerification,
        clearStatus: true,
      );
      return;
    }

    state = state.copyWith(busy: true, clearError: true, clearStatus: true);
    try {
      await _ref.read(authRepositoryProvider).sendVerificationCode(email);
      _startResendCooldown();
      state = state.copyWith(
        busy: false,
        statusMessage: l10n.verificationCodeSent,
      );
    } catch (error) {
      state = state.copyWith(busy: false, errorMessage: error.toString());
    }
  }

  Future<void> verifyCode() async {
    final l10n = _l10n;
    if (state.email.trim().isEmpty) {
      state = state.copyWith(
        errorMessage: l10n.enterEmailFirst,
        clearStatus: true,
      );
      return;
    }
    if (state.code.trim().isEmpty) {
      state = state.copyWith(
        errorMessage: l10n.enterVerificationCode,
        clearStatus: true,
      );
      return;
    }

    state = state.copyWith(busy: true, clearError: true, clearStatus: true);
    try {
      final token = await _ref
          .read(authRepositoryProvider)
          .verifyCode(email: state.email, code: state.code);
      state = state.copyWith(
        busy: false,
        verified: true,
        emailVerificationToken: token,
        statusMessage: l10n.emailVerified,
      );
    } catch (error) {
      state = state.copyWith(busy: false, errorMessage: error.toString());
    }
  }

  Future<AuthResult?> submit() async {
    final l10n = _l10n;
    state = state.copyWith(
      busy: true,
      clearError: true,
      statusMessage: l10n.creatingAccount,
    );
    try {
      final result = await _ref
          .read(authRepositoryProvider)
          .signup(
            email: state.email,
            password: state.password,
            displayName: state.displayName,
            dob: state.dob,
            gender: state.gender,
            fromCountry: state.fromCountry,
            firstLanguage: state.firstLanguage,
            learnLanguage: state.learnLanguage,
            emailVerificationToken: state.emailVerificationToken,
            profilePhotoBytes: state.profilePhotoBytes,
            profilePhotoMimeType: state.profilePhotoMimeType,
            profilePhotoName: state.profilePhotoName,
          );
      state = state.copyWith(busy: false, statusMessage: l10n.accountCreated);
      return result;
    } catch (error) {
      state = state.copyWith(busy: false, errorMessage: error.toString());
      return null;
    }
  }

  void _startResendCooldown() {
    _resendTimer?.cancel();
    state = state.copyWith(resendCooldownSeconds: 120);
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      final next = state.resendCooldownSeconds - 1;
      if (next <= 0) {
        timer.cancel();
        state = state.copyWith(resendCooldownSeconds: 0);
        return;
      }
      state = state.copyWith(resendCooldownSeconds: next);
    });
  }

  @override
  void dispose() {
    _resendTimer?.cancel();
    super.dispose();
  }
}
