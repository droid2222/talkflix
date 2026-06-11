# Local development

Last updated: 2026-06-10

## Flutter app (this repo)

From the repository root:

```bash
flutter pub get
flutter run
```

By default the app talks to **production** `https://api.talkflix.cc`. That is intentional so simulators and devices work without a local API.

### Point at a local API

Use your machine's LAN IP (not `127.0.0.1`) when testing on a **physical phone**:

```bash
flutter run --dart-define=API_BASE_URL=http://YOUR_MAC_LAN_IP:4000
```

Simulator/emulator can use:

```bash
# iOS Simulator → Mac localhost
flutter run --dart-define=API_BASE_URL=http://127.0.0.1:4000

# Android Emulator → host machine
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:4000
```

Verify the API:

```bash
curl http://127.0.0.1:4000/health
# {"ok":true,"db":true}
```

### Two-client testing

Use any pair on the same network:

- iOS Simulator + physical phone (phone needs LAN IP define)
- Android Emulator + physical phone
- Two physical phones (both can use production API, or both use LAN IP)

See [qa-manual.md](qa-manual.md) for what to exercise.

## Backend API (separate checkout)

The Node.js API is **not** inside this Flutter repo. Typical layouts:

| Layout | API path |
| --- | --- |
| Sibling folder | `../talkflix-api` next to `talkflix_flutter` |
| Existing custom checkout | Set `TALKFLIX_API_ROOT` to that local path |

Set an environment variable so scripts and docs match your machine:

```bash
export TALKFLIX_API_ROOT=/path/to/talkflix-api
```

Optional production/admin helpers used by ops docs:

```bash
export TALKFLIX_PROD_HOST=root@your-production-host
export TALKFLIX_SSH_KEY=~/.ssh/your-production-key
export TALKFLIX_WEB_ROOT=/var/www/talkflix-web
export TALKFLIX_ADMIN_WEB_ROOT=/var/www/talkflix-admin
```

Do not commit real production hosts, private key paths, API keys, signing files, or `.env` values.

Run locally:

```bash
cd "$TALKFLIX_API_ROOT"
npm install
npm run dev   # or: node server.js / pm2 — follow that repo's README
```

MySQL should have the `talkflix` schema imported from your SQL dump.

**Production API** (no local MySQL required for Flutter-only work):

- URL: `https://api.talkflix.cc`
- Droplet path: `/opt/talkflix-api`
- Process: `pm2` service `talkflix-api` on port `4000` behind nginx

Do not edit production `.env` or restart PM2 unless you intend to deploy. See `docs/v1-release-handoff.md`.

## iOS notes

After `flutter clean`:

```bash
flutter pub get
cd ios && pod install && cd ..
```

Open `ios/Runner.xcworkspace` in Xcode for device signing. Team id is set in the Xcode project for `cc.talkflix.app`.

## Android notes

- Cleartext HTTP is allowed for dev (local API).
- Release signing: copy `android/key.properties.example` → `android/key.properties` before Play Store builds.

## Debug-only QA screens

In **debug** builds only (`flutter run`, not `--release`):

- Profile → Settings → Diagnostics (debug-only entry)
- Routes: `/app/profile/diagnostics`, `/app/profile/qa-checklist`, `/app/profile/media-preview`

These are gated by `AppConfig.localQaToolsEnabled` (`kDebugMode`). See [configuration.md](configuration.md).

## Verify before pushing

```bash
dart analyze
flutter test
```
