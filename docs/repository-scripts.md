# Repository scripts

Last updated: 2026-06-10

Only scripts under `tool/` are part of the supported release workflow. Do not run ad-hoc patch scripts against production without a backup and a handoff note in `docs/v1-release-handoff.md`.

## Supported (`tool/`)

| Script | Purpose |
| --- | --- |
| `tool/build_web_preserving_homepage.sh` | `flutter build web` then restores static `web/index.html` into `build/web/` |
| `tool/check_web_homepage.sh` | Validates homepage HTML has required legal links and assets |

Web release:

```bash
tool/build_web_preserving_homepage.sh
```

See [web-homepage.md](web-homepage.md).

## Asset maintenance (`tools/`)

| Script | Purpose |
| --- | --- |
| `tools/generate_app_icons.sh` | Regenerate launcher icons (run when branding assets change) |

## Production server changes

Backend deployment is **not** automated from this Flutter repo. Production today:

- Host: DigitalOcean droplet (`api.talkflix.cc`)
- API path: `/opt/talkflix-api`
- Restart: `pm2 restart talkflix-api`

Always back up `server.js` / `socket.js` before overwriting. See `docs/v1-release-handoff.md` and `docs/production-backup-retention.md`.

One-off server patch scripts should live outside this repo or in a dedicated ops repo with review — not in the app release branch.

## What not to commit

- `android/key.properties` and keystore files
- Production `.env` or API keys
- Personal SSH exploration scripts with embedded host IPs (use env vars and internal runbooks instead)
