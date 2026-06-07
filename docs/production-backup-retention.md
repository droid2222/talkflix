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
