# Admin Dashboard

Last verified: 2026-06-07

This note exists so developers do not have to rediscover where the standalone admin dashboard lives.

Backup retention and production cleanup policy:

```text
docs/production-backup-retention.md
```

## Public URL

- Primary URL: `https://talkflix.cc/admin/`
- `https://www.talkflix.cc/admin/` redirects to `https://talkflix.cc/admin/`
- API base used by the dashboard: `/api`, proxied to the Node API

## Production Location

The admin dashboard is currently a standalone static HTML app on the droplet:

```text
/var/www/talkflix-admin/index.html
```

Static assets in the same folder:

```text
/var/www/talkflix-admin/logo.png
/var/www/talkflix-admin/favicon.png
```

This dashboard is not the same as the Flutter app and is not the React user web app at:

```text
/Users/genius/talkflixproject/talkflix
```

The backend API source is in:

```text
/Users/genius/talkflixproject/talkflix-api
```

Production backend path on the droplet:

```text
/opt/talkflix-api
```

## Common Admin Backend Routes

Anonymous match settings:

```text
GET   /admin/anonymous-match/settings
PATCH /admin/anonymous-match/settings
POST  /admin/anonymous-match/reset-history
```

Pro/free usage limit settings:

```text
GET   /admin/pro-limits
PATCH /admin/pro-limits
```

Stripe web commerce settings:

```text
GET   /admin/commerce/stripe-config
PATCH /admin/commerce/stripe-config
```

The Settings page includes a "Stripe Checkout" card where a super admin can save or clear:

- Stripe secret key (`sk_live_...` or `sk_test_...`)
- Stripe webhook secret (`whsec_...`)

The dashboard never displays saved secrets. It only shows masked status and source. Saved secrets are encrypted server-side before being stored in `app_settings`. Prefer setting a stable `SECRET_ENCRYPTION_KEY` on the API server for long-term secret storage. If `STRIPE_SECRET_KEY` or `STRIPE_WEBHOOK_SECRET` is set as a server environment variable, that environment value remains the effective value.

These endpoints control the free-plan daily limits documented in:

```text
docs/pro-entitlements.md
```

Production dashboard status:

- The Settings page includes a "Free Plan Daily Limits" card.
- The card reads and saves through `/admin/pro-limits`.
- The Settings page includes a "Stripe Checkout" card.
- The card reads and saves through `/admin/commerce/stripe-config`.
- Last deployed to `/var/www/talkflix-admin/index.html` on 2026-06-09.

The reset-history route clears in-memory anonymous match history:

- remembered prior pairs
- skip cooldown history

It does not end active matches and does not remove users already waiting in the queue.

Backend implementation:

```text
/Users/genius/talkflixproject/talkflix-api/server.js
/Users/genius/talkflixproject/talkflix-api/socket.js
```

Production implementation:

```text
/opt/talkflix-api/server.js
/opt/talkflix-api/socket.js
```

## Inspect Production Dashboard

```bash
ssh -i /Users/genius/.ssh/id_ed25519 root@134.209.119.153 \
  "grep -n \"Anonymous Match\\|Clear match history\\|reset-history\" /var/www/talkflix-admin/index.html"
```

List admin dashboard files:

```bash
ssh -i /Users/genius/.ssh/id_ed25519 root@134.209.119.153 \
  "find /var/www/talkflix-admin -maxdepth 2 -type f -print | sort"
```

Check API health:

```bash
curl -sS https://api.talkflix.cc/health
```

Check API process:

```bash
ssh -i /Users/genius/.ssh/id_ed25519 root@134.209.119.153 \
  "pm2 status talkflix-api"
```

## Safe Edit Workflow

1. Copy production admin HTML to a temp file.

```bash
scp -i /Users/genius/.ssh/id_ed25519 \
  root@134.209.119.153:/var/www/talkflix-admin/index.html \
  /private/tmp/talkflix-admin-index.html
```

2. Edit `/private/tmp/talkflix-admin-index.html`.

3. Back up production before deploying.

```bash
ssh -i /Users/genius/.ssh/id_ed25519 root@134.209.119.153 \
  "cp /var/www/talkflix-admin/index.html /var/www/talkflix-admin/index.html.backup-$(date +%Y%m%d-%H%M%S)"
```

4. Deploy the edited file.

```bash
scp -i /Users/genius/.ssh/id_ed25519 \
  /private/tmp/talkflix-admin-index.html \
  root@134.209.119.153:/var/www/talkflix-admin/index.html
```

5. Verify the deployed HTML contains the expected change.

```bash
ssh -i /Users/genius/.ssh/id_ed25519 root@134.209.119.153 \
  "grep -n \"EXPECTED_TEXT\" /var/www/talkflix-admin/index.html"
```

## Backend Deployment Notes

When admin UI changes require API changes:

1. Patch local files in `/Users/genius/talkflixproject/talkflix-api`.
2. Run syntax checks:

```bash
node --check /Users/genius/talkflixproject/talkflix-api/server.js
node --check /Users/genius/talkflixproject/talkflix-api/socket.js
```

3. Copy to production with backups.
4. Check syntax on production before restart.
5. Restart PM2:

```bash
ssh -i /Users/genius/.ssh/id_ed25519 root@134.209.119.153 \
  "pm2 restart talkflix-api && pm2 status talkflix-api"
```

6. Verify:

```bash
curl -sS https://api.talkflix.cc/health
```

## Current Known Backups

Live admin dashboard rollback backup still present in the production folder:

```text
/var/www/talkflix-admin/index.html.backup-20260604-anon-history-reset
```

Older admin dashboard backups were moved on 2026-06-05 to:

```text
/root/talkflix-production-backups/20260605-old-live-folder-backups-archive/
```

The current production files were snapshotted before cleanup in:

```text
/root/talkflix-production-backups/20260605-pre-backup-cleanup/
```
