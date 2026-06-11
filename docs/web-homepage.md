# Talkflix Web Homepage

Last verified: 2026-06-09

This note exists so future web or Flutter changes do not accidentally replace the public homepage.

Production restore note: the static homepage was redeployed on 2026-06-09 from the guarded `build/web` output. The production backup is documented in `docs/production-backup-retention.md`.

## Public Route

The main public homepage is:

```text
https://www.talkflix.cc/
https://talkflix.cc/
```

The source of truth for the public `/` homepage is the static HTML shell:

```text
web/index.html
```

This is intentional. The public root must show the branded marketing homepage before the Flutter app starts. It is not the same as the authenticated Flutter web app shell.

The Flutter router still contains a `/` route in:

```text
lib/app/router/app_router.dart
```

That route is only a safety redirect. It must not render a Flutter homepage. If Flutter ever handles `/` internally, it should force a full browser navigation back to the static root or fall back to login.

Flutter public pages that need a Home action must use:

```text
lib/core/navigation/public_home_navigation.dart
```

Do not use `context.go('/')` for public web Home actions.

`web/index.html` owns the browser root route. For non-root routes, the static shell loads Flutter dynamically with:

```text
flutter_bootstrap.js
```

Examples of routes that must continue loading the Flutter app:

```text
/login
/signup
/app/*
/coaching
/coaching/<product-slug>
/terms-of-service
/privacy-policy
/support
/account-deletion
/s/:token
/w/:token
```

Do not replace `web/index.html` with a Flutter-only loader, and do not reintroduce a Flutter `PublicHomeScreen`. Those are the failure modes that make the wrong homepage visible.

## Required Homepage Elements

The homepage must preserve these user-visible elements:

- Static `<main class="home-page">` markup for `/`.
- Background image from `web/images/talkflix-language-social-hero.jpg`.
- Transparent-background logo from `web/images/talkflix-logo-transparent.png`.
- Login and signup calls to action.
- Public explanation of language practice, tutors, paid partners, coaching, and the web app.
- Coaching call to action linking to `/coaching`.
- Footer links to Terms of Service, Privacy Policy, and Account Deletion.

Legal routes used by the footer:

```text
/terms-of-service
/privacy-policy
/support
/account-deletion
```

The support and account deletion routes are public store-review support pages. They must remain accessible without signing in.

The public coaching route is web-only and public:

```text
/coaching
/coaching/<product-slug>
```

It is documented in:

```text
docs/web-commerce.md
```

## Required Assets

These static web assets are part of the homepage contract:

```text
web/images/talkflix-language-social-hero.jpg
web/images/talkflix-logo-transparent.png
```

Do not remove, rename, compress beyond recognition, or replace these assets without verifying the first-load experience on desktop and mobile web.

## Build Guard

Run the homepage guard before shipping web changes:

```bash
tool/check_web_homepage.sh
```

For Flutter web releases, use the guarded build command instead of raw `flutter build web`:

```bash
tool/build_web_preserving_homepage.sh
```

The guarded build checks `web/index.html`, runs the Flutter build, preserves the generated Flutter shell as `build/web/app-index.html` and `build/web/share-index.html`, copies the static homepage into `build/web/index.html`, and checks the built output again.

## Safe Change Checklist

Before changing web routing, homepage UI, share-link handling, authentication redirects, or deployment scripts:

- Confirm `/` shows the static branded homepage with the hero background and transparent logo.
- Confirm `/login`, `/signup`, `/app/*`, `/coaching`, legal routes, and share links still load Flutter correctly.
- Confirm logged-in web users can still enter the app from the homepage login/open-app actions.
- Confirm footer links to `/terms-of-service`, `/privacy-policy`, `/support`, and `/account-deletion` work.
- Run `tool/check_web_homepage.sh`.
- Run `tool/build_web_preserving_homepage.sh`.
- If possible, open the built web app locally or on staging and verify desktop layout, mobile layout, and first-load logo.

## Handoff Rule

Treat the public homepage as launch-critical. If a future update replaces the homepage with the app shell, login page, blank screen, or a temporary placeholder, stop the release and restore `web/index.html` before deploying.
