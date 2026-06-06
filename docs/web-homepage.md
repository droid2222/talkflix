# Talkflix Web Homepage

Last verified: 2026-06-05

This note exists so future web or Flutter changes do not accidentally replace the public homepage.

## Public Route

The main public homepage is:

```text
https://www.talkflix.cc/
https://talkflix.cc/
```

In the Flutter web router, `/` must stay public and must render:

```text
lib/features/home/presentation/public_home_screen.dart
```

Router source:

```text
lib/app/router/app_router.dart
```

The route is registered as:

```dart
GoRoute(path: '/', builder: (context, state) => const PublicHomeScreen())
```

Do not redirect unauthenticated web users from `/` directly into `/login` or `/app/*`. The homepage is the public marketing entry point.

## Required Homepage Elements

The homepage must preserve these user-visible elements:

- Hero section with Talkflix branding.
- Background image from `assets/images/live_room_bg.png`.
- Talkflix logo from `assets/images/talkflix_logo.png`.
- Login and signup calls to action.
- Public explanation of language practice, tutors, paid partners, coaching, and the web app.
- Footer links to Terms of Service, Privacy Policy, and Account Deletion.

Legal routes used by the footer:

```text
/terms-of-service
/privacy-policy
/account-deletion
```

The account deletion route is a public store-review support page. It must remain accessible without signing in.

## Required Web Loader

The first web loading screen in `web/index.html` uses the transparent-background logo:

```text
web/images/talkflix-logo-transparent.png
```

Do not remove or replace this loader asset without verifying the first-load experience on desktop and mobile web.

## Asset Registration

The homepage Flutter assets must remain registered in:

```text
pubspec.yaml
```

Current required entries:

```yaml
assets:
  - assets/images/talkflix_logo.png
  - assets/images/live_room_bg.png
```

## Safe Change Checklist

Before changing web routing, homepage UI, share-link handling, or authentication redirects:

- Confirm `/` still renders `PublicHomeScreen` for unauthenticated web users.
- Confirm logged-in web users can still enter the app after choosing a login/signup action.
- Confirm `/terms-of-service`, `/privacy-policy`, and `/account-deletion` still work from the homepage footer.
- Confirm shared links such as `/s/:token`, `/w/:token`, and `/app/live?broadcastId=...` still keep their intended behavior.
- Run `flutter build web --release`.
- If possible, open the built web app locally or on staging and verify desktop layout, mobile layout, and first-load logo.

## Handoff Rule

Treat the public homepage as launch-critical. If a future update replaces the homepage with the app shell, login page, blank screen, or a temporary placeholder, revert that part before release.
