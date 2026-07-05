# Tono Platform

One truly-globalized repository for all Tono product surfaces (iOS, Android, web, backend).

## Status

This repo is the **build target** for the consolidated Tono platform. It is not yet
"excellent" — see the final-excellence gate before any source repos are archived or
deleted.

Until then, **all four source repos remain the working canonical per platform**. New
work continues to land in the source repos; this repo pulls their state in via
`git subtree`.

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
  ios/      Tono iOS app (keyboard + iMessage extension)
  android/  Tono Android app (IME + main app)
  web/      Tono web app (Next.js, deployed at tonoit.com/app)
  backend/  Tono unified backend (Postgres + Redis + Stripe account billing + WebAuthn passkeys)
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