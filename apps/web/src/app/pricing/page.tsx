// ──────────────────────────────────────────────────────────────────────
// /app/pricing — Tono public pricing page.
//
// Two tier cards (Trial / Pro) plus a one-line Family waitlist callout
// (the Family backend is not wired in v1 — showing it as a full card
// with a disabled "coming soon" button was misleading visitors).
// Source files referenced: ProCheckoutButton.tsx (existing),
// src/app/page.tsx#pricing (markup we mirror), tailwind.config.ts
// (tokens).
//
// Why server-side render: this page is mostly static copy + 2 cards,
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
            free for 7 days. pro when you rewrite all day.
          </h1>
          <p className="text-[16px] md:text-[17px] text-tono-text-soft leading-[1.6] mt-5">
            cancel anytime. web access starts after checkout; ios is coming soon.
          </p>
        </header>

        {/* Two-tier grid — Trial | Pro. md+: 2 cols. <md: stacks.
            Family is a one-line waitlist callout below the grid. */}
        <div className="grid grid-cols-1 md:grid-cols-2 gap-5">
          {/* ── Trial ────────────────────────────────────────────── */}
          <article
            data-tier="trial"
            className="bg-tono-bg-card border border-tono-border rounded-[18px] p-7 flex flex-col"
          >
            <p className="text-[11px] uppercase tracking-wider font-semibold text-tono-text-softer">
              free for 7 days
            </p>
            <p className="text-[40px] md:text-[44px] font-bold tracking-[-0.02em] text-tono-text mt-2">
              $0
              <span className="text-[15px] font-normal text-tono-text-softer ml-2">
                first 7 days
              </span>
            </p>
            <p className="text-[14px] text-tono-text-soft leading-[1.55] mt-3">
              start a real trial. we'll never charge until day 8.
            </p>
            <ul className="mt-6 space-y-2.5 text-[14px] text-tono-text-soft flex-1">
              <li className="flex gap-2">
                <CheckIcon />
                <span>no charge until day 8</span>
              </li>
              <li className="flex gap-2">
                <CheckIcon />
                <span>drafts are sent only when you choose rewrite</span>
              </li>
              <li className="flex gap-2">
                <CheckIcon />
                <span>nothing about your writing trains anything</span>
              </li>
              <li className="flex gap-2">
                <CheckIcon />
                <span>cancel anytime during the trial</span>
              </li>
            </ul>
            <ProCheckoutButton
              interval="month"
              label="start 7-day free trial"
              className="mt-8 inline-flex items-center justify-center gap-2 px-5 py-3 rounded-[12px] bg-transparent border border-tono-border-strong text-tono-text hover:border-tono-accent disabled:opacity-60 disabled:pointer-events-none font-semibold transition min-h-[44px] text-[14px]"
            >
              start 7-day free trial
            </ProCheckoutButton>
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
              $3.99
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
              <ProCheckoutButton interval="month" label="go pro — $3.99/mo">
                go pro — $3.99/mo
              </ProCheckoutButton>
              <ProCheckoutButton
                interval="year"
                label="go pro — $39.99/yr · save $7.89"
                className="inline-flex items-center justify-center gap-2 px-5 py-3 rounded-[12px] bg-transparent border border-tono-border-strong text-tono-text hover:border-tono-accent disabled:opacity-60 disabled:pointer-events-none font-semibold transition min-h-[44px] text-[14px] min-w-0 max-w-full text-center whitespace-normal leading-snug"
              >
                go pro — $39.99/yr · save $7.89
              </ProCheckoutButton>
            </div>
            <p className="text-[12px] text-tono-text-softer mt-3">
              billed monthly or yearly. cancel from your inbox.
            </p>
          </article>

          </div>

        {/* ── Family waitlist — one-line callout, no full pricing card.
                Backend is not wired in v1. Re-add as a full card when
                Family ships to production. ─────────────────────────── */}
        <p className="text-center text-[14px] text-tono-text-softer mt-8">
          <span className="font-semibold text-tono-text">Family — waitlist only.</span>{' '}
          <a
            href="mailto:hello@tonoit.com?subject=family%20plan%20waitlist"
            className="text-tono-accent-light hover:text-tono-text underline-offset-2 hover:underline"
          >
            get notified
          </a>{' '}
          when it ships.
        </p>

        <p className="text-center text-[13px] text-tono-text-softer mt-12">
          subscriptions auto-renew at $3.99/mo or $39.99/yr after the 7-day free trial unless cancelled. cancel anytime.
        </p>

        {/* Footnote */}
        <p className="text-center text-[13px] text-tono-text-softer mt-3">
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
