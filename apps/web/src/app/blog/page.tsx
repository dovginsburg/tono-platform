// /blog — Tono changelog / writing / product notes index
//
// Spec: marketing stub (Quinn, 2026-07-08). One-page canonical
// placeholder so the URL exists in the top-right nav and on the
// marketing sitemap. The real blog ships later; this stub lists the
// most recent changelog entries so the page is never blank.

import type { Metadata } from 'next'
import Link from 'next/link'

export const metadata: Metadata = {
  title: 'blog — tono',
  description: 'changelog, product notes, and the writing on pre-send rewrite.',
}

const POSTS = [
  {
    date: '2026-07-08',
    label: 'product',
    title: 'public beta opens for the ios keyboard',
    body: 'pro subscribers can install the tono ios keyboard today. free beta slots open weekly.',
  },
  {
    date: '2026-07-04',
    label: 'shipping',
    title: '/pricing, /checkout/success, /upgrade are live',
    body: 'three new pages, a real stripe checkout wired into api.tonoit.com/v1/checkout, and a 308 redirect that lands upgrade clicks on the right place.',
  },
  {
    date: '2026-06-30',
    label: 'writing',
    title: 'why a pre-send rewrite tool, not a generative inbox',
    body: 'the case for keeping the human in the loop on every send — even when the rewrite is good.',
  },
]

export default function BlogPage() {
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
          blog
        </span>
        <h1 className="text-4xl md:text-5xl font-bold tracking-[-0.02em] mt-3 leading-[1.05]">
          changelog, product notes, and the writing.
        </h1>
        <p className="text-tono-text-soft text-base md:text-lg leading-[1.65] mt-5">
          short, low-cadence. we ship when there's something to ship, and
          publish when there's something worth saying.
        </p>

        <div className="mt-12 space-y-5">
          {POSTS.map((p) => (
            <article
              key={p.title}
              className="bg-tono-bg-card border border-tono-border rounded-[18px] p-6"
            >
              <div className="flex items-center gap-3 text-[11px] uppercase tracking-wider font-semibold text-tono-text-softer">
                <span className="text-tono-accent-light">{p.label}</span>
                <span>·</span>
                <time dateTime={p.date}>{p.date}</time>
              </div>
              <h2 className="text-xl md:text-[22px] font-semibold mt-2 mb-2 tracking-tight">
                {p.title}
              </h2>
              <p className="text-[15px] text-tono-text-soft leading-[1.6]">
                {p.body}
              </p>
            </article>
          ))}
        </div>

        <p className="mt-12 text-[13px] text-tono-text-softer text-center">
          for the full changelog, see{' '}
          <a
            href="https://github.com/dovginsburg/tono-platform/commits/main"
            className="underline hover:text-tono-text"
          >
            github
          </a>
          .
        </p>
      </div>
    </main>
  )
}