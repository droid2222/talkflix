/// Centralized SharedPreferences keys for the entire app.
///
/// All persistent storage keys live here to prevent duplication
/// and make it easy to audit what's being stored locally.
class StorageKeys {
  StorageKeys._();

  // ── Auth / Session ──
  static const token = 'talkflix_token';

  // ── Theme ──
  static const themeMode = 'talkflix_theme_mode';

  // ── Login ──
  static const rememberLogin = 'tf_remember_login';
  static const savedEmail = 'tf_saved_email';

  // ── Notifications ──
  static const notificationsPref = 'tf_notifications_enabled';
  static const chatAutoTranslateIncoming = 'tf_chat_auto_translate_incoming';
  static const chatShowTranslationOnLongPress =
      'tf_chat_show_translation_on_long_press';
  static const chatEnableWritingCorrections =
      'tf_chat_enable_writing_corrections';
  static const chatCorrectionTone = 'tf_chat_correction_tone';
  static const chatPlayVoiceNotesAuto = 'tf_chat_play_voice_notes_auto';
  static const directChatCachePrefix = 'tf_direct_chat_cache_';
  static const accountGoogleBound = 'tf_account_google_bound';
  static const accountFacebookBound = 'tf_account_facebook_bound';
  static const accountAppleBound = 'tf_account_apple_bound';
  static const accountPhoneNumber = 'tf_account_phone_number';

  // ── QA / Diagnostics ──
  static const qaChecklistPrefix = 'qa_checklist_';
}
