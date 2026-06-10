# Production Backup Retention

Last updated: 2026-06-05

This policy exists to keep Talkflix production rollback files useful without letting old one-off backups accumulate or expose secrets.

## Scope

This policy applies to manually created production backup files in:

```text
/opt/talkflix-api
/var/www/talkflix-admin
/var/www/talkflix-web
```

It does not replace provider-level infrastructure backups such as DigitalOcean snapshots or managed database backups.

## Current Rule

Before removing old production backups:

- Create one fresh protected snapshot of the current production files.
- Keep the latest useful rollback backup for each active production surface.
- Remove old duplicate deployment backups that are older than the current verified deployment state.
- Treat `.env` backups as sensitive. They must not be world-readable and should not be kept unless there is a clear recovery reason.

## Fresh Snapshot Location

Use root-only storage outside the app folders:

```text
/root/talkflix-production-backups/<YYYYMMDD-label>/
```

The snapshot directory must be `700`. Files containing secrets must be `600`.

## Files To Snapshot Before Cleanup

API:

```text
/opt/talkflix-api/server.js
/opt/talkflix-api/socket.js
/opt/talkflix-api/package.json
/opt/talkflix-api/package-lock.json
/opt/talkflix-api/start.sh
/opt/talkflix-api/.env
```

Admin dashboard:

```text
/var/www/talkflix-admin/index.html
/var/www/talkflix-admin/logo.png
/var/www/talkflix-admin/favicon.png
```

Web homepage/static shell:

```text
/var/www/talkflix-web/index.html
```

## Files Safe To Remove After Snapshot

Old backups matching these patterns can be removed after the fresh snapshot exists and the active production files are verified:

```text
*.bak*
*backup*
*.old
*.orig
*~
```

Only remove those files inside the scoped production paths above.

## Files To Keep

Keep:

- The fresh protected snapshot for the current release.
- Any specifically named rollback backup that belongs to the current deployment and has not yet been superseded.
- Provider-level droplet/database backups managed outside this repo.

## Verification After Cleanup

Run:

```bash
curl -sS https://api.talkflix.cc/health
```

Also verify that the expected public surfaces still load:

```text
https://www.talkflix.cc/
https://talkflix.cc/admin/
```

## Documentation Rule

Whenever production backups are created, moved, or deleted, update this file or the release handoff with:

- date
- paths affected
- snapshot location
- cleanup summary
- verification performed

## Cleanup Log

### 2026-06-07 Backend Monthly IAP Product V2 Deployment Backup

Reason:

- Deployed backend default Pro IAP product IDs after changing the monthly subscription from `talkflix_pro_monthly` to `talkflix_pro_monthly_v2`.

Fresh protected backup created:

```text
/root/talkflix-production-backups/20260607-iap-monthly-v2-798c76c/server.js.before
```

Production path affected:

```text
/opt/talkflix-api/server.js
```

Verification performed:

```text
https://api.talkflix.cc/health returned {"ok":true}
/opt/talkflix-api/server.js contained talkflix_pro_monthly_v2 in defaultIapProProductIds
```

### 2026-06-06 Backend Six-Month IAP Product Deployment Backup

Reason:

- Deployed backend default Pro IAP product IDs after changing the middle subscription plan from `talkflix_pro_3_months` to `talkflix_pro_6_months`.

Fresh protected backup created:

```text
/root/talkflix-production-backups/20260606-iap-six-months-048113e/server.js.before
```

Production path affected:

```text
/opt/talkflix-api/server.js
```

Verification performed:

```text
https://api.talkflix.cc/health returned {"ok":true}
/opt/talkflix-api/server.js contained talkflix_pro_6_months in defaultIapProProductIds
```

### 2026-06-05 Web Account Deletion Deployment Backup

Reason:

- Deployed the Flutter web release build containing the public `/account-deletion` route required for Play Console account deletion metadata.

Fresh protected backup created:

```text
/root/talkflix-production-backups/20260605-account-deletion-8e254b2/talkflix-web-before.tar.gz
```

Production path affected:

```text
/var/www/talkflix-web
```

Deployment source:

```text
/Users/talkflix/talkflix_flutter/build/web
```

Verification performed:

```text
https://www.talkflix.cc/ returned HTTP 200
https://www.talkflix.cc/account-deletion returned HTTP 200
https://www.talkflix.cc/main.dart.js contained /account-deletion and "Delete your Talkflix account"
```

### 2026-06-09 Static Homepage Restore Deployment Backup

Reason:

- Restored the launch-critical static web homepage after the production root had been overwritten by a Flutter-only loader.
- Added a guarded web build workflow so future Flutter web releases preserve the static homepage in `build/web/index.html`.
- Deployed the matching commerce API route support because the restored homepage links to the public `/coaching` page.

Fresh protected backup created:

```text
/root/talkflix-production-backups/20260609-homepage-restore/talkflix-web-before.tar.gz
/root/talkflix-production-backups/20260609-homepage-commerce-api/server.js.before
```

Production path affected:

```text
/var/www/talkflix-web
/opt/talkflix-api/server.js
```

Deployment source:

```text
/Users/talkflix/talkflix_flutter/build/web
```

Verification performed:

```text
tool/check_web_homepage.sh: passed
tool/build_web_preserving_homepage.sh --no-wasm-dry-run: passed
https://www.talkflix.cc/ returned HTTP 200 with static home-page markup
https://www.talkflix.cc/coaching returned HTTP 200
https://www.talkflix.cc/account-deletion returned HTTP 200
production index.html contained talkflix-language-social-hero.jpg, talkflix-logo-transparent.png, /coaching, /account-deletion, and flutter_bootstrap.js
node --check /opt/talkflix-api/server.js: passed
pm2 restart talkflix-api: passed
https://api.talkflix.cc/health returned {"ok":true}
https://api.talkflix.cc/commerce/products returned one_on_one_coaching
POST https://api.talkflix.cc/commerce/checkout-sessions returned STRIPE_SECRET_KEY is not configured because production Stripe env vars are not set yet
```

### 2026-06-09 Flutter Homepage Removal Deployment Backup

Reason:

- Removed the obsolete Flutter `PublicHomeScreen` so it cannot appear after in-app navigation from `/coaching` or other public Flutter routes.
- Updated web public-home navigation to force a full browser load of `/`, preserving the static homepage as the only public homepage.

Fresh protected backup created:

```text
/root/talkflix-production-backups/20260609-remove-flutter-home/talkflix-web-before.tar.gz
```

Production path affected:

```text
/var/www/talkflix-web
```

Deployment source:

```text
/Users/talkflix/talkflix_flutter/build/web
```

Verification performed:

```text
dart analyze edited Dart files: passed
tool/build_web_preserving_homepage.sh --no-wasm-dry-run: passed
production main.dart.js did not contain PublicHomeScreen or old Flutter homepage text
production /coaching still contained Private 1-on-1 Coaching and one_on_one_coaching
browser test: https://www.talkflix.cc/coaching -> Home landed on https://www.talkflix.cc/ with static home-page visible and no Flutter view active
```

### 2026-06-09 Admin Stripe Config Deployment Backup

Reason:

- Added a Settings page "Stripe Checkout" card to the standalone admin dashboard.
- Added protected backend routes for masked Stripe config status and superadmin-only saving/clearing.
- Checkout now reads `STRIPE_SECRET_KEY` from the server environment first, then from encrypted dashboard storage in `app_settings`.
- Stripe webhook verification now reads `STRIPE_WEBHOOK_SECRET` from the server environment first, then from encrypted dashboard storage in `app_settings`.
- Added a dedicated `SECRET_ENCRYPTION_KEY` to the production API environment so dashboard-saved secrets are not tied to `JWT_SECRET` rotation.

Fresh protected backups created:

```text
/root/talkflix-production-backups/20260609-admin-stripe-config/server.js.before
/root/talkflix-production-backups/20260609-admin-stripe-config/admin-index.html.before
/root/talkflix-production-backups/20260609-admin-stripe-config/env.before-secret-encryption-key
```

Production paths affected:

```text
/opt/talkflix-api/server.js
/opt/talkflix-api/.env
/var/www/talkflix-admin/index.html
```

Verification performed:

```text
node --check /Users/genius/talkflixproject/talkflix-api/server.js: passed
admin dashboard inline script syntax check: passed
node --check /opt/talkflix-api/server.js: passed
pm2 restart talkflix-api: passed
SECRET_ENCRYPTION_KEY added without printing the generated value
pm2 restart talkflix-api --update-env: passed
server-local /health returned {"ok":true}
server-local /admin/commerce/stripe-config returned 401 without auth, confirming the route is registered and protected
server-local /commerce/checkout-sessions still returned STRIPE_SECRET_KEY is not configured until a Stripe key is saved
production admin index.html contained Stripe Checkout, stripe-config, and stripeSecretKeyInput
```

### 2026-06-09 Commerce Products And Share Links Deployment Backup

Reason:

- Added persistent `commerce_products` catalog support to the backend.
- Added public product links at `/coaching/<product-slug>`.
- Added protected admin product routes for create, edit, list, and archive.
- Added a standalone admin dashboard "Coaching" page with copy-share-link actions.
- Updated the Flutter web coaching screen so a specific share link loads the matching product and checkout CTA.

Fresh protected backups created:

```text
/root/talkflix-production-backups/20260609-commerce-products/server.js.before
/root/talkflix-production-backups/20260609-commerce-products/admin-index.html.before
/root/talkflix-production-backups/20260609-commerce-products/talkflix-web-before.tar.gz
```

Production paths affected:

```text
/opt/talkflix-api/server.js
/var/www/talkflix-admin/index.html
/var/www/talkflix-web
```

Verification performed:

```text
dart analyze edited Dart files: passed
node --check /Users/genius/talkflixproject/talkflix-api/server.js: passed
admin dashboard inline script syntax check: passed
tool/build_web_preserving_homepage.sh --no-wasm-dry-run: passed
node --check /opt/talkflix-api/server.js: passed
pm2 restart talkflix-api --update-env: passed
server-local /health returned {"ok":true}
server-local /commerce/products returned one_on_one_coaching with shareUrl https://www.talkflix.cc/coaching/one-on-one-coaching
server-local /commerce/products/one-on-one-coaching returned the matching public product
server-local /admin/commerce/products returned 401 without auth, confirming the route is registered and protected
server-local /commerce/checkout-sessions returned a Stripe Checkout URL
production admin index.html contained Coaching & Products, /admin/commerce/products, and copyCommerceShareLink
browser test: https://www.talkflix.cc/coaching/one-on-one-coaching rendered the 1-on-1 Coaching product and Book with Stripe CTA
```

### 2026-06-10 Admin Dashboard Cache Headers Backup

Reason:

- Production admin dashboard HTML already contained the Coaching section, but browser sessions could still show an older cached dashboard because `/admin/` did not send cache-control headers.
- Added no-cache headers to the canonical admin Nginx route so admin dashboard edits appear immediately after deployment.

Fresh protected backups created:

```text
/root/talkflix-production-backups/20260610-admin-cache-headers/talkflix-web.before
/root/talkflix-production-backups/20260610-admin-cache-headers/talkflix-web-enabled.before
```

Production paths affected:

```text
/etc/nginx/sites-available/talkflix-web
/etc/nginx/sites-enabled/talkflix-web
```

Verification performed:

```text
nginx -t: passed
systemctl reload nginx: passed
curl -sSI https://talkflix.cc/admin/ returned Cache-Control: no-cache, no-store, must-revalidate
curl -sS https://talkflix.cc/admin/ included data-page="commerce", Coaching & Products, and copyCommerceShareLink
```

### 2026-06-10 Commerce Cover Images And Catalog Deployment Backup

Reason:

- Added `image_url` support to `commerce_products`.
- Added public `imageUrl` fields to commerce product API responses.
- Added an admin commerce image upload endpoint and cover image fields in the Coaching product editor.
- Updated `/coaching` to show the active product catalog instead of only the original default product.
- Preserved `/coaching/<product-slug>` as a focused direct purchase page for one product/service.

Fresh protected backups created:

```text
/root/talkflix-production-backups/20260610-commerce-cover-catalog/server.js.before
/root/talkflix-production-backups/20260610-commerce-cover-catalog/admin-index.html.before
/root/talkflix-production-backups/20260610-commerce-cover-catalog/talkflix-web-before.tar.gz
```

Production paths affected:

```text
/opt/talkflix-api/server.js
/var/www/talkflix-admin/index.html
/var/www/talkflix-web
```

Verification performed:

```text
dart analyze edited commerce Dart files: passed
node --check /Users/genius/talkflixproject/talkflix-api/server.js: passed
admin dashboard inline script syntax check: passed
tool/build_web_preserving_homepage.sh --no-wasm-dry-run: passed
node --check /opt/talkflix-api/server.js: passed
pm2 restart talkflix-api --update-env: passed
GET https://api.talkflix.cc/health returned {"ok":true}
GET https://api.talkflix.cc/commerce/products returned Advanced American English and 1-on-1 Coaching with imageUrl fields
POST https://api.talkflix.cc/admin/commerce/upload-image returned 401 without auth, confirming the route is protected
production admin index.html contained Cover, commerceProductImageUrl, /admin/commerce/upload-image, and imageUrl
browser test: https://www.talkflix.cc/coaching showed Advanced American English in the hero and both active products in the catalog
browser test: https://www.talkflix.cc/coaching/advanced-american-english rendered the new service direct purchase page with no console errors
```

### 2026-06-05 Backup Folder Cleanup

Reason:

- Production app folders contained many one-off deployment backup files that made it harder to identify the current rollback point.
- `/opt/talkflix-api/.env.bak-` existed with broader permissions than the active `.env`.

Fresh protected snapshot created:

```text
/root/talkflix-production-backups/20260605-pre-backup-cleanup/
```

Snapshot contents:

```text
/opt/talkflix-api/server.js
/opt/talkflix-api/socket.js
/opt/talkflix-api/package.json
/opt/talkflix-api/package-lock.json
/opt/talkflix-api/start.sh
/opt/talkflix-api/.env
/var/www/talkflix-admin/index.html
/var/www/talkflix-admin/logo.png
/var/www/talkflix-admin/favicon.png
/var/www/talkflix-web/index.html
```

Old backup archive:

```text
/root/talkflix-production-backups/20260605-old-live-folder-backups-archive/
```

Cleanup result:

- Scanned 66 backup-looking files in `/opt/talkflix-api`, `/var/www/talkflix-admin`, and `/var/www/talkflix-web`.
- Moved 62 old backup files into the root-only archive above.
- Kept 4 newest live rollback files in place:

```text
/opt/talkflix-api/server.js.backup-20260605-iap-pro
/opt/talkflix-api/socket.js.backup-20260604-direct-cancel-fix
/var/www/talkflix-admin/index.html.backup-20260604-anon-history-reset
/var/www/talkflix-web/index.html.backup-20260603-094719-boot-only
```

Sensitive backup handling:

- Moved `/opt/talkflix-api/.env.bak-` into the root-only archive.
- Set the archived `.env.bak-` file to `600`.
- Set `/root/talkflix-production-backups` and both cleanup directories to `700`.

Verification performed:

```text
https://api.talkflix.cc/health returned {"ok":true}
https://www.talkflix.cc/ returned HTTP 200
https://talkflix.cc/admin/ returned HTTP 200
```
