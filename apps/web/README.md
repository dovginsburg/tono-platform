# Tono Web

The browser surface for Tono — same Coach flow as iOS/Android, with a
browser-extension companion planned as the web's answer to the mobile
keyboard extension.

## Stack

- Next.js 14 (App Router), React 18, TypeScript strict
- `@tono/shared` — wire contract + analyzer schema shared across platforms
- i18next for locale switching (matches `apps/ios/Shared/i18n` and
  `apps/android/app/src/main/res/values*/strings.xml`)
- Deployed at **tonoit.com/app** (the marketing site at `/` is `apps/marketing/`)

## Build

```sh
cd apps/web
npm install
npm run build       # production build → .next/
npm run dev         # local dev server on http://localhost:3000
npm run typecheck   # tsc --noEmit (no full build)
```

`next.config.js` transpiles `@tono/shared` from source in dev — production
builds use the workspace `dist/` (see `packages/shared` if linked).

## Layout

```
app/            Next.js App Router entry (layout.tsx, page.tsx, globals.css)
components/     React components (CoachForm, PasskeyAuth, ResultCard, ...)
lib/            API client, device helpers, i18n bootstrap
```

## Pointing at a backend

The web app calls `NEXT_PUBLIC_TONO_API_URL` (default `http://localhost:8765`,
matching `apps/backend`'s `uvicorn Backend.server:app --port 8765`).

## Out of scope for `tono-platform`

This subtree was cherry-picked from `dovginsburg/Tono-/apps/web/` via
`git subtree add` in commit `2dc042c`. New development continues in
`Tono-` until the final-excellence gate (`t_319676e8`) clears this subtree.
See `../../OWNERSHIP.md` for the canonical-per-platform table.
