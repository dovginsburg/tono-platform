'use client'

import { useState } from 'react'

// ── Newsletter form ────────────────────────────────────────────────────
// No backend yet — the form just shows a "subscribed" success state.
// TODO: wire to /api/subscribe (Tono server) and persist to a list
// (Buttondown, Resend audiences, etc.). Defer until the launch list
// question is settled.
//
// Kept as a client component because the onSubmit handler is interactive
// (no network round trip yet, just a local success state).
export default function NewsletterSignup() {
  const [email, setEmail] = useState('')
  const [subscribed, setSubscribed] = useState(false)

  return (
    <div className="mt-10 pt-8 border-t border-tono-border">
      <div className="grid sm:grid-cols-[1.1fr_1fr] gap-6 items-start">
        <div>
          <p className="text-[14px] font-semibold text-tono-text">
            Get the next rewrite.
          </p>
          <p className="text-[12px] text-tono-text-softer leading-[1.55] mt-1 max-w-sm">
            One short email a month — what we shipped, what we broke, what we
            learned about tone. No tracking pixels, no marketing automation.
          </p>
        </div>
        <form
          onSubmit={(e) => {
            e.preventDefault()
            // Stub: local success state. Wire to /api/subscribe when
            // backend is ready.
            setSubscribed(true)
            setEmail('')
          }}
          className="flex flex-col sm:flex-row gap-2"
        >
          <label htmlFor="tono-newsletter-email" className="sr-only">
            Email address
          </label>
          <input
            id="tono-newsletter-email"
            name="email"
            type="email"
            required
            placeholder="you@somewhere.com"
            autoComplete="email"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            disabled={subscribed}
            className="flex-1 min-w-0 px-3 py-2.5 rounded-[10px] bg-tono-bg-card border border-tono-border text-[13px] text-tono-text placeholder:text-tono-muted focus:border-tono-accent focus:outline-none transition min-h-[44px] disabled:opacity-60"
          />
          <button
            type="submit"
            disabled={subscribed}
            className="inline-flex items-center justify-center gap-2 px-4 py-2.5 rounded-[10px] bg-tono-accent hover:bg-tono-accent-hover text-white font-semibold transition min-h-[44px] text-[13px] disabled:opacity-70 disabled:cursor-default"
          >
            {subscribed ? 'subscribed ✓' : 'Subscribe'}
          </button>
        </form>
      </div>
      <p className="text-[11px] text-tono-muted mt-3">
        {/* TODO: replace with real endpoint when list infra is ready. */}
        Stub signup — backend wiring coming soon.
      </p>
    </div>
  )
}
