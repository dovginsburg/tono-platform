# OWNERSHIP

**Status: BUILD-OUT.** This table names the canonical-per-platform *destination* in
this repo. Until the final-excellence gate passes, the legacy source repos remain
the working canonical and continue to receive new work.

## Sync direction

`dovginsburg/tono-platform` is the **destination** for cherry-picks, not a
push target back into the legacy repos. The 5 source repos stay open and
keep receiving new work; we pull from them via `git subtree`. See
`README.md` §Sync direction for the full diagram.

```
dovginsburg/tono-ios         ─┐
dovginsburg/Tono-            ─┤
dovginsburg/tonoit.com       ─┼──>  dovginsburg/tono-platform  (this repo)
dovginsburg/tono-backend     ─┤
dovginsburg/tono-android     ─┘
```

## Canonical-per-platform

| Platform | Canonical home | Source-of-truth (during build-out) | Cherry-picked from |
|---|---|---|---|
| iOS | `apps/ios/` | `dovginsburg/tono-ios` (main) | `tono-ios/main` (v28 = cdeb8a5 + 4726a50); keyboard parity cherry-pick from `Tono-/claude/tono-globalization-rzoqc7` |
| Android | `apps/android/` | `dovginsburg/Tono-` (apps/android/) | `Tono-/apps/android/` (more recent than `tono-android/`) |
| Web (app) | `apps/web/` | `dovginsburg/Tono-` (apps/web/) | `Tono-/apps/web/` (Next.js 14, deployed at tonoit.com/app). Note: there is no standalone `tono-web` GitHub repo — the web app only exists as a subtree of `Tono-`. |
| Marketing | `apps/marketing/` | `dovginsburg/tonoit.com` (main) | `tonoit.com/main` (static HTML at tonoit.com/ root). Distinct from the web app — `tonoit.com` is the marketing site. |
| Backend | `apps/backend/` | `dovginsburg/Tono-` (apps/backend/) | `Tono-/apps/backend/` (Postgres+Redis+Stripe-account+WebAuthn) |

## Legacy repos (READ-ONLY during build-out, archive-pending after gate)

| Repo | Last push | Decision |
|---|---|---|
| `dovginsburg/tono-ios` | 2026-07-05 20:28 UTC | Archive after `apps/ios/` is excellent (per platform gate) |
| `dovginsburg/Tono-` | 2026-07-05 20:26 UTC | Archive after web/android/backend are excellent |
| `dovginsburg/tonoit.com` | 2026-07-05 16:31 UTC | Archive after `apps/web/` is excellent |
| `dovginsburg/tono-backend` | 2026-06-26 02:03 UTC | Already superseded by `Tono-/apps/backend/` |
| `dovginsburg/tono-android` | 2026-06-25 02:32 UTC | Already superseded by `Tono-/apps/android/` |

## What "excellent" means per platform

A platform is "excellent" when:

1. Its `apps/<platform>/` subtree in this repo builds green from a clean clone.
2. Its existing CI workflow (if any) is preserved at `apps/<platform>/.github/workflows/`.
3. A smoke test for at least one happy path passes.
4. No source-of-truth file is missing relative to the legacy repo (per the
   `t_319676e8` completeness comparison).

## Decision authority

No archive or delete happens without Dov's explicit per-repo 👍. The final gate
(`t_319676e8`) surfaces the verification report + 7-day soak and waits for go/no-go.