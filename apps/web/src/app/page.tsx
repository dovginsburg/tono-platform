// Tono landing — the public marketing page for tonoit.com/.
//
// Tono is an Operate surface (dark, professional, dry-witty).
// Voice: lowercase. No exclamation. Em-dashes over commas.
// One verb per button. The four tones named in copy match the on-screen
// accent color (warmer / clearer / funnier / safer).
//
// Surface intent: a Decide/Learn page with a real hero, real artifact
// preview, and a real footer. The previous landing was a server-side
// redirect into /app/app; that bounced unauthenticated visitors into
// the auth flow before they ever saw the product. This page is the
// marketing surface that Ezra's brief calls for: prominent wordmark,
// product story, four-tones section, and a sign-in CTA.
//
// Brand: docs/BRAND-TONO.md · tokens: tailwind.config.ts

import Link from 'next/link'
import TonoDemo from './TonoDemo'
import ProCheckoutButton from './ProCheckoutButton'

// ── Server component — no client state needed. ──────────────────────────
export default function LandingPage() {
  return (
    <main className="min-h-screen bg-tono-bg text-tono-text font-sans antialiased overflow-x-clip">
      <TonoNav />

      {/* ── Hero ──────────────────────────────────────────────────────── */}
      <section className="relative">
        {/* ambient backdrop — already in body globals, no extra div needed */}
        <div className="max-w-[1180px] mx-auto px-5 sm:px-6 md:px-10 pt-14 sm:pt-20 md:pt-28 pb-12 sm:pb-16 md:pb-24">
          <div className="grid grid-cols-1 lg:grid-cols-[1.1fr_1fr] gap-10 lg:gap-14 items-center min-w-0">
            <div>
              <span className="inline-flex items-center gap-2 px-3 py-1 rounded-full bg-tono-accent-soft text-tono-accent-light text-[11px] font-semibold uppercase tracking-wider border border-tono-accent/30">
                <span className="w-1.5 h-1.5 rounded-full bg-tono-accent shadow-[0_0_8px_var(--accent-glow)]" />
                public beta · web now · ios coming soon
              </span>
              {/* Benefit-first subline — the thing the first-2-second scanner
                  actually needs to know before reading the trust strip and h1.
                  Pitches the value, not the feature list. */}
              <p className="text-[14px] md:text-[16px] text-tono-text-soft leading-[1.45] mt-4 sm:mt-5 max-w-xl">
                Check tone before you send, in 8 seconds.
              </p>
              <p
                aria-label="trust and privacy"
                className="mt-3 text-[11px] md:text-[12px] tracking-[0.06em] uppercase font-semibold text-tono-text-softer leading-relaxed"
              >
                $3.99/mo · $39.99/yr · 7-day free trial · cancel anytime · drafts are sent only when you rewrite · not used for training
              </p>
              <h1 className="text-[36px] sm:text-[44px] md:text-[60px] leading-[1.05] md:leading-[1.02] font-bold tracking-[-0.025em] text-tono-text mt-2 sm:mt-3">
                paste a draft.{' '}
                <em className="not-italic text-tono-accent-light">get four ways to say it.</em>
              </h1>
              <div className="mt-5 flex flex-wrap items-center gap-x-3 gap-y-2 text-[15px] md:text-[16px] text-tono-text-soft leading-[1.5]">
                <span className="text-tono-text-softer">pick one —</span>
                <span className="inline-flex items-center gap-1.5 px-2 py-1 rounded-[8px] tone-bg-soft-warmer tone-text-warmer font-semibold text-[13px]">warmer</span>
                <span className="inline-flex items-center gap-1.5 px-2 py-1 rounded-[8px] tone-bg-soft-clearer tone-text-clearer font-semibold text-[13px]">clearer</span>
                <span className="inline-flex items-center gap-1.5 px-2 py-1 rounded-[8px] tone-bg-soft-funnier tone-text-funnier font-semibold text-[13px]">funnier</span>
                <span className="inline-flex items-center gap-1.5 px-2 py-1 rounded-[8px] tone-bg-soft-safer tone-text-safer font-semibold text-[13px]">safer</span>
                <span className="text-tono-text">— copy, send.</span>
              </div>
              <div className="mt-8 flex flex-col sm:flex-row gap-3">
                <ProCheckoutButton
                  interval="month"
                  label="start 7-day free trial"
                  className="inline-flex items-center justify-center gap-2 px-6 py-3.5 rounded-[12px] bg-tono-accent hover:bg-tono-accent-hover disabled:opacity-60 disabled:pointer-events-none text-white font-semibold transition shadow-[0_8px_32px_rgba(168,85,247,0.30)] min-h-[48px]"
                >
                  start 7-day free trial
                  <ArrowIcon />
                </ProCheckoutButton>
                <a
                  href="#pricing"
                  className="inline-flex items-center justify-center gap-2 px-5 py-3.5 rounded-[12px] bg-tono-bg-card border border-tono-accent/40 text-tono-text hover:border-tono-accent font-semibold transition min-h-[48px] text-[15px]"
                >
                  see pricing →
                </a>
                <a
                  href="#try-tono"
                  className="inline-flex items-center justify-center gap-2 px-5 py-3.5 rounded-[12px] bg-transparent text-tono-text-soft hover:text-tono-text font-semibold transition min-h-[48px] text-[15px] underline-offset-4 hover:underline hidden sm:inline-flex"
                >
                  try the demo →
                </a>
              </div>
              <p className="text-xs text-tono-muted mt-4">
                7-day free trial. then $3.99/mo or $39.99/yr. cancel anytime.
              </p>
            </div>

            {/* ── Inline demo — the actual working paste → rewrite tool ──
                Real client component, hits POST /api/analyze. Replaces
                the static phone-frame screenshot from the previous
                build so the above-the-fold experience is honest.
                `id="try-tono"` is the anchor target for the hero CTA — the
                demo is the actual hook, not the /login wall. */}
            <aside id="try-tono" className="relative scroll-mt-32">
              <TonoDemo />
            </aside>
          </div>
        </div>
      </section>

      {/* ── How it works ─────────────────────────────────────────────── */}
      <section id="how" className="border-t border-tono-border bg-tono-bg-soft">
        <div className="max-w-[1180px] mx-auto px-6 md:px-10 py-20 md:py-24">
          <div className="mb-10 max-w-2xl">
            <span className="text-[11px] uppercase tracking-wider font-semibold text-tono-accent-light">how it works</span>
            <h2 className="text-[32px] md:text-[40px] font-bold tracking-[-0.02em] text-tono-text mt-3">
              three steps. ten seconds.
            </h2>
          </div>
          <ol className="grid md:grid-cols-3 gap-5">
            {[
              {
                n: '1',
                title: 'paste the draft',
                body: 'copy the email, slack message, or doc paragraph you need to rework. the composer holds it locally until you rewrite.',
              },
              {
                n: '2',
                title: 'pick a tone',
                body: 'tono rewrites it four ways — warmer, clearer, funnier, safer. each one is named, colored, and ready to copy.',
              },
              {
                n: '3',
                title: 'copy, send, done',
                body: 'one tap copies the rewrite. your draft is sent only when you choose rewrite — tono never sends a message on your behalf.',
              },
            ].map((s) => (
              <li key={s.n} className="bg-tono-bg-card border border-tono-border rounded-[18px] p-6">
                <span
                  aria-hidden="true"
                  className="w-9 h-9 rounded-full bg-tono-accent-soft text-tono-accent-light font-bold text-[15px] grid place-items-center border border-tono-accent/40"
                >
                  {s.n}
                </span>
                <h3 className="text-[17px] font-semibold text-tono-text mt-4 tracking-[-0.01em]">{s.title}</h3>
                <p className="text-[14px] text-tono-text-soft leading-[1.6] mt-2">{s.body}</p>
              </li>
            ))}
          </ol>
        </div>
      </section>

      {/* ── Tones — concrete grid, no abstract promises ──────────────── */}
      <section className="border-t border-tono-border">
        <div className="max-w-[1180px] mx-auto px-6 md:px-10 py-20 md:py-24">
          <div className="mb-10 max-w-2xl">
            <span className="text-[11px] uppercase tracking-wider font-semibold text-tono-accent-light">the four tones</span>
            <h2 className="text-[32px] md:text-[40px] font-bold tracking-[-0.02em] text-tono-text mt-3">
              meet the four tones
            </h2>
            <p className="text-[15px] text-tono-text-soft leading-[1.6] mt-3 max-w-2xl">
              every rewrite gets all four. you pick the one that fits the moment — not the one the model happens to like.
            </p>
          </div>
          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
            {[
              { name: 'warmer', sub: 'soften the edge.', body: '“can we find a time that works for both of us?”', cls: 'tone-rule-t-warmer' },
              { name: 'clearer', sub: 'cut the noise.', body: '“please send the final draft by friday.”', cls: 'tone-rule-t-clearer' },
              { name: 'funnier', sub: 'loosen the grip.', body: '“the spreadsheet has entered its villain era.”', cls: 'tone-rule-t-funnier' },
              { name: 'safer', sub: 'pull the spike.', body: '“i see this differently — can we compare notes?”', cls: 'tone-rule-t-safer' },
            ].map((t) => (
              <article
                key={t.name}
                className={`bg-tono-bg-card border border-tono-border rounded-[18px] p-5 hover:border-tono-border-strong transition ${t.cls}`}
              >
                <div className="flex items-center gap-2">
                  <span className={`w-2.5 h-2.5 rounded-full tone-dot-${t.name}`} aria-hidden="true" />
                  <span className="text-[15px] font-semibold text-tono-text">{t.name}</span>
                </div>
                <p className="text-[13px] text-tono-text-softer mt-1.5 font-medium">{t.sub}</p>
                <p className="text-[13px] text-tono-text-soft leading-[1.6] mt-3">{t.body}</p>
              </article>
            ))}
          </div>
        </div>
      </section>

      {/* ── Pricing — Trial vs Pro, what's actually in each ─────────── */}
      <section id="pricing" className="border-t border-tono-border bg-tono-bg">
        <div className="max-w-[1080px] mx-auto px-6 md:px-10 py-20 md:py-24">
          <div className="mb-10 max-w-2xl">
            <span className="text-[11px] uppercase tracking-wider font-semibold text-tono-accent-light">pricing</span>
            <h2 className="text-[32px] md:text-[40px] font-bold tracking-[-0.02em] text-tono-text mt-3">
              free for 7 days. pro when you rewrite all day.
            </h2>
          </div>
          <div className="grid grid-cols-1 md:grid-cols-2 gap-5">
            {/* Trial — the first seven days of a paid subscription */}
            <article className="bg-tono-bg-card border border-tono-border rounded-[18px] p-7 flex flex-col">
              <p className="text-[11px] uppercase tracking-wider font-semibold text-tono-text-softer">free for 7 days</p>
              <p className="text-[36px] md:text-[40px] font-bold tracking-[-0.02em] text-tono-text mt-2">
                $0
                <span className="text-[15px] font-normal text-tono-text-softer ml-2">first 7 days</span>
              </p>
              <p className="text-[14px] text-tono-text-soft leading-[1.55] mt-3">
                start a real trial. we'll never charge until day 8.
              </p>
              <ul className="mt-6 space-y-2.5 text-[14px] text-tono-text-soft">
                <li className="flex gap-2"><span className="text-tono-tone-safer font-semibold">✓</span><span>no charge until day 8</span></li>
                <li className="flex gap-2"><span className="text-tono-tone-safer font-semibold">✓</span><span>drafts are sent only when you choose rewrite</span></li>
                <li className="flex gap-2"><span className="text-tono-tone-safer font-semibold">✓</span><span>nothing about your writing trains anything</span></li>
                <li className="flex gap-2"><span className="text-tono-tone-safer font-semibold">✓</span><span>cancel anytime during the trial</span></li>
              </ul>
              <ProCheckoutButton
                interval="month"
                label="start 7-day free trial"
                className="mt-8 inline-flex items-center justify-center gap-2 px-5 py-3 rounded-[12px] bg-transparent border border-tono-border-strong text-tono-text hover:border-tono-accent disabled:opacity-60 disabled:pointer-events-none font-semibold transition min-h-[44px] text-[14px]"
              >
                start 7-day free trial
              </ProCheckoutButton>
            </article>

            {/* Pro tier — wired to Stripe Checkout via /api/checkout */}
            <article
              className="bg-tono-bg-card border border-tono-accent/40 rounded-[18px] p-7 flex flex-col relative shadow-[0_8px_32px_rgba(168,85,247,0.18)]"
            >
              <span className="absolute -top-3 right-5 inline-flex items-center gap-1 px-3 py-1 rounded-full bg-tono-accent text-white text-[10px] font-semibold uppercase tracking-wider">
                tono pro
              </span>
              <p className="text-[11px] uppercase tracking-wider font-semibold text-tono-accent-light">pro</p>
              <p className="text-[36px] md:text-[40px] font-bold tracking-[-0.02em] text-tono-text mt-2">
                $3.99
                <span className="text-[15px] font-normal text-tono-text-softer ml-2">
                  / month
                </span>
              </p>
            <p className="text-[14px] text-tono-text-soft leading-[1.55] mt-3">
              for the people who write to be read all day.
            </p>
              <ul className="mt-6 space-y-2.5 text-[14px] text-tono-text-soft">
                <li className="flex gap-2"><span className="text-tono-tone-safer font-semibold">✓</span><span><strong className="text-tono-text font-semibold">unlimited rewrites</strong> on the web composer</span></li>
                <li className="flex gap-2"><span className="text-tono-tone-safer font-semibold">✓</span><span>local history of your last 50 rewrites</span></li>
                <li className="flex gap-2"><span className="text-tono-tone-safer font-semibold">✓</span><span>priority on the rewrite queue — no cold-start</span></li>
                <li className="flex gap-2"><span className="text-tono-tone-safer font-semibold">✓</span><span>cancel anytime — no retention, no dark patterns</span></li>
              </ul>
              <div className="mt-8 flex flex-col sm:flex-row gap-3">
                <ProCheckoutButton
                  interval="month"
                  label="go pro — $3.99/mo"
                >
                  go pro — $3.99/mo
                  <ArrowIcon />
                </ProCheckoutButton>
                <ProCheckoutButton
                  interval="year"
                  label="go pro — $39.99/yr · save $7.89"
                  className="inline-flex items-center justify-center gap-2 px-5 py-3 rounded-[12px] bg-transparent border border-tono-border-strong text-tono-text hover:border-tono-accent disabled:opacity-60 disabled:pointer-events-none font-semibold transition min-h-[44px] text-[14px] min-w-0 max-w-full text-center whitespace-normal leading-snug"
                >
                  go pro — $39.99/yr · save $7.89
                </ProCheckoutButton>
              </div>
            </article>
          </div>
          <p className="text-center text-[13px] text-tono-text-softer mt-8">
            subscriptions auto-renew at $3.99/mo or $39.99/yr after the 7-day trial unless cancelled. billed monthly or yearly. cancel from your inbox.
          </p>
        </div>
      </section>

      {/* ── Privacy / local-only — concrete claim, not marketing fluff ── */}
      <section className="border-t border-tono-border bg-tono-bg-soft">
        <div className="max-w-[860px] mx-auto px-6 md:px-10 py-16 md:py-20 text-center">
          <span className="inline-flex items-center gap-2 px-3 py-1 rounded-full bg-tono-accent-soft text-tono-accent-light text-[11px] font-semibold uppercase tracking-wider border border-tono-accent/30">
            <span className="w-1.5 h-1.5 rounded-full bg-tono-tone-safer" aria-hidden="true" />
            privacy
          </span>
          <h2 className="text-[28px] md:text-[40px] font-bold tracking-[-0.02em] text-tono-text mt-5 leading-[1.1]">
            your drafts stay yours.
          </h2>
          <div className="mt-5 space-y-3 text-[15px] md:text-[16px] text-tono-text-soft leading-[1.65] max-w-2xl mx-auto">
            <p>
              the demo works without an account. when you choose rewrite, your draft is sent securely to tono's rewrite service.
            </p>
            <p>
              signed-in users get unlimited rewrites and a local history of the last 50 rewrites. tono never sends messages on your behalf, and your writing is not used to train anything.
            </p>
          </div>
          <ul className="mt-8 flex flex-wrap items-center justify-center gap-x-6 gap-y-2 text-[12px] uppercase tracking-[0.14em] font-semibold text-tono-text-softer">
            <li className="flex items-center gap-2"><span className="w-1.5 h-1.5 rounded-full bg-tono-tone-safer" aria-hidden="true" />no account for the demo</li>
            <li className="flex items-center gap-2"><span className="w-1.5 h-1.5 rounded-full bg-tono-tone-safer" aria-hidden="true" />sent only when you rewrite</li>
            <li className="flex items-center gap-2"><span className="w-1.5 h-1.5 rounded-full bg-tono-tone-safer" aria-hidden="true" />no training on your writing</li>
          </ul>
        </div>
      </section>

      {/* ── Final CTA ────────────────────────────────────────────────── */}
      <section className="border-t border-tono-border">
        <div className="max-w-[860px] mx-auto px-6 md:px-10 py-20 md:py-24 text-center">
          <h2 className="text-[32px] md:text-[44px] font-bold tracking-[-0.02em] text-tono-text">
            ready to start your trial?
          </h2>
          <p className="text-[16px] text-tono-text-soft leading-[1.6] mt-4 max-w-xl mx-auto">
            7-day free trial. then $3.99/mo or $39.99/yr. cancel anytime.
          </p>
          <div className="mt-8 flex flex-col sm:flex-row gap-3 items-center justify-center">
            <ProCheckoutButton
              interval="month"
              label="start 7-day free trial"
              className="inline-flex items-center justify-center gap-2 px-6 py-3.5 rounded-[12px] bg-tono-accent hover:bg-tono-accent-hover disabled:opacity-60 disabled:pointer-events-none text-white font-semibold transition shadow-[0_8px_32px_rgba(168,85,247,0.30)] min-h-[48px]"
            >
              start 7-day free trial
              <ArrowIcon />
            </ProCheckoutButton>
            <a
              href="mailto:hi@tonoit.com?subject=tono%20feedback"
              className="inline-flex items-center justify-center gap-2 px-6 py-3.5 rounded-[12px] bg-transparent text-tono-text-soft hover:text-tono-text font-semibold transition min-h-[48px]"
            >
              send feedback
            </a>
          </div>
        </div>
      </section>

      {/* Footer is rendered in the root layout so it ships on every page. */}
    </main>
  );
}

// ── TonoNav ─────────────────────────────────────────────────────────────
// Brand wordmark on the left; top-right dropdown lives in the global
// layout (NavDropdown.tsx — present on every page per nav-spec.md).
// The wordmark stays here so the chrome reads as a header on the
// landing page, but it no longer carries inline links.
function TonoNav() {
  return (
    <header className="sticky top-0 z-30 bg-tono-bg/80 backdrop-blur-md border-b border-tono-border">
      <div className="max-w-[1180px] mx-auto px-6 md:px-10 py-4 flex items-center justify-between">
        <Link
          href="/"
          className="flex items-center gap-2.5 shrink-0"
          aria-label="tono — back to home"
        >
          <span
            aria-hidden="true"
            className="w-3 h-3 rounded-full bg-tono-accent shadow-[0_0_16px_var(--accent-glow)]"
          />
          <span className="text-[22px] font-bold tracking-[-0.02em] text-tono-text">tono</span>
        </Link>
      </div>
    </header>
  )
}

// ── ToneChip ────────────────────────────────────────────────────────────
// Compact tone preview for the hero demo card. Single-column list inside
// the iOS phone screen so the demo reads finished on mobile too. The
// tone name drives a class suffix — never an inline color literal.
function ToneChip({ name, text }: { name: 'warmer' | 'clearer' | 'funnier' | 'safer'; text: string }) {
  const rule = `tone-rule-l-${name}`
  const dot = `tone-dot-sm-${name}`
  return (
    <div
      className={`bg-tono-bg-elev border border-tono-border rounded-[10px] p-2.5 hover:border-tono-border-strong transition ${rule}`}
    >
      <div className="flex items-center gap-1.5 mb-1">
        <span className={`w-1.5 h-1.5 rounded-full ${dot}`} aria-hidden="true" />
        <span className={`text-[10px] font-semibold tracking-[0.04em] uppercase tone-text-${name}`}>{name}</span>
      </div>
      <p className="text-[12px] text-tono-text-soft leading-[1.45]">{text}</p>
    </div>
  )
}

function ArrowIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M5 12h14M13 5l7 7-7 7" />
    </svg>
  );
}
