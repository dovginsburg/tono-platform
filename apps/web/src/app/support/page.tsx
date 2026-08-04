// /support — Tono customer + App Review help page.
//
// Lives at /support (no basePath prefix in the source — Next.js applies
// basePath: '/app' so the built route is /app/support). The apex deep-link
// https://tonoit.com/support is served by a vercel.json rewrite
// (/support -> /app/support), exactly like /about and /contact; without that
// rewrite the anonymous apex load 404s. See tests/support-route-contract.test.cjs.
//
// Contact identity comes from src/lib/contact.ts — the single source of the
// official tonoit.com aliases — never a hand-typed operator mailbox.
//
// Token reference: tailwind.config.ts (tono-bg, tono-text, tono-text-soft,
// tono-accent-light, tono-bg-card, tono-border, tono-accent). No new colors.
// Brand voice: lowercase, plain, no fluff. Copy is deliberately truthful:
// no in-app tickets, no login requirement, no response-time promise, and no
// medical/therapy claim — email is the channel and this page loads anonymously.

import type { Metadata } from 'next'
import Link from 'next/link'
import { TONO_CONTACT, tonoMailto } from '../../lib/contact'

export const metadata: Metadata = {
  title: 'support — tono',
  description:
    'get help with your tono account, billing, and access — and how to reach the tono team by email.',
}

export default function SupportPage() {
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
          support
        </span>
        <h1 className="text-4xl md:text-5xl font-bold tracking-[-0.02em] mt-3 leading-[1.05]">
          help with tono.
        </h1>
        <p className="text-tono-text-soft text-base md:text-lg leading-[1.65] mt-5">
          the fastest way to reach us is email. we read every message. there's
          no ticket to file and no account needed to get help — just write to{' '}
          <a href={tonoMailto('support')} className="underline hover:text-tono-text">
            {TONO_CONTACT.support}
          </a>
          .
        </p>

        <div className="mt-8">
          <a
            href={tonoMailto('support')}
            className="inline-flex items-center justify-center gap-2 px-5 py-3 rounded-[10px] bg-tono-accent hover:bg-tono-accent-hover text-white font-semibold transition min-h-[44px] text-[14px]"
          >
            email support
          </a>
        </div>

        <section className="mt-14 space-y-8 text-[15px] leading-relaxed">
          <div>
            <h2 className="text-2xl font-semibold mb-3 text-tono-text">
              what to include
            </h2>
            <p className="text-tono-text-soft mb-3">
              so we can help on the first reply, add what you can:
            </p>
            <ul className="list-disc pl-6 space-y-2 text-tono-text-soft">
              <li>the email address on your account</li>
              <li>your device and OS version (for example, iPhone on iOS 18)</li>
              <li>what you expected, and what happened instead</li>
              <li>a screenshot, if you have one</li>
            </ul>
          </div>

          <div>
            <h2 className="text-2xl font-semibold mb-3 text-tono-text">
              account, billing &amp; access
            </h2>
            <p className="text-tono-text-soft">
              you can manage your subscription — including cancelling — from your{' '}
              <Link href="/account" className="underline hover:text-tono-text">account</Link>{' '}
              page. tono pro is $3.99/month or $39.99/year after a 14-day free
              trial, and renews unless cancelled. for a question about a charge,
              a refund, or getting back into your account, email{' '}
              <a href={tonoMailto('support')} className="underline hover:text-tono-text">
                {TONO_CONTACT.support}
              </a>{' '}
              from the address on your account.
            </p>
          </div>

          <div>
            <h2 className="text-2xl font-semibold mb-3 text-tono-text">
              privacy &amp; terms
            </h2>
            <p className="text-tono-text-soft">
              how we handle your drafts and data is on our{' '}
              <Link href="/privacy" className="underline hover:text-tono-text">privacy</Link>{' '}
              page. the rules for using tono are in our{' '}
              <Link href="/terms" className="underline hover:text-tono-text">terms</Link>. for a
              privacy or data-deletion request, write to{' '}
              <a href={tonoMailto('privacy')} className="underline hover:text-tono-text">
                {TONO_CONTACT.privacy}
              </a>
              .
            </p>
          </div>

          <div>
            <h2 className="text-2xl font-semibold mb-3 text-tono-text">
              not for emergencies
            </h2>
            <p className="text-tono-text-soft">
              tono is a writing tool — not an emergency, medical, or
              mental-health service, and email support is not monitored around
              the clock. if you're in crisis or facing an emergency, contact
              your local emergency number or a crisis line in your area.
            </p>
          </div>
        </section>
      </div>
    </main>
  )
}
