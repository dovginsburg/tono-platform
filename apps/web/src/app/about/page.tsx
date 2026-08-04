// /about — Tono story: why it exists, what it is, and what it isn't.
//
// Lives at /about (no basePath prefix in the source — Next.js
// applies basePath: '/app' so the live URL is /app/about).
//
// Contact identity comes from src/lib/contact.ts — the single source of the
// official tonoit.com aliases — never a hand-typed operator mailbox.
//
// Token reference: tailwind.config.ts (tono-bg, tono-text, tono-accent,
// tono-border, tono-text-soft). No new colors. Brand voice: lowercase,
// no marketing fluff.

import type { Metadata } from 'next'
import Link from 'next/link'
import { TONO_CONTACT, tonoMailto } from '../../lib/contact'

export const metadata: Metadata = {
  title: 'about — tono',
  description: 'why tono exists, who builds it, and what it isn\'t.',
}

export default function AboutPage() {
  return (
    <main className="min-h-screen bg-tono-bg text-tono-text font-sans antialiased">
      <div className="max-w-3xl mx-auto px-6 py-16 md:py-24">
        <Link
          href="/"
          className="text-sm text-tono-text-soft hover:text-tono-text transition min-h-[44px] inline-flex items-center"
        >
          ← back
        </Link>

        <span className="block mt-8 text-[11px] uppercase tracking-wider font-semibold text-tono-accent-light">
          about
        </span>
        <h1 className="text-4xl md:text-5xl font-bold tracking-[-0.02em] mt-3 leading-[1.05]">
          say what you mean. without the dread.
        </h1>
        <p className="text-tono-text-soft text-base md:text-lg leading-[1.65] mt-5">
          tono is a pre-send rewrite tool for the messages that matter. paste a
          draft, and you get four rewrites — warmer, clearer, funnier, safer —
          each one labeled, each one yours to keep, edit, or ignore. nothing is
          sent for you.
        </p>

        <section className="mt-12 space-y-8 text-[15px] leading-relaxed">
          <div>
            <h2 className="text-2xl font-semibold mb-3 text-tono-text">
              why tono exists
            </h2>
            <p className="text-tono-text-soft">
              the message that matters is the one you rewrite six times before
              sending — the apology, the ask, the boundary, the reply you don't
              want to get wrong. tono gives you those alternatives in seconds, so
              the words you send are the ones you meant. your draft stays private
              and is used only to produce your rewrites; it is never stored to
              train a model. read the specifics on our{' '}
              <Link href="/privacy" className="underline hover:text-tono-text">privacy</Link>{' '}
              page.
            </p>
          </div>

          <div>
            <h2 className="text-2xl font-semibold mb-3 text-tono-text">
              what tono isn't
            </h2>
            <ul className="list-disc pl-6 space-y-2 text-tono-text-soft">
              <li>an autoresponder — tono never sends on your behalf</li>
              <li>therapeutic or mental-health advice — see our <Link href="/terms" className="underline hover:text-tono-text">terms</Link></li>
              <li>a training-data pipeline — nothing you write is used to train anything</li>
            </ul>
          </div>

          <div>
            <h2 className="text-2xl font-semibold mb-3 text-tono-text">
              how it works
            </h2>
            <p className="text-tono-text-soft">
              tono pro starts with a real 14-day free trial. after the trial, it
              is $3.99/month or $39.99/year unless cancelled — cancel anytime from
              your account page. see full{' '}
              <Link href="/pricing" className="underline hover:text-tono-text">pricing</Link>.
            </p>
          </div>

          <div>
            <h2 className="text-2xl font-semibold mb-3 text-tono-text">
              contact
            </h2>
            <p className="text-tono-text-soft">
              general, press, and partnerships:{' '}
              <a href={tonoMailto('hello')} className="underline hover:text-tono-text">{TONO_CONTACT.hello}</a>.
              account help and product feedback:{' '}
              <a href={tonoMailto('support')} className="underline hover:text-tono-text">{TONO_CONTACT.support}</a>.
              more channels on our{' '}
              <Link href="/contact" className="underline hover:text-tono-text">contact</Link>{' '}
              page.
            </p>
          </div>
        </section>
      </div>
    </main>
  )
}