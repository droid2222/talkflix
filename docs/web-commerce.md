# Talkflix Web Commerce

Last updated: 2026-06-09

This note documents the web-only commerce flow so future mobile, web, or backend work does not mix coaching/product sales with Talkflix Pro in-app purchases.

## Scope

Web commerce is for coach-owned offers such as:

- Private 1-on-1 coaching.
- Ebooks.
- Podcast subscriptions.
- Future digital products or services.

The first implemented product is:

```text
one_on_one_coaching
```

Current public page:

```text
/coaching
```

The public static homepage links to this page from `web/index.html`. Keep that link in place when editing the homepage.

Flutter page source:

```text
lib/features/commerce/presentation/coaching_screen.dart
```

Flutter data source:

```text
lib/features/commerce/data/commerce_repository.dart
```

Router source:

```text
lib/app/router/app_router.dart
```

Static homepage entry point:

```text
web/index.html
```

## Payment Model

This first version assumes Talkflix/David is the only seller. It uses a normal Stripe account, not Stripe Connect.

Do not add Stripe Connect unless Talkflix intentionally becomes a marketplace where other coaches receive their own payouts.

## Separation From Pro

Web commerce is separate from Talkflix Pro.

- Talkflix Pro is a mobile/web app access subscription backed by App Store / Play Store IAP product IDs.
- Coaching and digital products are web-only Stripe purchases.
- A coaching purchase must not unlock Pro unless a future admin-defined promotion explicitly grants that benefit.

## Backend API

Backend source:

```text
/Users/genius/talkflixproject/talkflix-api/server.js
```

Public endpoints:

```text
GET  /commerce/products
POST /commerce/checkout-sessions
POST /stripe/webhook
```

`GET /commerce/products` returns active public products.

`POST /commerce/checkout-sessions` creates a Stripe Checkout Session and records a pending local order.

`POST /stripe/webhook` verifies the Stripe webhook signature when `STRIPE_WEBHOOK_SECRET` is configured, then marks the matching order paid, expired, or failed.

## Database

The backend creates this table at startup through `ensureTables`:

```text
commerce_orders
```

Important behavior:

- Orders start as `pending`.
- Orders become `paid` only after Stripe webhook confirmation.
- Stripe card data is never stored by Talkflix.

## Required Production Env Vars

Set these on the API process before taking real payments:

```env
STRIPE_SECRET_KEY=sk_live_xxx
STRIPE_WEBHOOK_SECRET=whsec_xxx
PUBLIC_WEB_BASE_URL=https://www.talkflix.cc
COACHING_PRODUCT_ACTIVE=true
COACHING_PRICE_CENTS=2800
COACHING_CURRENCY=usd
COACHING_PRODUCT_TITLE=1-on-1 Coaching
COACHING_PRODUCT_SUBTITLE=Personal clarity, strategy, and next-step guidance.
COACHING_PRODUCT_DESCRIPTION=A focused private coaching session with David Nwako.
```

Restart the API after changing these values.

## Production Status

Status on 2026-06-09:

- Web `/coaching` route is deployed in the production Flutter bundle.
- `GET https://api.talkflix.cc/commerce/products` returns `one_on_one_coaching`.
- `POST https://api.talkflix.cc/commerce/checkout-sessions` reaches the API but returns `STRIPE_SECRET_KEY is not configured` until the key is saved in the admin dashboard or provided as a server environment variable.
- Admin dashboard Settings includes a "Stripe Checkout" card for saving the Stripe secret key and webhook secret.
- Production backend backup before deploying the commerce routes: `/root/talkflix-production-backups/20260609-homepage-commerce-api/server.js.before`.

Do not send `/coaching` to a paying client until the Stripe secret key and webhook secret are configured through the admin dashboard or as production env vars. PM2 restart is only required for env var changes, not for dashboard-saved secrets.

Dashboard-saved Stripe secrets are encrypted in `app_settings`, masked on read, and never returned to the browser after saving.

For long-term production safety, set a stable `SECRET_ENCRYPTION_KEY` on the API server. The backend can fall back to `JWT_SECRET`, but rotating `JWT_SECRET` after saving dashboard secrets would make those saved secrets unreadable unless `SECRET_ENCRYPTION_KEY` is configured.

## Launch Checklist

Before sending `/coaching` to a paying client:

- Configure `STRIPE_SECRET_KEY`.
- Configure `STRIPE_WEBHOOK_SECRET`.
- Add the production webhook endpoint in Stripe Dashboard:

```text
https://api.talkflix.cc/stripe/webhook
```

- Enable at least `checkout.session.completed`, `checkout.session.expired`, and `checkout.session.async_payment_failed`.
- Confirm `GET https://api.talkflix.cc/commerce/products` returns `one_on_one_coaching`.
- Confirm `POST https://api.talkflix.cc/commerce/checkout-sessions` returns a Stripe Checkout URL.
- Confirm successful test payment marks the order as `paid` in `commerce_orders`.

## Future Expansion

If ebooks or podcast subscriptions are added:

- Add product definitions on the backend first.
- Keep product visibility controlled server-side.
- Use Stripe webhooks as the source of truth for access.
- Add admin dashboard controls before allowing non-technical price/content changes.

If other coaches are allowed to sell:

- Revisit this design and migrate to Stripe Connect.
- Add coach approval, product review, payout settings, refund handling, tax/compliance review, and admin moderation before public launch.
