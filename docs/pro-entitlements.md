# Talkflix Pro Entitlements

Last updated: 2026-06-07

Talkflix Pro is positioned as uninterrupted access. Free users can try the main app features, but daily limits create waits and interruptions. Pro, trial, admin, and superadmin users bypass these free-plan limits.

## Current Free Defaults

Daily reset policy: UTC day.

| Limit key | Free default | Pro behavior |
| --- | ---: | --- |
| `content_watch_seconds_daily` | 15 minutes/day | Unlimited videos and podcasts |
| `live_audience_seconds_daily` | 30 minutes/day | Unlimited live-room audience time |
| `live_host_seconds_daily` | 60 minutes/day | Unlimited live-room hosting |
| `live_stage_seconds_daily` | 5 minutes/day | Unlimited stage/speaker time |
| `direct_call_seconds_daily` | 5 minutes/day | Unlimited direct-call initiation time |
| `chat_ai_actions_daily` | 10 actions/day | Unlimited direct-chat translation actions |

## Backend Source Of Truth

Backend files:

```text
/Users/genius/talkflixproject/talkflix-api/entitlements.js
/Users/genius/talkflixproject/talkflix-api/server.js
/Users/genius/talkflixproject/talkflix-api/socket.js
```

Tables/settings:

```text
app_settings.setting_key = free_usage_limit.<limit_key>
user_daily_usage(user_id, usage_key, usage_date, used_amount)
```

The backend creates `user_daily_usage` at startup through `ensureEntitlementTables`.

Admin API:

```text
GET   /admin/pro-limits
PATCH /admin/pro-limits
```

Authenticated app API:

```text
GET  /me/entitlements
POST /me/usage/content-watch
```

`PATCH /admin/pro-limits` accepts numeric values in backend units. Time keys use seconds. `content_watch_seconds_daily` can also be sent as an object with `minutes` or `seconds`.

Production deployment status on 2026-06-07:

- Backend files deployed to `/opt/talkflix-api`.
- PM2 process `talkflix-api` restarted and health check returned `{"ok":true}`.
- Production backup: `/root/talkflix-production-backups/20260607-pro-entitlements/`.
- Admin dashboard HTML deployed to `/var/www/talkflix-admin/index.html` with a production backup named `index.html.backup-<timestamp>-pro-limits`.

## Enforcement

- Direct calls: `socket.js` checks remaining free direct-call seconds before ringing another user. The server starts a timer when the call connects and ends the call when the free daily allowance is exhausted.
- Live hosting: `socket.js` checks remaining host seconds before creating a room. The room ends when the free host allowance is exhausted.
- Live audience: `socket.js` checks remaining audience seconds before joining a room. The user is removed when the allowance is exhausted.
- Live stage: `socket.js` checks remaining stage seconds when a user is approved/ready for stage. The user leaves stage when the allowance is exhausted.
- Direct-chat AI: `server.js` checks and consumes `chat_ai_actions_daily` for the existing direct-message translation endpoint.
- Content watch/listen: Flutter reports active video/podcast playback to `POST /me/usage/content-watch` and pauses playback when the backend returns `FREE_USAGE_LIMIT_REACHED`.

## Known Limitation

Content media is currently served as static `/uploads` URLs. The app enforces watch/listen limits in the Flutter playback UX, but raw media URL access is not cryptographically blocked. A stronger production version should use tokenized media URLs or a streaming proxy before treating content watch limits as tamper-proof.

## Flutter UI

Flutter files:

```text
/Users/talkflix/talkflix_flutter/lib/features/upgrade/presentation/upgrade_screen.dart
/Users/talkflix/talkflix_flutter/lib/features/upgrade/presentation/pro_access_sheet.dart
/Users/talkflix/talkflix_flutter/lib/features/content/data/content_repository.dart
/Users/talkflix/talkflix_flutter/lib/features/content/presentation/content_video_screen.dart
/Users/talkflix/talkflix_flutter/lib/features/content/presentation/content_screen.dart
```

The upgrade screen now describes Pro as uninterrupted access: unlimited videos/podcasts, direct calls, live-room audience time, hosting, stage time, chat translations, and advanced partner discovery.
