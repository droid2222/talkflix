# Pending issues

Last updated: 2026-06-10

Open product and engineering risks for the Talkflix client and its API. For launch scope, blockers, and resolved items, see [v1-release-handoff.md](v1-release-handoff.md).

**How to use this file**

- Update an item when status, root cause, or owner changes.
- Add the date and a one-line summary in the item when you close or downgrade it.
- Link GitHub issues/PRs when they exist.

## 1. Voice room stage unmute fails on iPhone

- Severity: P1
- Status: Open
- Repos: `talkflix_flutter`, `talkflix-api`
- Current behavior:
  - Listener can join stage muted, but the first unmute can fail; local audio does not start.
  - Observed native log: `AUIOClient_StartIO failed (-66637)`.
- Context:
  - Audio rooms use LiveKit SFU by default (`AppConfig.liveUseSfuAudio`).
  - Stage approval is ack-driven; users join stage muted by default.
- Proposed next step:
  - Reproduce on a physical iPhone with Xcode device logs and LiveKit publish state.
  - Confirm permission vs `AVAudioSession` vs LiveKit publish startup.
- GitHub issue: TBD

## 2. Live audio on restrictive networks

- Severity: P1
- Status: Open (accepted launch risk per handoff 2026-06-05 — revisit if users report failures)
- Repos: `talkflix_flutter`, `talkflix-api`, infrastructure
- Current behavior:
  - LiveKit SFU works on the common path; TURN/TLS fallback is not fully configured.
- Risk:
  - Restrictive Wi‑Fi, symmetric NAT, or UDP-blocking networks may fail media while signaling still works.
- Proposed solution:
  - Add TURN/TLS on infrastructure; validate LTE↔Wi‑Fi and two restrictive-network cases.
- GitHub issue: TBD

## 3. Direct 1:1 call reliability (P2P)

- Severity: P2
- Status: Open
- Repos: `talkflix_flutter`, `talkflix-api`
- Current behavior:
  - Direct calls use P2P WebRTC; default ICE is STUN-only unless `RTC_TURN_*` dart-defines are set.
- Proposed solution:
  - Production TURN for direct calls, or move to relayed media if product requirements tighten.
- GitHub issue: TBD

## 4. Direct-message media and history scale

- Severity: P2
- Status: Open
- Repos: `talkflix-api` (primary), `talkflix_flutter`
- Current behavior:
  - DM media can be inline/base64; thread history is not paginated end-to-end.
- Proposed solution:
  - Object storage for media; paginated history APIs and client paging.
- GitHub issue: TBD

## 5. iOS App Store distribution workflow

- Severity: P2
- Status: In progress
- Repo: `talkflix_flutter`
- Current behavior:
  - `flutter build ios` and `flutter build ipa` succeed locally with team `VPZ2LX24TZ`.
  - App Store Connect / TestFlight upload and reviewer account packaging are tracked in [app_store_submission_checklist.md](app_store_submission_checklist.md).
- Proposed solution:
  - Complete first TestFlight upload; document exact Xcode/Transporter steps in handoff once done.
- GitHub issue: TBD
