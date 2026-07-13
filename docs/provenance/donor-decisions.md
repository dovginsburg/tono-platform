# Canonical import and donor decisions

## Immutable source choices

| Component | Selected source | Decision |
|---|---|---|
| Backend | original head `2821a222…` plus sanitized active working snapshot | Preserve the active committed history and the newer account/passkey/rate-limit/backend work. Local databases, caches, and skill scratch content were not imported. |
| Web | `78b2bf9…` | Exact clean active Next.js head used by the current Vercel source line. Local `.env*`, `.next`, and `.vercel` state were not imported. |
| iOS | protected build-85 `dc7ea04…` | Imported exactly as the source tree authority; the original repository and SHA were not modified. History was path-rewritten and sanitized, so the canonical equivalent is `f3acaa2…`. `ios/Backend`, signing material, databases, archives, and scratch binaries were excluded. |
| Android | original head `754a06f…` plus sanitized active source snapshot | Preserved the one source commit, then captured current billing/tests/source changes. `.gradle`, every build output, release candidate artifacts, keystores, and Play credentials were excluded. |
| tono-claude | `107b2a9…`, allowlisted files only | Imported only `Backend/db.py`, Redis client/rate limiter, Alembic configuration/migrations, Docker Compose, and donor CI history under `vendor/reviewed/tono-claude`. Native/web/desktop/browser-extension scaffolds were rejected. |
| tono-platform-claude | none | Rejected wholesale: tracked authority is the legacy static site while `apps/` is untracked local state. No unique reviewed source was identified. |
| Legacy static website | none | Not imported as an application authority. The active Next.js web source is canonical; static legal/SEO parity remains a later archival gate. |

## Why history SHAs changed

`git-filter-repo` rewrote every accepted history into its explicit monorepo root and removed prohibited data/build/signing paths. Rewriting necessarily changes commit IDs. `history-map.json` records original head, rewritten original head, and final imported head; raw filter maps are retained in `maps/`.

The original repositories were read-only throughout. In particular, protected iOS build-85 `dc7ea04bec4af57cc901b99ddc034574d6353c10` still resolves unchanged in `/Users/Ezra/Projects/apps/tono/ios`.

## Donor activation boundary

The reviewed Postgres/Redis/Alembic donor is preserved but intentionally not wired into the active SQLite backend in this card. Activating it before the schema and live-snapshot migration gates would create an unsafe implicit data migration. The truthful artifact schema revision is therefore `legacy-sqlite-unversioned`; the donor Alembic revision `a4fa19f51921` is reference input for the later schema card.

## Original repositories

No original remote was pushed, tagged, reset, cleaned, or modified. No production deployment occurred. The canonical repository has only local donor remotes used for the import; production remotes must be attached by the orchestrator after independent review.
