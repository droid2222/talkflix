# Talkflix Flutter

Flutter client for Talkflix (iOS, Android, web). Talks to the Node.js + MySQL API at `https://api.talkflix.cc` by default.

## Quick start

```bash
flutter pub get
flutter run
```

Local API on a physical device (same Wi‑Fi as your Mac):

```bash
flutter run --dart-define=API_BASE_URL=http://YOUR_MAC_LAN_IP:4000
```

More setup (simulator, Android emulator, backend checkout, iOS pods): **[docs/local-development.md](docs/local-development.md)**.

## Documentation

Full index: **[docs/README.md](docs/README.md)**

| Topic | Document |
| --- | --- |
| App structure | [docs/architecture.md](docs/architecture.md) |
| Feature flags & `--dart-define` | [docs/configuration.md](docs/configuration.md) |
| Backend contracts | [docs/backend-contracts.md](docs/backend-contracts.md) |
| Supported scripts | [docs/repository-scripts.md](docs/repository-scripts.md) |
| Manual QA | [docs/qa-manual.md](docs/qa-manual.md) |
| **V1 launch handoff** | [docs/v1-release-handoff.md](docs/v1-release-handoff.md) |
| App Store / Play checklist | [docs/app_store_submission_checklist.md](docs/app_store_submission_checklist.md) |
| Open engineering issues | [docs/pending-issues.md](docs/pending-issues.md) |
| Admin dashboard (production) | [docs/admin-dashboard.md](docs/admin-dashboard.md) |
| Public web homepage | [docs/web-homepage.md](docs/web-homepage.md) |
| Web commerce | [docs/web-commerce.md](docs/web-commerce.md) |
| Pro entitlements | [docs/pro-entitlements.md](docs/pro-entitlements.md) |
| Production backups | [docs/production-backup-retention.md](docs/production-backup-retention.md) |

## Current product scope

- Auth, signup, profile, privacy, block/report, account deletion
- Talk inbox, direct chat (text, media, voice notes), direct voice/video calls
- Meet discovery, anonymous match, live rooms
- Content feed and creator posting
- Talkflix Pro via native IAP

Not a starter template — focus is hardening and real-device QA before launch.

## Release identifiers

- Android `applicationId` / iOS bundle id: `cc.talkflix.app`
- Version: see `pubspec.yaml` (`version: x.y.z+build`)

Android release signing: [android/key.properties.example](android/key.properties.example). Without `key.properties`, release builds use the debug key (not for store upload).

## Debug-only QA tools

Diagnostics, QA checklist, and media preview are available only in **debug** builds (`AppConfig.localQaToolsEnabled`). Profile/release builds must not expose these routes. Details: [docs/configuration.md](docs/configuration.md).

## Verify

```bash
dart analyze
flutter test
```

Contributor workflow: [CONTRIBUTING.md](CONTRIBUTING.md). Recent notable changes: [CHANGELOG.md](CHANGELOG.md).
