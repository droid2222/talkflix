# Manual QA checklist

Last updated: 2026-06-10

Use this before release candidates or after large realtime changes. Automated tests do not cover two-device call/live flows.

For store submission specifics, also use [app_store_submission_checklist.md](app_store_submission_checklist.md).

## 1. Auth and session

- Launch the app and log in with an existing account.
- Confirm app shell navigation loads without blank screens.
- Sign out and sign back in.
- In a **debug** build, open Profile → Diagnostics → Open media preview; confirm camera/microphone permission prompts and local preview work.
- Run through signup and verify each step advances correctly.
- Start a trial from the upgrade screen and confirm the app session updates immediately.

## 2. Profile and follow

- Open your own profile and confirm avatar, counts, and actions render.
- Open another user's profile.
- Follow and unfollow that user.
- Open followers and following lists.
- Jump from profile into direct chat.
- Toggle privacy settings (age, flag, location, follow stats) and confirm they persist after relaunch.

## 3. Meet discovery

- Open Meet and confirm user cards load.
- Apply language filters and confirm results change.
- Apply country, pro-only, and photo-only filters and confirm local refinements behave as expected.
- Pull to refresh and verify discovery reloads cleanly.

## 4. Direct chat

- Open a thread and confirm message history loads.
- Send text messages both directions across two clients.
- Confirm typing indicators appear.
- Send an image.
- Record and send a voice note, then play it back.
- Pull to refresh inside the thread.
- Disable network temporarily and confirm offline/reconnect messaging is honest.

## 5. Direct calls

- Start a voice call from one client and accept on the other.
- Repeat with video call.
- Confirm incoming call UI appears when the receiver is outside the chat screen.
- Confirm mute, camera toggle, and end-call actions work.
- Let one call ring without answering and verify timeout behavior.
- Repeat after navigating in and out of the chat screen.

## 6. Anonymous match

- Open anonymous meet and start searching on two clients.
- Confirm match found state appears and both sides enter the same session.
- Exchange text messages; send image and voice-note messages.
- Toggle follow permission and confirm the state updates.
- Skip or end the match and confirm both clients recover cleanly.

## 7. Anonymous calls

- Start an anonymous call request from one side; accept on the other.
- Confirm call timer and end-state cleanup behave correctly.
- Let a request timeout and verify the screen resets cleanly.

## 8. Live rooms

- Create a live room on one client; confirm it appears for another client.
- Join as listener; post comments from both clients.
- Raise hand; host accepts or declines; speaker joins stage when accepted.
- Verify mute, camera toggle, and leave-stage behaviors.
- Leave and rejoin the room to confirm resync behavior.

## High-risk areas

- Realtime state drift after app navigation
- Call cleanup after declined, missed, or timed-out requests
- Permission prompts on first use for camera and microphone
- Media playback for uploaded images and voice notes
- Room resync after reconnect in anonymous and live flows
- Restrictive networks (Wi‑Fi / NAT) for calls and live audio — see [pending-issues.md](pending-issues.md)
