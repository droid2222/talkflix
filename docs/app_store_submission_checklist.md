# Talkflix App Store Submission Checklist

This checklist reflects the v1 release branch as of 2026-06-05.

Before using this checklist, read the implementation handoff in [`docs/v1-release-handoff.md`](/Users/talkflix/talkflix_flutter/docs/v1-release-handoff.md). That document explains the current feature gates, IAP product IDs, direct-call behavior, diagnostics policy, iOS launch-screen fix, homepage preservation rule, and production setup dependencies.

The public web homepage preservation details are in [`docs/web-homepage.md`](/Users/talkflix/talkflix_flutter/docs/web-homepage.md). Verify the homepage, Terms of Service link, Privacy Policy link, and Account Deletion link before submission.

## V1 Release Scope

Ship only the stable reviewable surface:

- Authentication, onboarding, profile, privacy, block/report, and account deletion.
- Content feed, shared content links, creator posting flows that are ready for QA.
- Direct text chat, media messages, voice notes, call logs, and direct voice/video calls.
- Live room browse/create/join flows that pass real-device QA.
- Meet/discovery flows and Pro-gated discovery behavior.
- Talkflix Pro mobile subscriptions through native App Store / Google Play IAP.

Deferred from v1:

- Device contacts invite/save flows.

## Submission Assets

- Set the final App Store version and build number you want to ship.
- Upload the final signed iOS archive from Xcode or Transporter.
- Add the support contact `info@talkflix.cc`.
- Add the privacy policy URL and marketing/support URLs in App Store Connect.
- Add the account deletion URL in Play Console: `https://www.talkflix.cc/account-deletion`.
- Upload the final App Store screenshots.
- Complete the App Privacy questionnaire.
- Complete the age rating questionnaire.
- Confirm paid digital features are either free/trial-only or implemented through native IAP before submission.
- Create matching subscription products in App Store Connect and Play Console: `talkflix_pro_monthly_v2`, `talkflix_pro_6_months`, and `talkflix_pro_yearly`, unless overridden with `IAP_PRO_PRODUCT_IDS`.

## Reviewer Access

- Provide two working test accounts.
- Make sure both accounts can log in on real iPhones.
- Make sure both accounts can open a direct chat with each other.
- Direct calling in the current app requires two authenticated users.
- Provide one reviewer account that can test free/trial Pro behavior and one account that can complete sandbox IAP restore/purchase checks if requested.

## High-Priority Device QA

- Sign up flow
- Login flow
- Forgot password / reset password
- Direct text chat
- Direct media messages and voice notes
- Direct voice call
- Direct video call
- Incoming call accept / decline
- Caller cancel while ringing
- Background / locked-screen incoming call on iPhone
- Combined call logs
- Pro subscription purchase
- Restore purchases
- Push notifications
- Live broadcast create
- Live broadcast join
- Live broadcast leave
- Shared content links
- Shared live broadcast links
- Profile edit
- Privacy settings
- Help email launch

## iOS Permission QA

Verify these prompts and descriptions on a real device:

- Camera
- Microphone
- Photo library
- Notifications
- VoIP / incoming-call behavior

Contacts permission should not appear in v1 review builds.

## App Review Notes Template

Paste and customize this in App Store Connect:

> Talkflix is a social communication app with content sharing, direct chat, direct voice/video calling, language discovery, and live rooms.
>
> Important iOS review note: direct calls use PushKit and CallKit for incoming call presentation.
>
> Talkflix Pro subscriptions use native App Store in-app purchases. Prices and renewal terms are shown by the App Store before confirmation.
>
> To test direct chat and calls, please sign in on two test accounts on two iPhones:
>
> 1. Open **Chats**.
> 2. Open the direct conversation between the two accounts.
> 3. Send text, media, and voice-note messages.
> 4. On the caller device, tap the phone icon for a voice call or the video icon for a video call in the top-right area of the direct chat screen.
> 5. On the receiver device, accept or decline the incoming call from the in-app / CallKit incoming call surface.
>
> To test background incoming calls, place the receiving app in the background or lock the device before placing the call.
>
> If prompted, please allow microphone, camera, photo library, and notification permissions so media, voice notes, direct calls, and live rooms can be reviewed correctly.
>
> To test Pro, open **Profile → Talkflix Pro** or any Pro-gated feature, choose a Pro plan, and complete the sandbox purchase / restore purchases flow.
>
> Support contact: info@talkflix.cc

## Final Release Gate

Do not submit until all of these are true:

- App Store Connect and Play Console subscription products match the app/backend product IDs.
- Play Console account deletion URL points to `https://www.talkflix.cc/account-deletion` and the page is reachable without signing in.
- Production API has Apple and Google purchase verification credentials configured.
- Pro purchase and restore purchase pass sandbox QA on real devices.
- The signed release archive installs cleanly on a real iPhone.
- The signed Android app bundle installs through an internal Play track or equivalent real-device test path.
- Final App Store and Play Store screenshots are uploaded.
- Final build numbers and version numbers are set.
- App Review notes and test credentials are prepared.
- No reviewer-facing placeholder flows remain in the shipping UI.

Resolved or accepted for v1 as of 2026-06-05:

- Direct voice and video call QA was user-reported as passing.
- Combined call logs are part of the main chat screen flow.
- Contacts feature is disabled by default for v1 review builds.
- Android contacts permissions are explicitly removed from the merged manifest.
- Android packaged release manifest was checked after `flutter build appbundle --release`; no contacts permissions were present.
- iOS scene lifecycle support is configured through `UIApplicationSceneManifest` and `SceneDelegate.swift`.
- iOS release build passed with `flutter build ios --release --no-codesign`.
- Diagnostics and QA screens are debug-only through `AppConfig.localQaToolsEnabled`.
- TURN/TLS is accepted as a v1 call-reliability risk because real-device direct-call QA passed. Revisit immediately after launch if calls fail on restrictive networks.
