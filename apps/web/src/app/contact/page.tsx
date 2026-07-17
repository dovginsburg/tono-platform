// /contact — Tono support / sales / press / feedback entry point
//
// Spec: marketing stub (Quinn, 2026-07-08). One-page canonical
// placeholder routing to mailto while the full Contact form ships.
// Lives at /contact (no basePath prefix in source — Next.js applies
// basePath: '/app' so live URL is /app/contact).
//
// Note: the top-right nav's Contact item currently uses a mailto:
// (TonoNavDropdown.tsx ITEMS[5]). When this stub grows into a real
// form, swap the nav entry to point here.

import type { Metadata } from 'next'

export const metadata: Metadata = {
  title: 'contact — tono',
  description: 'support, feedback, partnerships, and press for tono.',
}

const CHANNELS = [
  {
    label: 'support',
    title: 'help with your account',
    body: 'login trouble, billing questions, or a bug you hit. include your account email and a screenshot when you can.',
    email: 'hi@tonoit.com',
  },
  {
    label: 'feedback',
    title: 'product feedback',
    body: 'a tone that misses, a workflow that\'s clunky, an idea you want us to hear. we read every email.',
    email: 'hi@tonoit.com',
  },
  {
    label: 'press',
    title: 'media & partnerships',
    body: 'podcast guest pitches, product reviews, and integration partners.',
    email: 'hi@tonoit.com',
  },
  {
    label: 'security',
    title: 'report a vulnerability',
    body: 'responsible disclosure. we triage within 24 hours and credit reporters who follow coordinated disclosure.',
    email: 'hi@tonoit.com',
  },
]

export default function ContactPage() {
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
          contact
        </span>
        <h1 className="text-4xl md:text-5xl font-bold tracking-[-0.02em] mt-3 leading-[1.05]">
          we read every email.
        </h1>
        <p className="text-tono-text-soft text-base md:text-lg leading-[1.65] mt-5">
          tono is a small team. for anything urgent, tag the subject{' '}
          <span className="font-mono text-tono-text">[URGENT]</span> and we'll
          see it first.
        </p>

        <div className="mt-12 grid sm:grid-cols-2 gap-5">
          {CHANNELS.map((c) => (
            <article
              key={c.label}
              className="bg-tono-bg-card border border-tono-border rounded-[18px] p-6"
            >
              <span className="text-[11px] uppercase tracking-wider font-semibold text-tono-accent-light">
                {c.label}
              </span>
              <h2 className="text-xl font-semibold mt-2 mb-2 tracking-tight">
                {c.title}
              </h2>
              <p className="text-[14px] text-tono-text-soft leading-[1.6] mb-4">
                {c.body}
              </p>
              <a
                href={`mailto:${c.email}?subject=${encodeURIComponent(c.label)}`}
                className="inline-flex items-center justify-center gap-2 px-4 py-2.5 rounded-[10px] bg-tono-accent hover:bg-tono-accent-hover text-white font-semibold transition min-h-[40px] text-[13px]"
              >
                email {c.label}
              </a>
            </article>
          ))}
        </div>
      </div>
    </main>
  )
}