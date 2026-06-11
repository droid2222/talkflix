# Talkflix Pro Entitlements

Last updated: 2026-06-11

Talkflix Pro is positioned as uninterrupted access. Free users can try the main app features, but daily limits create waits and interruptions. Pro, admin, and superadmin users bypass these free-plan limits.

The app no longer presents a free-trial upgrade option. When a free user taps a Pro-only feature or reaches a daily free limit, the app navigates directly to the Pro purchase screen.

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
$TALKFLIX_API_ROOT/entitlements.js
$TALKFLIX_API_ROOT/server.js
$TALKFLIX_API_ROOT/socket.js
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

Production deployment status on 2026-06-11:

- Web Pro checkout deployed with mobile/web payment split: iOS and Android use native IAP; web uses Stripe Checkout.
- Backend deployed to `/opt/talkflix-api/server.js` and PM2 restarted with `--update-env`.
- Flutter web build deployed to `/var/www/talkflix-web` with the guarded homepage-preserving build flow.
- Production backup: `/root/talkflix-production-backups/20260611-web-pro-stripe/`.
- Live verification: `https://www.talkflix.cc/`, `https://www.talkflix.cc/app/upgrade?feature=Direct%20calling`, and `https://api.talkflix.cc/billing/pro/stripe-plans` returned 200/valid JSON after deployment.

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
lib/features/upgrade/presentation/upgrade_screen.dart
lib/features/upgrade/presentation/pro_access_sheet.dart
lib/features/content/data/content_repository.dart
lib/features/content/presentation/content_video_screen.dart
lib/features/content/presentation/content_screen.dart
```

The upgrade screen now uses a full-screen paywall with Talkflix branding, a compact auto-looping benefit carousel, and monthly, six-month, and yearly plan cards. The carousel advances every four seconds, loops back to the first benefit, and restarts its timer after manual swipes. On narrow screens, the carousel and plan cards use tighter spacing so plan comparison remains the priority. On iOS and Android, prices and purchase flow come from App Store / Google Play product data. On web, prices come from `GET /billing/pro/stripe-plans`, checkout starts with `POST /billing/pro/stripe-checkout-sessions`, and Stripe webhooks activate Pro after payment confirmation.

Web Pro checkout uses the same Stripe configuration as web coaching commerce. Optional backend overrides are `STRIPE_PRO_MONTHLY_PRICE_ID`, `STRIPE_PRO_6_MONTHS_PRICE_ID`, `STRIPE_PRO_YEARLY_PRICE_ID`, `STRIPE_PRO_MONTHLY_AMOUNT_CENTS`, `STRIPE_PRO_6_MONTHS_AMOUNT_CENTS`, `STRIPE_PRO_YEARLY_AMOUNT_CENTS`, and `STRIPE_PRO_CURRENCY`. If Stripe Price IDs are not configured, the backend creates recurring Checkout price data from the configured amount cents.
