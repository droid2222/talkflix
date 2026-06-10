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

Specific product/service share links:

```text
/coaching/<product-slug>
```

Example:

```text
https://www.talkflix.cc/coaching/one-on-one-coaching
```

Each product has one stable `slug` and `shareUrl`. Use the admin dashboard "Coaching" page to create/edit/archive products and copy the share link. Do not hand-build links from product titles in client code.

The generic `/coaching` page shows the active product catalog. A direct `/coaching/<product-slug>` link shows only the selected product/service.

Products can include a cover image through `imageUrl`. Admins can upload a cover image from the Coaching product editor or paste an HTTPS image URL. Uploaded covers are stored under `/uploads/...` on the API server and rendered publicly through the app media URL resolver.

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
GET  /commerce/products/:slug
POST /commerce/checkout-sessions
POST /stripe/webhook
```

`GET /commerce/products` returns active public products.

`GET /commerce/products/:slug` returns one active public product for a share link.

Public product responses include `imageUrl` when a cover image has been configured.

`POST /commerce/checkout-sessions` creates a Stripe Checkout Session and records a pending local order.

`POST /stripe/webhook` verifies the Stripe webhook signature when `STRIPE_WEBHOOK_SECRET` is configured, then marks the matching order paid, expired, or failed.

## Database

The backend creates this table at startup through `ensureTables`:

```text
commerce_products
commerce_orders
```

Important behavior:

- Products have unique `product_key` and `slug` values.
- Products can be `draft`, `active`, or `archived`; only active products are public.
- Orders start as `pending`.
- Orders become `paid` only after Stripe webhook confirmation.
- Stripe card data is never stored by Talkflix.

## Required Production Env Vars

Set these on the API process before taking real payments:

```env
STRIPE_SECRET_KEY=sk_live_xxx
STRIPE_WEBHOOK_SECRET=whsec_xxx
PUBLIC_WEB_BASE_URL=https://www.talkflix.cc
```

Restart the API after changing server environment values. Product titles, prices, status, and share links are now managed through the admin dashboard and do not require PM2 restart.

## Production Status

Status on 2026-06-09:

- Web `/coaching` route is deployed in the production Flutter bundle.
- Web `/coaching/one-on-one-coaching` route is deployed for direct product purchase links.
- `GET https://api.talkflix.cc/commerce/products` returns `one_on_one_coaching` with `shareUrl`.
- `GET https://api.talkflix.cc/commerce/products/one-on-one-coaching` returns the public product used by the share link.
- `POST https://api.talkflix.cc/commerce/checkout-sessions` returns a Stripe Checkout URL after the Stripe secret key is configured.
- Admin dashboard Settings includes a "Stripe Checkout" card for saving the Stripe secret key and webhook secret.
- Admin dashboard includes a "Coaching" page for product CRUD, archive, and copy-share-link actions.
- Production backend backup before deploying the commerce routes: `/root/talkflix-production-backups/20260609-homepage-commerce-api/server.js.before`.
- Production backup before deploying product management and share links: `/root/talkflix-production-backups/20260609-commerce-products/`.

Use direct product links such as `/coaching/one-on-one-coaching` for specific services. Use `/coaching` as the general coaching catalog entry point.

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
- Confirm `GET https://api.talkflix.cc/commerce/products/one-on-one-coaching` returns the specific product.
- Confirm `POST https://api.talkflix.cc/commerce/checkout-sessions` returns a Stripe Checkout URL.
- Confirm successful test payment marks the order as `paid` in `commerce_orders`.

## Future Expansion

If ebooks or podcast subscriptions are added:

- Add products through the admin dashboard first.
- Keep product visibility controlled server-side.
- Use Stripe webhooks as the source of truth for access.
- Reuse the existing `/coaching/<slug>` share-link pattern unless a future route family is intentionally introduced.

If other coaches are allowed to sell:

- Revisit this design and migrate to Stripe Connect.
- Add coach approval, product review, payout settings, refund handling, tax/compliance review, and admin moderation before public launch.
