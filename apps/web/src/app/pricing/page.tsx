// /app/pricing — Tono public pricing page.
//
// Three tier cards (Free / Pro / Family) matching Mark's design tokens
// (see tailwind.config.ts). Pro uses the existing ProCheckoutButton,
// which POSTs /api/checkout → Tono backend /v1/checkout, which only
// supports { interval: 'month' | 'year' } today — so Family is shown
// as "coming soon" rather than wired to a button that would 400.
//
// Source files referenced: ProCheckoutButton.tsx (existing),
// src/app/page.tsx#pricing (markup we mirror), tailwind.config.ts
// (tokens).
//
// Why server-side render: this page is mostly static copy + 3 cards,
// no per-user state needed. Per-button state (busy / error) is owned
// by ProCheckoutButton which is already a client component.

import Link from 'next/link'
import ProCheckoutButton from '../ProCheckoutButton'

function CheckIcon() {
  return (
    <span className="text-tono-tone-safer font-semibold" aria-hidden="true">
      ✓
    </span>
  )
}

export default function PricingPage() {
  return (
    <main className="min-h-screen bg-tono-bg text-tono-text font-sans antialiased">
      <div className="max-w-[1180px] mx-auto px-6 md:px-10 py-16 md:py-24">
        {/* Header — same eyebrow + heading pattern as landing #pricing */}
        <header className="mb-12 md:mb-16 max-w-2xl">
          <span className="text-[11px] uppercase tracking-wider font-semibold text-tono-accent-light">
            pricing
          </span>
          <h1 className="text-[36px] md:text-[48px] font-bold tracking-[-0.02em] text-tono-text mt-3 leading-[1.05]">
            free for most. pro when you rewrite all day.
          </h1>
          <p className="text-[16px] md:text-[17px] text-tono-text-soft leading-[1.6] mt-5">
            cancel anytime. the iOS keyboard ships with pro on day one.
          </p>
        </header>

        {/* Three-tier grid — Free | Pro | Family.
            md+: 3 cols. <md: stacks Free on top, then Pro (featured), then Family. */}
        <div className="grid md:grid-cols-3 gap-5">
          {/* ── Free ─────────────────────────────────────────────── */}
          <article
            data-tier="free"
            className="bg-tono-bg-card border border-tono-border rounded-[18px] p-7 flex flex-col"
          >
            <p className="text-[11px] uppercase tracking-wider font-semibold text-tono-text-softer">
              free
            </p>
            <p className="text-[40px] md:text-[44px] font-bold tracking-[-0.02em] text-tono-text mt-2">
              $0
              <span className="text-[15px] font-normal text-tono-text-softer ml-2">
                forever
              </span>
            </p>
            <p className="text-[14px] text-tono-text-soft leading-[1.55] mt-3">
              for the draft, the slack reply, the one email a week.
            </p>
            <ul className="mt-6 space-y-2.5 text-[14px] text-tono-text-soft flex-1">
              <li className="flex gap-2">
                <CheckIcon />
                <span>
                  <strong className="text-tono-text font-semibold">
                    3 rewrites a day
                  </strong>{' '}
                  — no signup required
                </span>
              </li>
              <li className="flex gap-2">
                <CheckIcon />
                <span>drafts stay in your browser only</span>
              </li>
              <li className="flex gap-2">
                <CheckIcon />
                <span>nothing about your writing trains anything</span>
              </li>
            </ul>
            <Link
              href="/app/login?next=/app/app"
              className="mt-8 inline-flex items-center justify-center gap-2 px-5 py-3 rounded-[12px] bg-transparent border border-tono-border-strong text-tono-text hover:border-tono-accent hover:text-tono-text font-semibold transition min-h-[44px] text-[14px]"
            >
              start free — no card
            </Link>
          </article>

          {/* ── Pro (featured) ───────────────────────────────────── */}
          <article
            data-tier="pro"
            className="bg-tono-bg-card border border-tono-accent/40 rounded-[18px] p-7 flex flex-col relative shadow-[0_8px_32px_rgba(168,85,247,0.18)]"
          >
            <span className="absolute -top-3 right-5 inline-flex items-center gap-1 px-3 py-1 rounded-full bg-tono-accent text-white text-[10px] font-semibold uppercase tracking-wider">
              tono pro
            </span>
            <p className="text-[11px] uppercase tracking-wider font-semibold text-tono-accent-light">
              pro
            </p>
            <p className="text-[40px] md:text-[44px] font-bold tracking-[-0.02em] text-tono-text mt-2">
              $5.99
              <span className="text-[15px] font-normal text-tono-text-softer ml-2">
                / month
              </span>
            </p>
            <p className="text-[14px] text-tono-text-soft leading-[1.55] mt-3">
              for the people who write to be read all day.
            </p>
            <ul className="mt-6 space-y-2.5 text-[14px] text-tono-text-soft flex-1">
              <li className="flex gap-2">
                <CheckIcon />
                <span>
                  <strong className="text-tono-text font-semibold">
                    unlimited rewrites
                  </strong>{' '}
                  on the web composer
                </span>
              </li>
              <li className="flex gap-2">
                <CheckIcon />
                <span>local history of your last 50 rewrites</span>
              </li>
              <li className="flex gap-2">
                <CheckIcon />
                <span>priority on the rewrite queue — no cold-start</span>
              </li>
              <li className="flex gap-2">
                <CheckIcon />
                <span>cancel anytime — no retention, no dark patterns</span>
              </li>
            </ul>
            <div className="mt-8 flex flex-col gap-3">
              <ProCheckoutButton interval="month" label="go pro — $5.99/mo">
                go pro — $5.99/mo
              </ProCheckoutButton>
              <ProCheckoutButton
                interval="year"
                label="go pro — $39.99/yr (save 45%)"
                className="inline-flex items-center justify-center gap-2 px-5 py-3 rounded-[12px] bg-transparent border border-tono-border-strong text-tono-text hover:border-tono-accent disabled:opacity-60 disabled:pointer-events-none font-semibold transition min-h-[44px] text-[14px]"
              >
                go pro — $39.99/yr
              </ProCheckoutButton>
            </div>
            <p className="text-[12px] text-tono-text-softer mt-3">
              billed monthly or yearly. cancel from your inbox.
            </p>
          </article>

          {/* ── Family ───────────────────────────────────────────── */}
          <article
            data-tier="family"
            className="bg-tono-bg-card border border-tono-border rounded-[18px] p-7 flex flex-col"
          >
            <p className="text-[11px] uppercase tracking-wider font-semibold text-tono-text-softer">
              family
            </p>
            <p className="text-[40px] md:text-[44px] font-bold tracking-[-0.02em] text-tono-text mt-2">
              $9.99
              <span className="text-[15px] font-normal text-tono-text-softer ml-2">
                / month
              </span>
            </p>
            <p className="text-[14px] text-tono-text-soft leading-[1.55] mt-3">
              for up to 5 devices on the same plan — kids, partners, the group chat.
            </p>
            <ul className="mt-6 space-y-2.5 text-[14px] text-tono-text-soft flex-1">
              <li className="flex gap-2">
                <CheckIcon />
                <span>
                  <strong className="text-tono-text font-semibold">
                    everything in pro
                  </strong>
                </span>
              </li>
              <li className="flex gap-2">
                <CheckIcon />
                <span>shared family rewrite history</span>
              </li>
              <li className="flex gap-2">
                <CheckIcon />
                <span>one bill, individual drafts</span>
              </li>
              <li className="flex gap-2">
                <CheckIcon />
                <span>priority support for the household</span>
              </li>
            </ul>
            <div className="mt-8">
              <button
                type="button"
                disabled
                aria-disabled="true"
                title="Family plan is rolling out next — join the waitlist from your inbox"
                className="w-full inline-flex items-center justify-center gap-2 px-5 py-3 rounded-[12px] bg-tono-bg-elev border border-tono-border text-tono-text-softer font-semibold transition min-h-[44px] text-[14px] cursor-not-allowed"
              >
                coming soon
              </button>
              <p className="text-[12px] text-tono-text-softer mt-3">
                not wired in v1 — backend ship pending.{' '}
                <a
                  href="mailto:hello@tonoit.com?subject=family%20plan%20waitlist"
                  className="text-tono-accent-light hover:text-tono-text underline-offset-2 hover:underline"
                >
                  get notified
                </a>
                .
              </p>
            </div>
          </article>
        </div>

        {/* Footnote */}
        <p className="text-center text-[13px] text-tono-text-softer mt-12">
          prices in USD. checkout handled by stripe — your card never touches tono.
        </p>

        {/* Back link */}
        <div className="text-center mt-6">
          <Link
            href="/"
            className="text-[13px] text-tono-text-softer hover:text-tono-text transition"
          >
            ← back to tono
          </Link>
        </div>
      </div>
    </main>
  )
}
