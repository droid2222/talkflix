# Talkflix v1 Release Handoff

Last updated: 2026-06-05

This document is the practical handoff for the current v1 release branch. It is written for a future developer or team that needs to continue the app without relying on chat history.

## Repositories And Production Paths

Flutter app:

```text
/Users/talkflix/talkflix_flutter
```

Backend API:

```text
/Users/genius/talkflixproject/talkflix-api
```

Production backend path on the droplet:

```text
/opt/talkflix-api
```

Admin dashboard production path:

```text
/var/www/talkflix-admin/index.html
```

Public URLs:

```text
https://api.talkflix.cc
https://talkflix.cc/admin/
https://www.talkflix.cc
```

## Current V1 Scope

V1 includes:

- Authentication, signup, login, forgot/reset password, session restore.
- Profile, edit profile, privacy settings, block/report, account deletion.
- Main content feed, shared content links, and creator posting flows.
- Direct chat with text, media, voice notes, message actions, and combined call logs.
- Direct voice and video calling.
- Live room browse/create/join flows.
- Meet/discovery flows and Pro-gated discovery behavior.
- Talkflix Pro subscriptions through native App Store and Google Play IAP.
- Public homepage, privacy policy, and terms routes.

The public web homepage is launch-critical. Preserve the `/` route, source file, required assets, and footer legal links documented in:

```text
docs/web-homepage.md
```

V1 intentionally defers:

- Device contacts invite/save flows. Contacts are disabled by default for review builds.

## Feature Gates

The main release gates are in:

```text
lib/core/config/app_config.dart
```

Current defaults:

- `directCallsEnabled`: true
- `deviceContactsEnabled`: false
- `paidUpgradeEnabled`: true

Do not remove these gates casually. They are useful for emergency rollback, review builds, and staged rollout.

## Native Launch Screen

The iOS native launch screen was fixed on 2026-06-05.

Files:

```text
ios/Runner/Base.lproj/LaunchScreen.storyboard
ios/Runner/Base.lproj/Main.storyboard
ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage.png
ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage@2x.png
ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage@3x.png
```

Important details:

- The old launch images were transparent `1x1` PNGs, which caused a blank white launch screen on iOS.
- The launch images now use the Talkflix logo at `90x29`, `180x58`, and `270x87`.
- `LaunchScreen.storyboard` and `Main.storyboard` use iOS `systemBackgroundColor`, so the pre-Flutter background follows the phone light/dark appearance.
- iOS caches launch-screen snapshots. When testing this change on a physical iPhone, uninstall the app before reinstalling.

Verification used:

```bash
flutter build ios --release --no-codesign
dart analyze
xcrun assetutil --info build/ios/iphoneos/Runner.app/Assets.car
```

The compiled release asset catalog must contain `LaunchImage.png`, `LaunchImage@2x.png`, and `LaunchImage@3x.png` with the sizes above.

## Native iOS Scene Lifecycle

The iOS scene lifecycle warning was addressed on 2026-06-05.

Files:

```text
ios/Runner/Info.plist
ios/Runner/SceneDelegate.swift
ios/Runner.xcodeproj/project.pbxproj
```

Important details:

- `Info.plist` now declares `UIApplicationSceneManifest`.
- `UIApplicationSupportsMultipleScenes` is false for the v1 single-window app.
- `UISceneDelegateClassName` is `$(PRODUCT_MODULE_NAME).SceneDelegate`.
- `UISceneStoryboardFile` is `Main`.
- `SceneDelegate.swift` preserves deep-link routing for shared content, shared live rooms, and Talkflix custom scheme links.

Verification used:

```bash
plutil -lint ios/Runner/Info.plist
plutil -p ios/Runner/Info.plist
flutter build ios --release --no-codesign
```

`flutter build ios --release --no-codesign` passed on 2026-06-05 and the previous `UIScene` lifecycle warning did not appear in the build output.

## Notifications

Direct-message notifications must still notify users normally, but direct-message events must not appear in the notification-center list opened from the main chat screen.

Client files:

```text
lib/features/notifications/data/app_notification.dart
lib/features/notifications/presentation/notifications_controller.dart
lib/features/notifications/presentation/notifications_screen.dart
test/features/notifications/app_notification_test.dart
```

Current behavior:

- `AppNotification.isMessageType` recognizes `message`, `direct_message`, and `chat_message`.
- `AppNotification.isNotificationCenterVisible` returns false for direct-message event types.
- The notification controller filters fetched notification history before displaying it.
- Realtime message notifications can still play notification sound according to user notification settings and muted-thread state.
- The notification-center empty state no longer says messages will appear there.

Regression test:

```bash
flutter test test/features/notifications/app_notification_test.dart
```

## Direct Calls

Direct calls are required for v1. Do not disable them for release.

Main client areas:

```text
lib/features/talk/presentation/direct_chat_screen.dart
lib/core/realtime/direct_call_controller.dart
lib/core/realtime/direct_call_registration_controller.dart
lib/core/realtime/dm_callkit_bridge.dart
lib/features/talk/data/direct_call_log_entry.dart
lib/features/talk/presentation/direct_call_log_screen.dart
```

Main backend areas:

```text
/Users/genius/talkflixproject/talkflix-api/server.js
/Users/genius/talkflixproject/talkflix-api/socket.js
```

Important current behavior:

- Direct-call receiving defaults are on for new/missing preferences.
- Explicit user opt-outs must still be respected.
- Deleted accounts still have call receiving disabled.
- Call logs belong on the main chat screen, not inside an individual chat menu.
- Direct call notifications should be recorded in chat history/call logs, not as noisy notification-center list items.

Known production risk:

- Direct 1:1 calls still need TURN configuration for stronger reliability across restrictive networks.
- See `docs/pending-issues.md` and `/Users/genius/talkflixproject/talkflix-api/docs/pending-issues.md`.

## Pro IAP

The app currently supports three native subscription products:

```text
talkflix_pro_monthly
talkflix_pro_3_months
talkflix_pro_yearly
```

Client product list:

```text
lib/core/config/app_config.dart
```

Client purchase flow:

```text
lib/features/upgrade/data/pro_purchase_repository.dart
lib/features/upgrade/presentation/pro_purchase_controller.dart
lib/features/upgrade/presentation/upgrade_screen.dart
```

Backend verification:

```text
/Users/genius/talkflixproject/talkflix-api/server.js
/Users/genius/talkflixproject/talkflix-api/migrations/003_mobile_iap_purchases_mysql.sql
```

Required production environment keys:

```text
IAP_PRO_PRODUCT_IDS
IAP_APPLE_BUNDLE_ID
APPLE_IAP_ISSUER_ID
APPLE_IAP_KEY_ID
APPLE_IAP_PRIVATE_KEY
APPLE_IAP_ENVIRONMENT
IAP_GOOGLE_PACKAGE_NAME
GOOGLE_PLAY_SERVICE_ACCOUNT_JSON
GOOGLE_PLAY_SERVICE_ACCOUNT_FILE
GOOGLE_PLAY_CLIENT_EMAIL
GOOGLE_PLAY_PRIVATE_KEY
```

Only one Google credential style is required:

- `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON`, or
- `GOOGLE_PLAY_SERVICE_ACCOUNT_FILE`, or
- `GOOGLE_PLAY_CLIENT_EMAIL` plus `GOOGLE_PLAY_PRIVATE_KEY`.

Important:

- Production did not have the IAP env keys when this note was written.
- Real purchases will not verify until those credentials are added to the backend environment and PM2 is restarted.
- The mobile app must never unlock Pro from local purchase state alone. Pro is granted only after backend store verification.

Store setup required before launch:

- Create all three product IDs in App Store Connect.
- Create all three product IDs in Play Console.
- Keep IDs exactly matching the strings above unless `IAP_PRO_PRODUCT_IDS` is intentionally changed in both app/backend.
- Complete sandbox/internal-track purchase and restore testing for all three plans.

## Database Migrations

Backend migrations added for current release work:

```text
/Users/genius/talkflixproject/talkflix-api/migrations/002_content_feed_upgrade_mysql.sql
/Users/genius/talkflixproject/talkflix-api/migrations/003_mobile_iap_purchases_mysql.sql
/Users/genius/talkflixproject/talkflix-api/migrations/004_direct_call_receive_defaults_mysql.sql
```

`004_direct_call_receive_defaults_mysql.sql` changes direct-call receive column defaults to enabled for new users. It intentionally does not backfill existing `0` values, because those may be real opt-outs.

Production DB verification:

```text
/Users/genius/talkflixproject/talkflix-api/docs/production-db-migrations.md
```

Verified on 2026-06-05:

- `content_saves` exists.
- `iap_purchases` exists.
- `users.receive_voice_calls` default is `1` and nullable is `NO`.
- `users.receive_video_calls` default is `1` and nullable is `NO`.

## Admin Dashboard And Diagnostics

Admin dashboard details live in:

```text
docs/admin-dashboard.md
```

Production backup retention and cleanup rules live in:

```text
docs/production-backup-retention.md
```

Review-build rule:

- Normal users should not see in-app diagnostics or QA back doors in production.
- Flutter diagnostics, QA checklist, and media preview entry points are controlled by `AppConfig.localQaToolsEnabled` in `lib/core/config/app_config.dart`.
- `AppConfig.localQaToolsEnabled` is true only in Flutter debug builds. It must remain false for profile/release builds submitted to App Store, Play Store, or production web.
- Diagnostic data that is still useful should be moved to or exposed through the admin dashboard.
- Debug-only Flutter routes are acceptable for local development, but do not rely on them as production support tools.

## Build And Verification Commands

Flutter app:

```bash
dart analyze
flutter test
flutter build appbundle --release
flutter build ios --release --no-codesign
flutter build web --release
```

Backend syntax checks:

```bash
node --check /Users/genius/talkflixproject/talkflix-api/server.js
node --check /Users/genius/talkflixproject/talkflix-api/socket.js
```

iOS dependency sync after `flutter clean`:

```bash
flutter pub get
cd ios
pod install
```

If `pod install` says `Generated.xcconfig must exist`, run `flutter pub get` first, then rerun `pod install`.

## Production Backend Deployment Checklist

Before copying API changes to production:

```bash
node --check /Users/genius/talkflixproject/talkflix-api/server.js
node --check /Users/genius/talkflixproject/talkflix-api/socket.js
```

On production, keep backups before overwriting:

```text
/opt/talkflix-api/server.js
/opt/talkflix-api/socket.js
```

After deployment:

```bash
pm2 restart talkflix-api
pm2 status talkflix-api
curl -sS https://api.talkflix.cc/health
```

Do not commit production `.env` values or store API keys in the app repository.

## Final Launch Blockers

Do not submit until these are resolved or explicitly accepted:

- IAP production Apple/Google verification credentials are configured and PM2 is restarted.
- All three Pro plans purchase and restore successfully in sandbox/internal testing.
- App Store / Play Console privacy and subscription metadata match the actual app behavior.
- Signed iOS and Android release artifacts are produced and installed on real devices.
- Store screenshots, build numbers, reviewer notes, and reviewer test credentials are finalized in App Store Connect and Play Console.

Resolved or accepted for v1 on 2026-06-05:

- Direct voice/video call QA was user-reported as passing.
- iOS `UIApplicationSceneManifest` is present and `SceneDelegate.swift` is wired into the Runner target.
- Contacts are disabled by `AppConfig.deviceContactsEnabled=false`; Android removes contacts permissions from the merged manifest.
- In-app diagnostics/QA entry points are controlled by `AppConfig.localQaToolsEnabled`, which is false in profile/release builds.
- Production backup retention is documented and old live-folder backups were moved to a root-only archive.
- Production DB migrations listed in this handoff were verified; direct-call receive defaults are now `1`.
- TURN/TLS is accepted as a v1 launch risk because direct-call QA passed on real devices. Revisit this immediately if calls fail on restrictive networks.

Final local verification on 2026-06-05:

```text
dart analyze: passed
flutter test: 135 tests passed
node --check server.js: passed
node --check socket.js: passed
flutter build ios --release --no-codesign: passed, Runner.app 47.2MB
flutter build appbundle --release: passed, app-release.aab 82.0MB
flutter build web --release: passed
https://api.talkflix.cc/health: {"ok":true}
```

Android release manifest verification:

```text
build/app/intermediates/packaged_manifests/release/processReleaseManifestForPackage/AndroidManifest.xml
```

No `READ_CONTACTS`, `WRITE_CONTACTS`, `GET_ACCOUNTS`, or `android.permission.CONTACT*` entries were present in the packaged release manifest.

## Handoff Rules For Future Work

- Update this file whenever release scope, product IDs, feature gates, or production setup changes.
- Update `docs/app_store_submission_checklist.md` when store-review requirements change.
- Update `/Users/genius/talkflixproject/talkflix-api/README.md` when backend env vars or deployment steps change.
- Prefer exact file paths, command outputs, and dates. Do not write assumptions as facts.
