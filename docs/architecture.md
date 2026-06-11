# Talkflix Flutter architecture

Last updated: 2026-06-10

This document describes how the mobile/web Flutter client is organized. It does not document the Node.js API implementation (see backend repo or `docs/v1-release-handoff.md` for production paths).

## Stack

| Layer | Choice |
| --- | --- |
| UI | Flutter (Material) |
| State | Riverpod (`StateNotifier`, `FutureProvider`, `Provider`) |
| Routing | `go_router` with auth redirect |
| HTTP | `ApiClient` → `https://api.talkflix.cc` by default |
| Realtime | Socket.IO (`SocketService`) |
| 1:1 calls | WebRTC P2P + optional CallKit (iOS) |
| Live audio rooms | LiveKit SFU when `AppConfig.liveUseSfuAudio` is true |
| IAP | Native store purchases via `pro_purchase_repository` |

Entry point: `lib/main.dart` → `lib/app/app.dart`.

## Directory layout

```text
lib/
  app/           Router, theme, localization, root widget
  core/          Shared infrastructure (no product screens)
    auth/        Session, AppUser, privacy helpers
    config/      AppConfig, StorageKeys, privacy prefs
    network/     ApiClient, exceptions
    realtime/    Socket, WebRTC, direct calls, CallKit, push registration
    media/       Permissions, ringtone, audio player
    widgets/     Reusable UI (avatars, banners, scaffolds)
  features/      Product areas (data + presentation)
    auth/        Login, signup, password reset
    shell/       Bottom nav shell, global incoming call handling
    talk/        Inbox, direct chat, call logs
    meet/        Discovery, filters, anonymous match
    live/        Live rooms, stage, comments, SFU session
    profile/     Profile, settings, edit, QR, diagnostics (debug)
    content/     Feed, video, composers, creator studio
    upgrade/     Pro paywall and purchase flow
    notifications/
    commerce/    Coaching web surface
    legal/       Account deletion (public route)
```

Convention: `features/<name>/data/` for repositories and DTOs; `features/<name>/presentation/` for screens; `features/<name>/application/` for controllers that sit between UI and data.

## Authentication and session

1. `AuthRepository` exchanges credentials for a token.
2. `SessionController` holds token, user (`AppUser`), and session id.
3. `app_router.dart` redirects unauthenticated users to `/login` (except public routes).
4. On connect, `SocketService` uses the session token and validates user/session id.

Public routes (no login required) include login/signup, legal pages, `/account-deletion`, shared content/live links, and the web coaching routes. See `publicLocations` and related checks in `app_router.dart`.

## Feature gates

Product rollout switches live in `AppConfig` (see [configuration.md](configuration.md)):

- `directCallsEnabled` — voice/video calls, CallKit, call logs
- `deviceContactsEnabled` — device contacts invite/save (off for v1 review)
- `paidUpgradeEnabled` — native IAP upgrade UI
- `localQaToolsEnabled` — diagnostics routes (`kDebugMode` only)

Router and screens check these flags before exposing routes or UI.

## Realtime flows

### Direct chat

- `TalkRepository` / `DirectChatRepository` — REST for threads and messages
- `DirectChatController` — socket subscriptions (`dm:message`, typing, presence)
- `DirectChatScreen` — UI, media upload, call entry points

### Direct calls

- Signaling over Socket.IO (`dm:call:*` events)
- Media via `WebRtcService` (P2P)
- iOS incoming UI: `DmCallKitBridge` + `flutter_callkit_incoming`
- Push registration: `DirectCallRegistrationController`, `DirectCallPushService`

### Anonymous meet

- `MeetAnonScreen` — queue, match, chat, and calls over socket match ids

### Live rooms

- `LiveScreen` — room list, host/listener/speaker roles
- `LiveRoomSessionController` — stage state and permissions
- Audio path uses LiveKit when SFU flag is on; host moderation uses ack-driven socket events

## Data and caching

- **Session user:** from `/me` via `SessionController.refreshProfile()`
- **Other profiles:** `GET /users/:id` via `profileProvider` in `profile_screen.dart`
- **Local prefs:** centralized keys in `StorageKeys` (theme, privacy toggles, chat prefs, QA checklist in debug)
- **Some privacy toggles:** server (`/me/privacy`) for age, flag, location, follow stats; local-only for online status and per-device call receive prefs

## Web vs mobile

- Same codebase; `kIsWeb` guards native-only features (CallKit, some push paths).
- Public marketing homepage is **static** (`web/index.html`), not Flutter-generated. Use `tool/build_web_preserving_homepage.sh` for web releases (see [web-homepage.md](web-homepage.md)).

## Testing

```bash
dart analyze
flutter test
```

Widget tests cover diagnostics/QA screens, `AppConfig`, and core auth parsing. They do not replace the manual checklist in [qa-manual.md](qa-manual.md).

## Related backend

The API is Node.js + MySQL. Production runs on the droplet at `/opt/talkflix-api` behind `https://api.talkflix.cc`. Client assumes REST + Socket.IO on the same API host unless `API_BASE_URL` overrides it.
