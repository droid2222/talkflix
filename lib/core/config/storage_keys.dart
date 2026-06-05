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
  static const appLanguage = 'talkflix_app_language';

  // ── Login ──
  static const rememberLogin = 'tf_remember_login';
  static const savedEmail = 'tf_saved_email';

  // ── Notifications ──
  static const notificationsPref = 'tf_notifications_enabled';
  static const notificationMessagesEnabled = 'tf_notification_messages_enabled';
  static const notificationMessageSoundEnabled =
      'tf_notification_message_sound_enabled';
  static const notificationFollowersEnabled =
      'tf_notification_followers_enabled';
  static const notificationFollowerSoundEnabled =
      'tf_notification_follower_sound_enabled';
  static const chatAutoTranslateIncoming = 'tf_chat_auto_translate_incoming';
  static const chatShowTranslationOnLongPress =
      'tf_chat_show_translation_on_long_press';
  static const chatEnableWritingCorrections =
      'tf_chat_enable_writing_corrections';
  static const chatCorrectionTone = 'tf_chat_correction_tone';
  static const chatTranslateTargetLanguage = 'tf_chat_translate_target_lang';
  static const chatPlayVoiceNotesAuto = 'tf_chat_play_voice_notes_auto';
  static const profilePrivacyShowAge = 'tf_profile_privacy_show_age';
  static const profilePrivacyShowFlag = 'tf_profile_privacy_show_flag';
  static const profilePrivacyShowFollowStats =
      'tf_profile_privacy_show_follow_stats';
  static const profilePrivacyShowOnlineStatus =
      'tf_profile_privacy_show_online_status';
  static const profilePrivacyReceiveVoiceCalls =
      'tf_profile_privacy_receive_voice_calls';
  static const profilePrivacyReceiveVideoCalls =
      'tf_profile_privacy_receive_video_calls';
  static const talkPinnedThreadIds = 'tf_talk_pinned_thread_ids';
  static const talkDeletedThreadIds = 'tf_talk_deleted_thread_ids';
  static const talkThreadMutedPrefix = 'tf_talk_thread_muted_';
  static const talkThreadReceiveVoiceCallsPrefix =
      'tf_talk_thread_receive_voice_calls_';
  static const talkThreadReceiveVideoCallsPrefix =
      'tf_talk_thread_receive_video_calls_';
  static const directChatCachePrefix = 'tf_direct_chat_cache_';
  static const contentSavedItemIdsPrefix = 'tf_content_saved_item_ids_';
  static const contentSubtitleLanguagePrefix = 'tf_content_subtitle_language_';
  static const liveCommentTheme = 'tf_live_comment_theme';
  static const liveMicEffect = 'tf_live_mic_effect';

  // ── QA / Diagnostics ──
  static const qaChecklistPrefix = 'qa_checklist_';
}
