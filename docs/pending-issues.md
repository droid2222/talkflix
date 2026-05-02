# Pending Issues

Last updated: 2026-05-01

This file is the client/app-side source of truth for open issues that still need coordinated work.

How to use it:

- Update this file in every PR that changes the status, root-cause understanding, or proposed solution for one of these items.
- Prefer concrete dates, exact symptoms, and links to the relevant GitHub issue/PR once those exist.
- If an item also needs backend or infrastructure work, note that explicitly instead of assuming ownership.

## 1. Voice room stage unmute fails on iPhone

- Severity: P1
- Status: Open
- Repos: `talkflix`, `talkflix-api`
- Current behavior:
  - In current iPhone testing, a listener can join stage muted, but the first unmute can fail and local audio does not start.
  - The observed native log is `AUIOClient_StartIO failed (-66637)`.
- What is already true:
  - Audio rooms now use the LiveKit SFU path by default.
  - Stage approval is ack-driven.
  - Users join stage muted by default for privacy.
  - Host remove-from-stage is backend-authoritative.
- Current understanding:
  - The failure now occurs on the first local microphone start when the app enables the mic on unmute.
  - The earlier “auto-start mic on stage join” path is no longer the active failure point.
- Proposed next step:
  - Reproduce on a physical iPhone while collecting Xcode device logs plus client-side room/publish state.
  - Confirm whether the remaining failure is permission-related, `AVAudioSession`-related, or LiveKit publish startup.
  - Do not mark this fixed until a real two-device stage flow passes end to end.
- GitHub issue: TBD

## 2. Live audio restrictive-network reliability is not production-complete

- Severity: P1
- Status: Open
- Repos: `talkflix`, `talkflix-api`
- Current behavior:
  - The app uses LiveKit SFU for audio rooms.
  - The deployed stack currently works for the basic path, but TURN/TLS fallback is not yet configured.
- Current understanding:
  - This leaves a real risk for users on restrictive Wi-Fi, symmetric NAT, or networks where direct UDP paths fail.
  - Stage/moderation logic can be correct while media still fails to flow on those networks.
- Proposed solution:
  - Add TURN/TLS fallback on the backend/infrastructure side.
  - Keep the app-side validation matrix explicit: LTE to Wi-Fi, Wi-Fi to LTE, and two restrictive-network cases.
- GitHub issue: TBD

## 3. Direct 1:1 call reliability is still best-effort

- Severity: P2
- Status: Open
- Repos: `talkflix`, `talkflix-api`
- Current behavior:
  - Direct audio/video calls still use the existing P2P WebRTC path.
  - Default RTC config falls back to STUN-only unless TURN is provided via environment overrides.
- Current understanding:
  - This is acceptable for development and some production networks, but not reliable enough to treat as fully solved.
- Proposed solution:
  - Add TURN configuration for the direct-call path.
  - If product expectations become stricter, evaluate whether direct calls should stay P2P or move to a relayed media design.
- GitHub issue: TBD

## 4. Direct-message media and history do not scale yet

- Severity: P2
- Status: Open
- Repos: `talkflix`, `talkflix-api`
- Current behavior:
  - DM media is still handled as inline/base64 payloads.
  - Full thread fetches still happen without real pagination.
- Current understanding:
  - This is workable for small conversations, but it is the wrong storage and retrieval model for larger chats.
- Proposed solution:
  - Move media to object storage and persist references instead of inline blobs.
  - Add paginated message history APIs and client-side pagination.
- GitHub issue: TBD

## 5. iOS distribution is still pending

- Severity: P2
- Status: Open
- Repos: `talkflix`
- Current behavior:
  - The app can be run from Xcode and built locally.
  - App Store Connect / TestFlight signing and distribution are not yet completed in this repo workflow.
- Current understanding:
  - Backend hosting on the droplet does not remove the need for proper iOS signing and distribution.
- Proposed solution:
  - Complete Apple signing/provisioning, archive flow, and TestFlight distribution.
  - Document the release steps once the first successful TestFlight upload is complete.
- GitHub issue: TBD
