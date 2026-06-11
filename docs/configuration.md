# Configuration reference

Last updated: 2026-06-10

Runtime configuration is centralized in `lib/core/config/app_config.dart`. Build-time overrides use Flutter `--dart-define=KEY=value`.

## URLs and support (constants)

| Symbol | Default | Purpose |
| --- | --- | --- |
| `AppConfig.apiBaseUrl` | `https://api.talkflix.cc` | REST and socket base (unless overridden) |
| `AppConfig.publicMarketingUrl` | `https://www.talkflix.cc` | Marketing, SMS invite, share links |
| `AppConfig.supportUrl` | `https://www.talkflix.cc/support` | Public store-review support URL |
| `AppConfig.accountDeletionUrl` | `https://www.talkflix.cc/account-deletion` | Store metadata and legal links |
| `AppConfig.supportEmail` | `info@talkflix.cc` | Help and deletion email templates |

## Feature gates (`--dart-define`)

Boolean flags accept `true` / `false` / `1` / `0` / `yes` / `no`. Empty means use the **fallback** below.

| Define | Fallback | Effect |
| --- | --- | --- |
| `DIRECT_CALLS_ENABLED` | `true` | Direct voice/video calls, call logs, CallKit wiring |
| `DEVICE_CONTACTS_ENABLED` | `false` | Device contacts read/write and invite flows |
| `PAID_UPGRADE_ENABLED` | `true` | Native IAP upgrade screens |
| `LIVE_USE_ACK_MODERATION` | `true` | Live room moderation ack path |
| `LIVE_REQUIRE_HOST_MODERATION` | `true` | Host approval for stage |
| `LIVE_USE_SFU_SPEAKING_INDICATOR` | `true` | SFU speaking indicator |
| `LIVE_USE_SFU_AUDIO` | `true` | LiveKit SFU for audio rooms |

### Debug-only (not a dart-define)

| Symbol | Value | Effect |
| --- | --- | --- |
| `AppConfig.localQaToolsEnabled` | `kDebugMode` | Registers `/app/profile/diagnostics`, qa-checklist, media-preview |

Profile and release builds must keep QA tools off for store review.

## API and RTC overrides

| Define | Purpose |
| --- | --- |
| `API_BASE_URL` | Full API origin, e.g. `http://192.168.1.20:4000` for LAN dev |
| `RTC_ICE_SERVERS_JSON` | JSON array of ICE server objects (replaces default STUN list) |
| `RTC_TURN_URL` | TURN URL (used with username/credential below) |
| `RTC_TURN_USERNAME` | TURN username |
| `RTC_TURN_CREDENTIAL` | TURN credential |

Default RTC uses Google STUN only unless TURN defines are set.

## In-app purchases

| Define | Purpose |
| --- | --- |
| `IAP_PRO_PRODUCT_IDS` | Comma-separated store product ids; overrides defaults |

Default product ids:

- `talkflix_pro_monthly_v2`
- `talkflix_pro_6_months`
- `talkflix_pro_yearly`

## Example commands

Production-like run (default API):

```bash
flutter run
```

Local backend on LAN:

```bash
flutter run --dart-define=API_BASE_URL=http://192.168.1.20:4000
```

Review build without direct calls:

```bash
flutter run --release --dart-define=DIRECT_CALLS_ENABLED=false
```

Local backend without LiveKit SFU:

```bash
flutter run --dart-define=API_BASE_URL=http://127.0.0.1:4000 \
  --dart-define=LIVE_USE_SFU_AUDIO=false
```

## Local persistence

SharedPreferences keys are listed in `lib/core/config/storage_keys.dart`. Do not duplicate key strings elsewhere.

## Production server configuration

Backend secrets (DB, JWT, IAP verification, Stripe, LiveKit, push keys) live in `/opt/talkflix-api/.env` on the droplet — **never** commit them to this repo. See `docs/v1-release-handoff.md` for deployment checks.
