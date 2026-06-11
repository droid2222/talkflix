# Backend contracts

Last updated: 2026-06-11

This Flutter repo does not own the full REST or Socket.IO contract. The Node.js API repo is the source of truth for endpoint behavior, database migrations, production deployment, and backend environment variables.

## Source Of Truth

Set the backend checkout path locally:

```bash
export TALKFLIX_API_ROOT=/path/to/talkflix-api
```

Primary backend references:

```text
$TALKFLIX_API_ROOT/README.md
$TALKFLIX_API_ROOT/server.js
$TALKFLIX_API_ROOT/socket.js
$TALKFLIX_API_ROOT/docs/
$TALKFLIX_API_ROOT/migrations/
```

Update the API repo docs when backend env vars, request/response payloads, socket events, migrations, or deployment steps change.

## Flutter-Owned Expectations

- `API_BASE_URL` controls the REST base URL. Production default is `https://api.talkflix.cc`.
- Socket.IO connects to the same API origin through `SocketService`.
- Authenticated REST calls require the current session bearer token.
- Direct chat, direct calling, anonymous match, live rooms, and notifications all depend on Socket.IO events staying compatible with the Flutter listeners.
- Production media URLs may be returned as `/uploads/...`; Flutter resolves them through the app media URL helpers.

## Contract Change Checklist

When changing a backend contract used by Flutter:

1. Update the API repo implementation and API docs first.
2. Update Flutter data models/repositories/controllers that consume the contract.
3. Run targeted Flutter analysis/tests for the changed feature.
4. Run backend syntax checks:

```bash
node --check "$TALKFLIX_API_ROOT/server.js"
node --check "$TALKFLIX_API_ROOT/socket.js"
```

5. Update this repo's feature docs only when Flutter behavior, launch risk, or developer setup changes.
