# Talkflix documentation index

Start here if you are new to the repo or preparing a release.

| Document | When to read it |
| --- | --- |
| [../README.md](../README.md) | Quick start, default API, links into deeper docs |
| [local-development.md](local-development.md) | Run Flutter + optional local backend on any machine |
| [architecture.md](architecture.md) | How the Flutter app is structured |
| [configuration.md](configuration.md) | `AppConfig`, `--dart-define`, and feature gates |
| [backend-contracts.md](backend-contracts.md) | Flutter-owned expectations for REST, Socket.IO, and backend docs |
| [repository-scripts.md](repository-scripts.md) | Supported `tool/` scripts and what not to run in prod |
| [qa-manual.md](qa-manual.md) | Real-device manual QA checklist |
| [v1-release-handoff.md](v1-release-handoff.md) | **Primary launch handoff** — scope, IAP, deployment, blockers |
| [app_store_submission_checklist.md](app_store_submission_checklist.md) | App Store / Play submission steps |
| [pending-issues.md](pending-issues.md) | Open product/engineering risks (P1/P2) |
| [admin-dashboard.md](admin-dashboard.md) | Production admin UI on the droplet |
| [web-homepage.md](web-homepage.md) | Static public homepage — do not overwrite by mistake |
| [web-commerce.md](web-commerce.md) | `/coaching` web route and commerce API notes |
| [pro-entitlements.md](pro-entitlements.md) | Free vs Pro limits and backend entitlements |
| [production-backup-retention.md](production-backup-retention.md) | Droplet backup and cleanup policy |

## Source-of-truth rules

- **Launch scope and blockers:** `v1-release-handoff.md`
- **Open engineering risks:** `pending-issues.md` (update when status changes)
- **Runtime flags and URLs:** `lib/core/config/app_config.dart` + [configuration.md](configuration.md)
- **Production paths on the droplet:** `admin-dashboard.md` and `v1-release-handoff.md`

If two documents disagree, prefer the newer “Last updated” date and verify in code.
