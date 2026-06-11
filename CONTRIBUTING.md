# Contributing

Last updated: 2026-06-11

This repo contains the Talkflix Flutter client. The backend API is a separate checkout; set `TALKFLIX_API_ROOT` before using backend commands.

## Local Setup

```bash
flutter pub get
flutter run
```

Optional backend checkout:

```bash
export TALKFLIX_API_ROOT=/path/to/talkflix-api
```

Optional production/admin helpers for ops docs:

```bash
export TALKFLIX_PROD_HOST=root@your-production-host
export TALKFLIX_SSH_KEY=~/.ssh/your-production-key
```

Do not commit real production hosts, private key paths, `.env` files, signing keys, API keys, store credentials, database dumps, or generated production backups.

## Branches And Scope

- Use short feature branches. Codex-created branches should use the `codex/` prefix.
- Keep changes scoped to the requested feature or fix.
- Do not refactor unrelated files during product fixes.
- Docs changes should be committed separately from risky app/backend behavior changes when possible.

## Required Checks

For Flutter changes, run the narrowest useful checks first:

```bash
dart analyze
flutter test
```

For web-facing changes, also run:

```bash
flutter build web --release
```

For production web releases, use the guarded homepage-preserving workflow documented in `docs/web-homepage.md`.

For backend changes in the API checkout, run:

```bash
node --check "$TALKFLIX_API_ROOT/server.js"
node --check "$TALKFLIX_API_ROOT/socket.js"
```

## Pull Request Checklist

- Explain user-visible behavior changes.
- List tests/checks run.
- Note any checks that were not run and why.
- Update docs when changing setup, feature gates, production workflow, entitlements, store behavior, or release risk.
- Link or update `docs/pending-issues.md` when opening, closing, downgrading, or accepting a risk.

## Production Safety

- Never deploy without a rollback backup for the file or directory being replaced.
- Never print or paste production secrets into docs, commits, issues, or PRs.
- Verify production health after backend deploys:

```bash
curl -sS https://api.talkflix.cc/health
```

- Verify web asset freshness after web deploys:

```bash
curl -sSI https://www.talkflix.cc/main.dart.js
```
