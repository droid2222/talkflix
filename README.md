# Talkflix Flutter

Flutter mobile client for Talkflix, built against the existing Node.js + MySQL backend.

## Current status

The Flutter app now includes real first-pass implementations for:

- login and multi-step signup
- talk inbox and direct chat
- direct voice/video calling
- anonymous match and anonymous chat/calls
- live rooms, comments, stage controls, and live RTC groundwork
- profile, follow/following, meet discovery, filters, upgrade, and content hub

This is no longer a starter project. The main focus moving forward is product hardening and real device QA.

## Local backend

Run the API locally from:

```bash
cd /Users/genius/talkflixproject/talkflix-api
npm run dev
```

MySQL should also be running locally, with the `talkflix` database imported from:

[`/Users/genius/talkflixproject/talkflix.sql`](/Users/genius/talkflixproject/talkflix.sql)

Useful backend check:

```bash
curl http://127.0.0.1:4000/health
```

Expected response:

```json
{"ok":true,"db":true}
```

## Running the Flutter app

All builds now default to the deployed API at `https://api.talkflix.cc` unless `API_BASE_URL` is provided explicitly.

### iOS Simulator

```bash
cd /Users/talkflix/talkflix_flutter
flutter run
```

### Android Emulator

```bash
cd /Users/talkflix/talkflix_flutter
flutter run
```

### Physical iPhone or Android device

Override the API base URL only when you intentionally want to hit a local backend:

```bash
cd /Users/talkflix/talkflix_flutter
flutter run --dart-define=API_BASE_URL=http://YOUR_MAC_LAN_IP:4000
```

Example:

```bash
flutter run --dart-define=API_BASE_URL=http://192.168.1.20:4000
```

## Testing notes

- All build modes default to `https://api.talkflix.cc`.
- Android cleartext HTTP is enabled for development.
- iOS local-network development access is enabled for local backend testing.
- Before testing on a physical phone, make sure the phone and your Mac are on the same Wi-Fi network.
- For two-client testing, use any combination of:
  - iOS Simulator + physical phone
  - Android Emulator + physical phone
- two physical phones on the same network

## Release prep

### Android signing

Create `android/key.properties` from [`android/key.properties.example`](/Users/talkflix/talkflix_flutter/android/key.properties.example) and point it at your upload keystore before building a Play Store release.

If `android/key.properties` is not present, release builds fall back to the debug signing key so local `--release` builds still work, but that output is not suitable for store submission.

### Current identifiers

- Android `applicationId`: `cc.talkflix.app`
- iOS bundle identifier: `cc.talkflix.app`

If you do not want `.dev` in production, change both identifiers before submitting the first store build.

## In-app QA tools

- `Profile -> Diagnostics` shows the active API base URL, session state, socket state, backend health check, and quick links into the highest-risk product flows.
- `Profile -> Diagnostics` also shows the current user ID and lets you copy it when matching device behavior to backend logs or database records.
- `Profile -> QA progress` shows how far through the current QA pass you are and gives direct access to Diagnostics and the checklist.
- `Diagnostics -> Open QA checklist` opens a persistent on-device checklist that keeps progress between app launches and can be reset for a fresh QA round.
- `Diagnostics -> Open media preview` lets you verify camera/microphone permissions, local preview, and camera switching before testing live rooms or calls.
- Direct chat, anonymous match, and live room status bars now include copy actions for thread, match, and room IDs so multi-device QA can be matched against backend logs more easily.

## QA checklist

### 1. Auth and session

- Launch the app and log in with an existing account.
- Confirm app shell navigation loads without blank screens.
- Sign out and sign back in.
- Open `Profile -> Diagnostics -> Open media preview` and confirm camera/microphone permission prompts and local preview work.
- Run through signup and verify each step advances correctly.
- Start a trial from the upgrade screen and confirm the app session updates immediately.

### 2. Profile and follow

- Open your own profile and confirm avatar, counts, and actions render.
- Open another user's profile.
- Follow and unfollow that user.
- Open followers and following lists.
- Jump from profile into direct chat.

### 3. Meet discovery

- Open Meet and confirm user cards load.
- Apply language filters and confirm results change.
- Apply country, pro-only, and photo-only filters and confirm the local refinements behave as expected.
- Pull to refresh and verify discovery reloads cleanly.

### 4. Direct chat

- Open a thread and confirm message history loads.
- Send text messages both directions across two clients.
- Confirm typing indicators appear.
- Send an image.
- Record and send a voice note, then play it back.
- Pull to refresh inside the thread.
- Disable network temporarily and confirm offline/reconnect messaging is honest.

### 5. Direct calls

- Start a voice call from one client and accept on the other.
- Repeat with video call.
- Confirm incoming call overlay appears even when the receiver is outside the chat screen.
- Confirm mute, camera toggle, and end-call actions work.
- Let one call ring without answering and verify timeout behavior.
- Repeat after navigating in and out of the chat screen to catch state handoff issues.

### 6. Anonymous match

- Open anonymous meet and start searching on two clients.
- Confirm match found state appears and both sides enter the same session.
- Exchange text messages.
- Send image and voice-note messages.
- Toggle follow permission and confirm the state updates.
- Skip or end the match and confirm both clients recover cleanly.
- Retry after briefly disconnecting one client from the network.

### 7. Anonymous calls

- Start an anonymous call request from one side.
- Accept on the other client.
- Confirm call timer and end-state cleanup behave correctly.
- Let a request timeout and verify the screen resets cleanly.
- Repeat after reconnecting from a dropped socket state.

### 8. Live rooms

- Create a live room on one client.
- Confirm the room appears in the room list on another client.
- Join as listener.
- Post comments from both clients.
- Raise hand from listener account.
- Accept or decline from host account.
- Once accepted, confirm the speaker joins the stage.
- Verify mute, camera toggle, and leave-stage behaviors.
- Leave and rejoin the room to confirm resync behavior.

## High-risk areas to watch

- Realtime state drift after app navigation
- Call cleanup after declined, missed, or timed-out requests
- Permission prompts on first use for camera and microphone
- Media playback behavior for uploaded images and voice notes
- Room resync after reconnect in anonymous and live flows
