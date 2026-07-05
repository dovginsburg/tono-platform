# Tono Platform

One truly-globalized repository for all Tono product surfaces (iOS, Android, web, backend).

## Status

This repo is the **build target** for the consolidated Tono platform. It is not yet
"excellent" — see the final-excellence gate before any source repos are archived or
deleted.

Until then, **all four source repos remain the working canonical per platform**. New
work continues to land in the source repos; this repo pulls their state in via
`git subtree`.

## Quickstart

One repo, five subtrees. Clone, pick a platform, follow the per-platform
docs.

```sh
git clone https://github.com/dovginsburg/tono-platform.git
cd tono-platform
```

### iOS — Xcode

```sh
cd apps/ios
open Tono.xcodeproj          # opens in Xcode; ⌘U to run tests
# OR, headless build:
xcodebuild -project Tono.xcodeproj -scheme Tono -destination 'generic/platform=iOS Simulator' build
```

Requires Xcode 16+, iOS 16+ SDK. Bundle IDs `com.tonocoach.app` and
`com.tonocoach.app.keyboard`; App Group `group.com.tonocoach.shared`.

### Android — Gradle wrapper

```sh
cd apps/android
./gradlew --version          # confirms wrapper works
./gradlew assembleDebug      # debug APK at app/build/outputs/apk/debug/
# OR: open apps/android in Android Studio and let it sync.
```

Requires JDK 17+, Android SDK + platform-tools. AGP 8.5.2, Kotlin 1.9.24,
Compose. The keyboard lives in the same `:app` module as the host UI (an
`InputMethodService`, not a separate app extension target).

If you ever need to regenerate the wrapper after a Gradle bump:

```sh
cd apps/android
gradle wrapper --gradle-version 8.7   # uses a system-installed gradle once
```

### Web — Next.js

```sh
cd apps/web
npm install
npm run dev                  # http://localhost:3000
npm run build && npm start   # production
npm run typecheck            # tsc --noEmit
```

Requires Node 20+. `@tono/shared` is transpiled from source in dev. Points
at `http://localhost:8765` by default — match with the backend quickstart.

### Backend — FastAPI + uvicorn

```sh
cd apps/backend
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
docker compose up -d postgres redis
alembic upgrade head
uvicorn Backend.server:app --port 8765 --reload
# OpenAPI: http://localhost:8765/docs
```

Requires Python 3.11+ (3.9+ for dev), Docker. Copy `.env.example` to
`.env` and fill in at least `DATABASE_URL` + `REDIS_URL`. Open `pytest -q`
to run the test suite.

### Marketing site — static HTML

```sh
cd apps/marketing
python -m http.server 8080   # or use Netlify / Cloudflare Pages / GH Pages
```

The live site is **tonoit.com** (pinned by `CNAME`). No build step.

## Per-platform docs

Each subtree has its own README with full build instructions, layout, and
deployment specifics. Read these before diving into a platform.

- iOS — `apps/ios/README.md`
- Android — `apps/android/README.md`
- Web — `apps/web/README.md`
- Backend — `apps/backend/README.md`
- Marketing — `apps/marketing/README.md`

## Sync direction

```
dovginsburg/tono-ios         ─┐
dovginsburg/Tono-            ─┤
dovginsburg/tonoit.com       ─┼──>  dovginsburg/tono-platform  (this repo)
dovginsburg/tono-backend     ─┤
dovginsburg/tono-android     ─┘
```

The new repo is the **destination** for cherry-picks. It is not the source for pushes
back into the legacy repos.

## Layout

```
apps/
  ios/       Tono iOS app (keyboard + iMessage extension)
  android/   Tono Android app (IME + main app)
  web/       Tono web app (Next.js, deployed at tonoit.com/app)
  backend/   Tono unified backend (Postgres + Redis + Stripe account billing + WebAuthn passkeys)
  marketing/ tonoit.com marketing site (static HTML)
```

## Source repos (READ-ONLY during build-out)

| Repo | Role |
|---|---|
| `dovginsburg/tono-ios` | Production iOS (v28 = cdeb8a5 + 4726a50). Starting point for `apps/ios/`. |
| `dovginsburg/Tono-` | Multi-platform refactor; backend/web/android + iOS scaffold. |
| `dovginsburg/tonoit.com` | Web app (deployed at tonoit.com/app). |
| `dovginsburg/tono-backend` | Older backend. Skip — `apps/backend/` comes from `Tono-/apps/backend/`. |
| `dovginsburg/tono-android` | Older Android. Skip — `apps/android/` comes from `Tono-/apps/android/`. |

See `OWNERSHIP.md` for the canonical-per-platform table.

## Iteration plan

After each `apps/<platform>/` lands, we run the platform's build/test, fix anything
that breaks, and only then move to the next platform. "Excellent" means all four
platforms build green from a clean clone, top-level CI is green, and a smoke test
passes for at least one happy path per platform.

When "excellent" is reached, the final-excellence verification gate (`t_319676e8`)
runs. Only after Dov's explicit 👍 per repo do any legacy repos get archived.