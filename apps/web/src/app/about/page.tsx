// /about — Tono story, who we are, what we believe
//
// Spec: marketing stub (Quinn, 2026-07-08). One-page canonical
// placeholder while the full About narrative is being written.
// Lives at /about (no basePath prefix in the source — Next.js
// applies basePath: '/app' so the live URL is /app/about).
//
// Token reference: tailwind.config.ts (tono-bg, tono-text, tono-accent,
// tono-border, tono-text-soft). No new colors. Brand voice: lowercase,
// no marketing fluff.

import type { Metadata } from 'next'

export const metadata: Metadata = {
  title: 'about — tono',
  description: 'why tono exists, who is building it, and what it isn\'t.',
}

export default function AboutPage() {
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
          about
        </span>
        <h1 className="text-4xl md:text-5xl font-bold tracking-[-0.02em] mt-3 leading-[1.05]">
          say what you mean. without the dread.
        </h1>
        <p className="text-tono-text-soft text-base md:text-lg leading-[1.65] mt-5">
          tono is a pre-send rewrite tool for the messages that matter. built
          by people who write to be read every day, and who got tired of
          drafting the same paragraph six ways.
        </p>

        <section className="mt-12 space-y-8 text-[15px] leading-relaxed">
          <div>
            <h2 className="text-2xl font-semibold mb-3 text-tono-text">
              what tono is
            </h2>
            <p className="text-tono-text-soft">
              a tool you paste a draft into. it returns four rewrites —
              warmer, clearer, funnier, safer — each one labeled, each one
              yours to edit, copy, or ignore. nothing leaves your browser on
              the free tier.
            </p>
          </div>

          <div>
            <h2 className="text-2xl font-semibold mb-3 text-tono-text">
              what tono isn't
            </h2>
            <ul className="list-disc pl-6 space-y-2 text-tono-text-soft">
              <li>an autoresponder — tono never sends on your behalf</li>
              <li>a therapy bot — see our <a href="/app/privacy" className="underline hover:text-tono-text">privacy</a> page</li>
              <li>a training data pipeline — nothing you write is used to train anything</li>
            </ul>
          </div>

          <div>
            <h2 className="text-2xl font-semibold mb-3 text-tono-text">
              who we are
            </h2>
            <p className="text-tono-text-soft">
              two builders, one designer, and a small but loud group of
              beta testers. we're based in brooklyn and shipping on the ios
              keyboard next. for press or partnerships, see <a href="mailto:hi@tonoit.com?subject=tono%20about" className="underline hover:text-tono-text">hi@tonoit.com</a>.
            </p>
          </div>

          <div>
            <h2 className="text-2xl font-semibold mb-3 text-tono-text">
              contact
            </h2>
            <p className="text-tono-text-soft">
              general: <a href="mailto:hi@tonoit.com" className="underline hover:text-tono-text">hi@tonoit.com</a>.
              support: open a ticket from inside the app after you sign in.
            </p>
          </div>
        </section>
      </div>
    </main>
  )
}