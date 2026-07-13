// /features — Tono feature overview (canonical placeholder)
//
// Spec: marketing stub (Quinn, 2026-07-08). One-page canonical
// placeholder. The deep feature tour lives at / (the marketing landing
// page) — this URL exists so the marketing site has a shareable
// permalink for the four-tones feature area.
//
// Token reference: tailwind.config.ts. No new colors.

import type { Metadata } from 'next'

export const metadata: Metadata = {
  title: 'features — tono',
  description: 'the four tones, free vs pro, ios keyboard, and how tono handles your drafts.',
}

const FEATURES = [
  {
    label: 'four tones',
    title: 'warmer, clearer, funnier, safer.',
    body: 'every draft becomes four. each one is named, colored, and ready to copy. you pick the one that fits the moment.',
  },
  {
    label: 'privacy',
    title: 'drafts stay in your browser.',
    body: 'the free tier never sends your text to a server. signed-in pro users get quota + local history, never a server-side copy.',
  },
  {
    label: 'ios keyboard',
    title: 'rewrite inside any app.',
    body: 'the tono ios keyboard ships with pro. highlight, rewrite in place, ship.',
  },
  {
    label: 'history',
    title: 'the last 50 rewrites, locally.',
    body: 'pro users get a local history of their last 50 rewrites. scroll back to yesterday\'s safer version of that angry reply.',
  },
]

export default function FeaturesPage() {
  return (
    <main className="min-h-screen bg-tono-bg text-tono-text font-sans antialiased">
      <div className="max-w-3xl mx-auto px-6 py-16 md:py-24">
        <a
          href="/"
          className="text-sm text-tono-text-soft hover:text-tono-text transition min-h-[44px] inline-flex items-center"
        >
          ← back
        </a>

        <span className="block mt-8 text-[11px] uppercase tracking-wider font-semibold text-tono-accent-light">
          features
        </span>
        <h1 className="text-4xl md:text-5xl font-bold tracking-[-0.02em] mt-3 leading-[1.05]">
          what tono does, on one page.
        </h1>
        <p className="text-tono-text-soft text-base md:text-lg leading-[1.65] mt-5">
          four rewrite modes, no server-side copy on the free tier, an ios
          keyboard, and a local history. that's the whole product.
        </p>

        <div className="mt-12 space-y-5">
          {FEATURES.map((f) => (
            <article
              key={f.label}
              className="bg-tono-bg-card border border-tono-border rounded-[18px] p-6"
            >
              <span className="text-[11px] uppercase tracking-wider font-semibold text-tono-accent-light">
                {f.label}
              </span>
              <h2 className="text-xl md:text-[22px] font-semibold mt-2 mb-2 tracking-tight">
                {f.title}
              </h2>
              <p className="text-[15px] text-tono-text-soft leading-[1.6]">
                {f.body}
              </p>
            </article>
          ))}
        </div>

        <div className="mt-12 text-center">
          <a
            href="/pricing"
            className="inline-flex items-center justify-center gap-2 px-6 py-3.5 rounded-[12px] bg-tono-accent hover:bg-tono-accent-hover text-white font-semibold transition min-h-[48px]"
          >
            see pricing →
          </a>
        </div>
      </div>
    </main>
  )
}