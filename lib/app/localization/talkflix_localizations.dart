import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/config/app_config.dart';
import 'app_language_controller.dart';
import 'talkflix_translation_maps.dart';

class TalkflixLocalizations {
  const TalkflixLocalizations(this.locale);

  final Locale locale;

  static const delegate = _TalkflixLocalizationsDelegate();

  static TalkflixLocalizations of(BuildContext context) {
    final value = Localizations.of<TalkflixLocalizations>(
      context,
      TalkflixLocalizations,
    );
    assert(value != null, 'TalkflixLocalizations not found in context.');
    return value!;
  }

  String get _languageCode => locale.languageCode.toLowerCase();

  bool get isArabic => _languageCode == 'ar';

  String _t(String key, String english, {String? arabic}) {
    final translated = talkflixTranslations[_languageCode]?[key];
    if (translated != null && translated.isNotEmpty) {
      return translated;
    }
    if (isArabic && arabic != null) {
      return arabic;
    }
    return english;
  }

  String _tf(
    String key,
    String english,
    Map<String, String> values, {
    String? arabic,
  }) {
    var result = _t(key, english, arabic: arabic);
    for (final entry in values.entries) {
      result = result.replaceAll('{${entry.key}}', entry.value);
    }
    return result;
  }

  String get appTitle => 'Talkflix';
  String get talkTab => _t('talkTab', 'Chats', arabic: 'المحادثات');
  String get talksTitle => _t('talksTitle', 'Chats', arabic: 'المحادثات');
  String get liveTab => _t('liveTab', 'Live', arabic: 'بث');
  String get meetTab => _t('meetTab', 'Meet', arabic: 'تعارف');
  String get contentTab => 'Talkiz';
  String get profileTab => _t('profileTab', 'Profile', arabic: 'الملف');

  String get incomingVideoCall => _t(
    'incomingVideoCall',
    'Incoming video call',
    arabic: 'مكالمة فيديو واردة',
  );
  String get incomingCall =>
      _t('incomingCall', 'Incoming call', arabic: 'مكالمة واردة');
  String get someone => _t('someone', 'Someone', arabic: 'شخص ما');
  String get decline => _t('decline', 'Decline', arabic: 'رفض');
  String get accept => _t('accept', 'Accept', arabic: 'قبول');

  String get settings => _t('settings', 'Settings', arabic: 'الإعدادات');
  String get account => _t('account', 'Account', arabic: 'الحساب');
  String get notifications =>
      _t('notifications', 'Notifications', arabic: 'الإشعارات');
  String get privacy => _t('privacy', 'Privacy', arabic: 'الخصوصية');
  String get blacklist =>
      _t('blacklist', 'Blacklist', arabic: 'القائمة السوداء');
  String get blockedUsers =>
      _t('blockedUsers', 'Blocked users', arabic: 'المستخدمون المحظورون');
  String get noBlockedUsers => _t(
    'noBlockedUsers',
    'No blocked users.',
    arabic: 'لا يوجد مستخدمون محظورون.',
  );
  String get unblock => _t('unblock', 'Unblock', arabic: 'إلغاء الحظر');
  String get blockedUsersLoadFailed => _t(
    'blockedUsersLoadFailed',
    'Could not load blocked users.',
    arabic: 'تعذر تحميل المستخدمين المحظورين.',
  );
  String get userUnblocked =>
      _t('userUnblocked', 'User unblocked.', arabic: 'تم إلغاء حظر المستخدم.');
  String get showAge => _t('showAge', 'Show Age', arabic: 'إظهار العمر');
  String get showAgeSubtitle => _t(
    'showAgeSubtitle',
    'Show your age in Meet cards when that data is available.',
    arabic: 'اعرض عمرك في بطاقات التعارف عندما تكون البيانات متاحة.',
  );
  String get showFlag => _t('showFlag', 'Show Flag', arabic: 'إظهار العلم');
  String get showFlagSubtitle => _t(
    'showFlagSubtitle',
    'Show your flag next to your name in the Meet screen.',
    arabic: 'اعرض علمك بجانب اسمك في شاشة التعارف.',
  );
  String get meetPrimaryGoalPrompt => _t(
    'meetPrimaryGoalPrompt',
    "What's your primary goal on Talkflix?",
    arabic: 'ما هدفك الأساسي على Talkflix؟',
  );
  String get showCountry =>
      _t('showCountry', 'Show Location', arabic: 'إظهار الموقع');
  String get showCountrySubtitle => _t(
    'showCountrySubtitle',
    'Show your location on your public profile.',
    arabic: 'اعرض موقعك في ملفك الشخصي العام.',
  );
  String get showFollowingFollowers => _t(
    'showFollowingFollowers',
    'Show following/followers',
    arabic: 'إظهار المتابَعين والمتابِعين',
  );
  String get showFollowingFollowersSubtitle => _t(
    'showFollowingFollowersSubtitle',
    'Show follower and following counts on your profile.',
    arabic: 'اعرض عدد المتابعين والمتابَعين في ملفك الشخصي.',
  );
  String get showOnlineStatus => _t(
    'showOnlineStatus',
    'Show online status',
    arabic: 'إظهار حالة الاتصال',
  );
  String get showOnlineStatusSubtitle => _t(
    'showOnlineStatusSubtitle',
    'Show online and offline labels in direct chats.',
    arabic: 'اعرض مؤشرات متصل وغير متصل في الدردشة المباشرة.',
  );
  String get receiveVoiceCalls => _t(
    'receiveVoiceCalls',
    'Receive voice calls',
    arabic: 'استقبال المكالمات الصوتية',
  );
  String get receiveVoiceCallsSubtitle => _t(
    'receiveVoiceCallsSubtitle',
    'Allow people to reach you with direct voice calls.',
    arabic: 'اسمح للمستخدمين بالاتصال بك عبر المكالمات الصوتية المباشرة.',
  );
  String get receiveVideoCalls => _t(
    'receiveVideoCalls',
    'Receive video calls',
    arabic: 'استقبال مكالمات الفيديو',
  );
  String get receiveVideoCallsSubtitle => _t(
    'receiveVideoCallsSubtitle',
    'Allow people to reach you with direct video calls.',
    arabic: 'اسمح للمستخدمين بالاتصال بك عبر مكالمات الفيديو المباشرة.',
  );
  String get relationshipStatus => _t(
    'relationshipStatus',
    'Relationship Status',
    arabic: 'الحالة الاجتماعية',
  );
  String get relationshipStatusHidden => _t(
    'relationshipStatusHidden',
    'Hidden on your profile',
    arabic: 'مخفية في ملفك الشخصي',
  );
  String get selectRelationshipStatus => _t(
    'selectRelationshipStatus',
    'Select relationship status',
    arabic: 'اختر الحالة الاجتماعية',
  );
  String get relationshipStatusRequired => _t(
    'relationshipStatusRequired',
    'Select a relationship status first.',
    arabic: 'اختر الحالة الاجتماعية أولاً.',
  );
  String get relationshipStatusUpdated => _t(
    'relationshipStatusUpdated',
    'Relationship status updated.',
    arabic: 'تم تحديث الحالة الاجتماعية.',
  );
  String get relationshipStatusHiddenNotice => _t(
    'relationshipStatusHiddenNotice',
    'Relationship status hidden from your profile.',
    arabic: 'تم إخفاء الحالة الاجتماعية من ملفك الشخصي.',
  );
  String get married => _t('married', 'Married', arabic: 'متزوج');
  String get single => _t('single', 'Single', arabic: 'أعزب');
  String get divorced => _t('divorced', 'Divorced', arabic: 'مطلق');
  String get searching => _t('searching', 'Searching', arabic: 'أبحث');
  String get widowed => _t('widowed', 'Widowed', arabic: 'أرمل');
  String get chatSettings =>
      _t('chatSettings', 'Chat Settings', arabic: 'إعدادات الدردشة');
  String get language => _t('language', 'Language', arabic: 'اللغة');
  String get darkTheme =>
      _t('darkTheme', 'Dark Theme', arabic: 'المظهر الداكن');
  String get rateTalkflix =>
      _t('rateTalkflix', 'Rate Talkflix', arabic: 'قيّم Talkflix');
  String get about => _t('about', 'About', arabic: 'حول');
  String get help => _t('help', 'Help', arabic: 'المساعدة');
  String get manageStorage =>
      _t('manageStorage', 'Manage Storage', arabic: 'إدارة التخزين');
  String get appLanguage =>
      _t('appLanguage', 'App Language', arabic: 'لغة التطبيق');
  String get translateReceivedMessagesTo => _t(
    'translateReceivedMessagesTo',
    'Translate Received Messages To',
    arabic: 'ترجمة الرسائل المستلمة إلى',
  );
  String get systemDefault =>
      _t('systemDefault', 'System Default', arabic: 'افتراضي النظام');
  String get autoPlayReceivedVoiceNotes => _t(
    'autoPlayReceivedVoiceNotes',
    'Auto-play received voice notes',
    arabic: 'تشغيل الرسائل الصوتية المستلمة تلقائيًا',
  );
  String get handsFreeListening => _t(
    'handsFreeListening',
    'Hands-free listening while you are in a chat.',
    arabic: 'استماع بدون استخدام اليدين أثناء وجودك في الدردشة.',
  );
  String get languageFollowsDeviceHint => _t(
    'languageFollowsDeviceHint',
    'Talkflix starts in English. Choose System Default here if you want the app to follow your device language.',
    arabic:
        'يبدأ Talkflix باللغة الإنجليزية. اختر افتراضي النظام هنا إذا أردت أن يتبع التطبيق لغة جهازك.',
  );
  String defaultTranslationTarget(String language) => _tf(
    'defaultTranslationTarget',
    'Default translation target is your first language: {language}.',
    <String, String>{'language': language},
    arabic: 'لغة الترجمة الافتراضية هي لغتك الأولى: {language}.',
  );
  String get aboutBody => _t(
    'aboutBody',
    'Talkflix helps language learners practice through direct chat, voice rooms, and live broadcasts.',
    arabic:
        'يساعد Talkflix متعلمي اللغات على الممارسة عبر الدردشة المباشرة والغرف الصوتية والبث المباشر.',
  );
  String get helpBody => isArabic
      ? 'للمساعدة في استرداد الحساب أو الإشعارات أو المكالمات المباشرة، تواصل مع فريق Talkflix على ${AppConfig.supportEmail}.'
      : 'Need help with account recovery, notifications, or direct calls? Contact the Talkflix team at ${AppConfig.supportEmail}.';
  String get talkflixId =>
      _t('talkflixId', 'Talkflix ID', arabic: 'معرّف Talkflix');
  String get email => _t('email', 'Email', arabic: 'البريد الإلكتروني');
  String get password => _t('password', 'Password', arabic: 'كلمة المرور');
  String get bindMoreLoginMethods => _t(
    'bindMoreLoginMethods',
    'Bind more login methods to ensure account security.',
    arabic: 'اربط المزيد من طرق تسجيل الدخول لضمان أمان الحساب.',
  );
  String get phoneNumber =>
      _t('phoneNumber', 'Phone number', arabic: 'رقم الهاتف');
  String get facebook => 'Facebook';
  String get google => 'Google';
  String get appleId => 'Apple ID';
  String get notSet => _t('notSet', 'Not set', arabic: 'غير محدد');
  String get notBound => _t('notBound', 'Not bound', arabic: 'غير مرتبط');
  String get bound => _t('bound', 'Bound', arabic: 'مرتبط');
  String get logOut => _t('logOut', 'Log Out', arabic: 'تسجيل الخروج');
  String get deleteAccount =>
      _t('deleteAccount', 'Delete Account', arabic: 'حذف الحساب');
  String get systemTheme => _t('systemTheme', 'System', arabic: 'النظام');
  String get lightTheme => _t('lightTheme', 'Light', arabic: 'فاتح');
  String get darkThemeOption => _t('darkThemeOption', 'Dark', arabic: 'داكن');
  String get appLanguageSetSystemDefault => _t(
    'appLanguageSetSystemDefault',
    'App language set to system default.',
    arabic: 'تم تعيين لغة التطبيق إلى افتراضي النظام.',
  );
  String appLanguageSetTo(String language) => _tf(
    'appLanguageSetTo',
    'App language set to {language}.',
    <String, String>{'language': language},
    arabic: 'تم تعيين لغة التطبيق إلى {language}.',
  );
  String receivedMessagesTranslateTo(String language) => _tf(
    'receivedMessagesTranslateTo',
    'Received messages will translate to {language}.',
    <String, String>{'language': language},
    arabic: 'ستُترجم الرسائل المستلمة إلى {language}.',
  );

  String get translate => _t('translate', 'Translate', arabic: 'ترجمة');
  String get translating =>
      _t('translating', 'Translating...', arabic: 'جارٍ الترجمة...');
  String translatedTo(String language) => _tf(
    'translatedTo',
    'Translated to {language}',
    <String, String>{'language': language},
    arabic: 'تمت الترجمة إلى {language}',
  );
  String get translationSaved =>
      _t('translationSaved', 'Translation saved', arabic: 'الترجمة محفوظة');
  String get showTranslation =>
      _t('showTranslation', 'Show translation', arabic: 'إظهار الترجمة');
  String get noTranslationReturned => _t(
    'noTranslationReturned',
    'No translation returned.',
    arabic: 'لم يتم إرجاع ترجمة.',
  );
  String get couldNotTranslate => _t(
    'couldNotTranslate',
    'Could not translate. Try again.',
    arabic: 'تعذرت الترجمة. حاول مرة أخرى.',
  );

  String get authBrandCopy => _t(
    'authBrandCopy',
    'Connect with people worldwide, practice languages naturally, and continue your conversations across chat, voice, and video.',
    arabic:
        'تواصل مع أشخاص حول العالم، وتدرّب على اللغات بشكل طبيعي، وواصل محادثاتك عبر الدردشة والصوت والفيديو.',
  );
  String get welcomeBack =>
      _t('welcomeBack', 'Welcome back', arabic: 'مرحبًا بعودتك');
  String get signInSubtitle => _t(
    'signInSubtitle',
    'Sign in to continue your chats and matches.',
    arabic: 'سجّل الدخول لمتابعة محادثاتك وتوافقاتك.',
  );
  String get rememberEmail =>
      _t('rememberEmail', 'Remember email', arabic: 'تذكر البريد الإلكتروني');
  String get forgotPassword =>
      _t('forgotPassword', 'Forgot password?', arabic: 'هل نسيت كلمة المرور؟');
  String get signingIn =>
      _t('signingIn', 'Signing in...', arabic: 'جارٍ تسجيل الدخول...');
  String get signIn => _t('signIn', 'Sign In', arabic: 'تسجيل الدخول');
  String get newHere => _t('newHere', 'New here?', arabic: 'جديد هنا؟');
  String get createAccount =>
      _t('createAccount', 'Create account', arabic: 'إنشاء حساب');
  String get pleaseEnterEmail => _t(
    'pleaseEnterEmail',
    'Please enter your email.',
    arabic: 'يرجى إدخال بريدك الإلكتروني.',
  );
  String get pleaseEnterPassword => _t(
    'pleaseEnterPassword',
    'Please enter your password.',
    arabic: 'يرجى إدخال كلمة المرور.',
  );
  String get signInFailed => _t(
    'signInFailed',
    'We could not sign you in right now. Please try again.',
    arabic: 'تعذر تسجيل الدخول الآن. يرجى المحاولة مرة أخرى.',
  );
  String get forgotPasswordTitle =>
      _t('forgotPasswordTitle', 'Forgot password', arabic: 'نسيت كلمة المرور');
  String get forgotPasswordSubtitle => _t(
    'forgotPasswordSubtitle',
    'Enter your email and we’ll send you a reset link.',
    arabic: 'أدخل بريدك الإلكتروني وسنرسل لك رابط إعادة تعيين.',
  );
  String get sending => _t('sending', 'Sending...', arabic: 'جارٍ الإرسال...');
  String get sendResetLink => _t(
    'sendResetLink',
    'Send reset link',
    arabic: 'إرسال رابط إعادة التعيين',
  );
  String get resetLinkSent => _t(
    'resetLinkSent',
    'If that email exists, a reset link has been sent.',
    arabic: 'إذا كان هذا البريد موجودًا، فقد تم إرسال رابط إعادة التعيين.',
  );
  String get sendResetLinkFailed => _t(
    'sendResetLinkFailed',
    'We could not send the reset link right now. Please try again.',
    arabic: 'تعذر إرسال رابط إعادة التعيين الآن. يرجى المحاولة مرة أخرى.',
  );
  String get backToLogin =>
      _t('backToLogin', 'Back to login', arabic: 'العودة إلى تسجيل الدخول');
  String get resetPasswordTitle => _t(
    'resetPasswordTitle',
    'Reset password',
    arabic: 'إعادة تعيين كلمة المرور',
  );
  String get missingToken =>
      _t('missingToken', 'Missing token.', arabic: 'الرمز مفقود.');
  String get passwordMinSix => _t(
    'passwordMinSix',
    'Password must be at least 6 characters.',
    arabic: 'يجب أن تتكون كلمة المرور من 6 أحرف على الأقل.',
  );
  String get passwordResetSuccess => _t(
    'passwordResetSuccess',
    'Password reset. You can login now.',
    arabic: 'تمت إعادة تعيين كلمة المرور. يمكنك تسجيل الدخول الآن.',
  );
  String get resetPasswordFailed => _t(
    'resetPasswordFailed',
    'We could not reset your password right now. Please try again.',
    arabic: 'تعذر إعادة تعيين كلمة المرور الآن. يرجى المحاولة مرة أخرى.',
  );
  String get resettingPassword => _t(
    'resettingPassword',
    'Resetting password...',
    arabic: 'جارٍ إعادة تعيين كلمة المرور...',
  );
  String get setNewPassword =>
      _t('setNewPassword', 'Set new password', arabic: 'تعيين كلمة مرور جديدة');
  String get newPasswordMinSix => _t(
    'newPasswordMinSix',
    'New password (min 6)',
    arabic: 'كلمة مرور جديدة (6 أحرف على الأقل)',
  );
  String get authBackTooltip => _t('authBackTooltip', 'Back', arabic: 'رجوع');
  String get accountVerification => _t(
    'accountVerification',
    'Account verification',
    arabic: 'التحقق من الحساب',
  );
  String get accountVerificationSubtitle => _t(
    'accountVerificationSubtitle',
    'Use a real email so you can verify your account and recover your password later.',
    arabic:
        'استخدم بريدًا إلكترونيًا حقيقيًا حتى تتمكن من التحقق من حسابك واستعادة كلمة المرور لاحقًا.',
  );
  String get passwordMinSixLabel => _t(
    'passwordMinSixLabel',
    'Password (min 6)',
    arabic: 'كلمة المرور (6 أحرف على الأقل)',
  );
  String resendIn(String value) => _tf(
    'resendIn',
    'Resend in {value}',
    <String, String>{'value': value},
    arabic: 'إعادة الإرسال خلال {value}',
  );
  String get resendVerificationCode => _t(
    'resendVerificationCode',
    'Resend verification code',
    arabic: 'إعادة إرسال رمز التحقق',
  );
  String get sendVerificationCode => _t(
    'sendVerificationCode',
    'Send verification code',
    arabic: 'إرسال رمز التحقق',
  );
  String get verificationCode =>
      _t('verificationCode', 'Verification code', arabic: 'رمز التحقق');
  String get verified => _t('verified', 'Verified', arabic: 'تم التحقق');
  String get verifyCode =>
      _t('verifyCode', 'Verify code', arabic: 'تحقق من الرمز');
  String get displayName =>
      _t('displayName', 'Display name', arabic: 'الاسم المعروض');
  String get dateOfBirth =>
      _t('dateOfBirth', 'Date of birth', arabic: 'تاريخ الميلاد');
  String get male => _t('male', 'Male', arabic: 'ذكر');
  String get female => _t('female', 'Female', arabic: 'أنثى');
  String get whereYouAreFrom =>
      _t('whereYouAreFrom', 'Where you are from', arabic: 'من أين أنت');
  String get firstLanguage =>
      _t('firstLanguage', 'First language', arabic: 'اللغة الأولى');
  String get languageToLearn => _t(
    'languageToLearn',
    'Language to learn',
    arabic: 'اللغة التي تريد تعلمها',
  );
  String get profilePhoto =>
      _t('profilePhoto', 'Profile photo', arabic: 'صورة الملف الشخصي');
  String get profilePhotoSubtitle => _t(
    'profilePhotoSubtitle',
    'Optional for now. You can upload one later from your profile.',
    arabic: 'اختيارية الآن. يمكنك رفعها لاحقًا من ملفك الشخصي.',
  );
  String get choosePhoto =>
      _t('choosePhoto', 'Choose photo', arabic: 'اختيار صورة');
  String get replacePhoto =>
      _t('replacePhoto', 'Replace photo', arabic: 'استبدال الصورة');
  String get removePhoto =>
      _t('removePhoto', 'Remove photo', arabic: 'إزالة الصورة');
  String get back => _t('back', 'Back', arabic: 'رجوع');
  String get working => _t('working', 'Working...', arabic: 'جارٍ العمل...');
  String get continueAction =>
      _t('continueAction', 'Continue', arabic: 'متابعة');
  String get alreadyHaveAccountLogin => _t(
    'alreadyHaveAccountLogin',
    'Already have an account? Login',
    arabic: 'لديك حساب بالفعل؟ سجّل الدخول',
  );
  String stepOf(int current, int total) => _tf(
    'stepOf',
    'Step {current} of {total}',
    <String, String>{'current': '$current', 'total': '$total'},
    arabic: 'الخطوة {current} من {total}',
  );
  String get createAccountButton =>
      _t('createAccountButton', 'Create account', arabic: 'إنشاء حساب');
  String get accountCreated =>
      _t('accountCreated', 'Account created.', arabic: 'تم إنشاء الحساب.');
  String get creatingAccount => _t(
    'creatingAccount',
    'Creating account...',
    arabic: 'جارٍ إنشاء الحساب...',
  );
  String get emailVerified => _t(
    'emailVerified',
    'Email verified.',
    arabic: 'تم التحقق من البريد الإلكتروني.',
  );
  String get verificationCodeSent => _t(
    'verificationCodeSent',
    'Verification code sent. Please check your email and enter the code to continue.',
    arabic:
        'تم إرسال رمز التحقق. يرجى التحقق من بريدك الإلكتروني وإدخال الرمز للمتابعة.',
  );
  String get enterValidEmail => _t(
    'enterValidEmail',
    'Enter a valid email address.',
    arabic: 'أدخل بريدًا إلكترونيًا صالحًا.',
  );
  String get enterEmailFirst => _t(
    'enterEmailFirst',
    'Please enter your email first.',
    arabic: 'يرجى إدخال بريدك الإلكتروني أولاً.',
  );
  String get enterVerificationCode => _t(
    'enterVerificationCode',
    'Enter the verification code you received.',
    arabic: 'أدخل رمز التحقق الذي استلمته.',
  );
  String get passwordBeforeVerification => _t(
    'passwordBeforeVerification',
    'Password must be at least 6 characters before verification.',
    arabic: 'يجب أن تتكون كلمة المرور من 6 أحرف على الأقل قبل التحقق.',
  );
  String get incomingCallSetup => _t(
    'incomingCallSetup',
    'Incoming call setup',
    arabic: 'إعداد المكالمات الواردة',
  );
  String get incomingCallSetupBody => _t(
    'incomingCallSetupBody',
    'Allow notifications so Talkflix can show incoming calls. On some Android versions, you may also be asked to allow full-screen call notifications.',
    arabic:
        'اسمح بالإشعارات حتى يتمكن Talkflix من عرض المكالمات الواردة. في بعض إصدارات Android، قد يُطلب منك أيضًا السماح بإشعارات المكالمات بملء الشاشة.',
  );
  String get notNow => _t('notNow', 'Not now', arabic: 'ليس الآن');

  String relationshipStatusLabel(String value) {
    switch (value.trim().toLowerCase()) {
      case 'married':
        return married;
      case 'single':
        return single;
      case 'divorced':
        return divorced;
      case 'searching':
        return searching;
      case 'widowed':
        return widowed;
      default:
        return value;
    }
  }
}

class _TalkflixLocalizationsDelegate
    extends LocalizationsDelegate<TalkflixLocalizations> {
  const _TalkflixLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) =>
      resolveTalkflixLocale(locale, supportedAppLocales) != null;

  @override
  Future<TalkflixLocalizations> load(Locale locale) {
    return SynchronousFuture<TalkflixLocalizations>(
      TalkflixLocalizations(locale),
    );
  }

  @override
  bool shouldReload(_TalkflixLocalizationsDelegate old) => false;
}

Locale? resolveTalkflixLocale(
  Locale? locale,
  Iterable<Locale> supportedLocales,
) {
  if (locale == null) return supportedLocales.firstOrNull;
  for (final supported in supportedLocales) {
    if (supported.languageCode == locale.languageCode &&
        (supported.countryCode == null ||
            supported.countryCode == locale.countryCode)) {
      return supported;
    }
  }
  for (final supported in supportedLocales) {
    if (supported.languageCode == locale.languageCode) {
      return supported;
    }
  }
  return supportedLocales.firstOrNull;
}

extension TalkflixLocalizationsX on BuildContext {
  TalkflixLocalizations get l10n => TalkflixLocalizations.of(this);
}
