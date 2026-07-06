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

import Link from 'next/link';

// ── Server component — no client state needed. ──────────────────────────
export default function LandingPage() {
  return (
    <main className="min-h-screen bg-tono-bg text-tono-text font-sans antialiased">
      <TonoNav />

      {/* ── Hero ──────────────────────────────────────────────────────── */}
      <section className="relative">
        {/* ambient backdrop — already in body globals, no extra div needed */}
        <div className="max-w-[1180px] mx-auto px-6 md:px-10 pt-20 md:pt-28 pb-16 md:pb-24">
          <div className="grid lg:grid-cols-[1.15fr_1fr] gap-12 lg:gap-16 items-center">
            <div>
              <span className="inline-flex items-center gap-2 px-3 py-1 rounded-full bg-tono-accent-soft text-tono-accent-light text-[11px] font-semibold uppercase tracking-wider border border-tono-accent/30">
                <span className="w-1.5 h-1.5 rounded-full bg-tono-accent shadow-[0_0_8px_var(--accent-glow)]" />
                now in public beta
              </span>
              <h1 className="text-[44px] md:text-[60px] leading-[1.05] font-bold tracking-[-0.025em] text-tono-text mt-6">
                <em className="not-italic text-tono-accent-light">say what you mean.</em>
              </h1>
              <p className="text-lg md:text-xl text-tono-text-soft leading-[1.55] mt-5 max-w-xl">
                paste a draft. tono hands you four ways to say it —{' '}
                <span className="text-[#F472B6]">warmer</span>,{' '}
                <span className="text-[#38BDF8]">clearer</span>,{' '}
                <span className="text-[#FBBF24]">funnier</span>,{' '}
                <span className="text-[#34D399]">safer</span>{' '}
                — pick one, copy, send.
              </p>
              <div className="mt-8 flex flex-col sm:flex-row gap-3">
                <Link
                  href="/app/login"
                  className="inline-flex items-center justify-center gap-2 px-6 py-3.5 rounded-[12px] bg-tono-accent hover:bg-tono-accent-hover text-white font-semibold transition shadow-[0_8px_32px_rgba(168,85,247,0.30)] min-h-[48px]"
                >
                  try tono free
                  <ArrowIcon />
                </Link>
                <a
                  href="#how"
                  className="inline-flex items-center justify-center gap-2 px-6 py-3.5 rounded-[12px] bg-tono-bg-elev hover:bg-tono-bg-card text-tono-text border border-tono-border hover:border-tono-border-strong font-semibold transition min-h-[48px]"
                >
                  see how it works
                </a>
              </div>
              <p className="text-xs text-tono-muted mt-4">
                free tier — 3 rewrites a day. no credit card.
              </p>
            </div>

            {/* ── Inline demo card — concrete artifact, not abstract promise ── */}
            <aside
              aria-label="tono editor preview"
              className="bg-tono-bg-card border border-tono-border rounded-[18px] p-6 shadow-[0_24px_64px_rgba(0,0,0,0.5)]"
            >
              <div className="flex items-center justify-between mb-4">
                <div className="flex items-center gap-2">
                  <span className="w-2 h-2 rounded-full bg-tono-accent shadow-[0_0_8px_var(--accent-glow)]" />
                  <span className="text-[12px] font-semibold tracking-[0.04em] text-tono-text">tono</span>
                </div>
                <span className="text-[11px] text-tono-muted font-mono lowercase">draft</span>
              </div>

              <p className="text-[13px] text-tono-text-softer mb-2 font-semibold tracking-wider uppercase">your draft</p>
              <p className="text-[15px] text-tono-text leading-[1.55] mb-5">
                "Q3 timeline keeps slipping. I need the design files by Friday or we are missing the launch."
              </p>

              <p className="text-[13px] text-tono-text-softer mb-2 font-semibold tracking-wider uppercase">four ways to say it</p>
              <div className="grid grid-cols-1 sm:grid-cols-2 gap-2">
                <ToneChip color="#F472B6" label="warmer" text="Hey — totally hear the urgency. Could we get the design files by Friday? Without them we're at risk of slipping past the launch window." />
                <ToneChip color="#38BDF8" label="clearer" text="The Q3 launch depends on design files arriving by Friday. Can you confirm whether that deadline is feasible?" />
                <ToneChip color="#FBBF24" label="funnier" text="Design files by Friday or we are all attending the post-launch pizza party in our PJs. No pressure." />
                <ToneChip color="#34D399" label="safer" text="Friendly nudge on the design files — Friday is the launch cutoff. Happy to scope the ask if you need a different target." />
              </div>
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
                body: 'one tap copies the rewrite. paste it into slack, email, or anywhere. nothing leaves your browser unless you copy it.',
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
              named in the copy. colored on the screen.
            </h2>
            <p className="text-[15px] text-tono-text-soft leading-[1.6] mt-3 max-w-2xl">
              every rewrite gets all four. you pick the one that fits the moment — not the one the model happens to like.
            </p>
          </div>
          <div className="grid sm:grid-cols-2 lg:grid-cols-4 gap-4">
            {[
              { color: '#F472B6', name: 'warmer', sub: 'soften the edge.', body: 'for the messages that need to land human. the difficult conversation. the ask that already sounds pushy in your head.' },
              { color: '#38BDF8', name: 'clearer', sub: 'cut the noise.', body: 'for the updates that get ignored. the status emails that read like riddles. the meeting invites that bury the ask.' },
              { color: '#FBBF24', name: 'funnier', sub: 'loosen the grip.', body: 'for the messages that don\'t need to be formal. the slack reply. the introduction. the all-hands slide that nobody is awake for.' },
              { color: '#34D399', name: 'safer', sub: 'pull the spike.', body: 'for the messages you wrote angry, or tired, or both. the post-incident note. the reply-all you almost sent.' },
            ].map((t) => (
              <article
                key={t.name}
                className="bg-tono-bg-card border border-tono-border rounded-[18px] p-5 hover:border-tono-border-strong transition"
                style={{ borderTopColor: t.color, borderTopWidth: '2px' }}
              >
                <div className="flex items-center gap-2">
                  <span className="w-2.5 h-2.5 rounded-full" style={{ background: t.color, boxShadow: `0 0 12px ${t.color}80` }} aria-hidden="true" />
                  <span className="text-[15px] font-semibold text-tono-text">{t.name}</span>
                </div>
                <p className="text-[13px] text-tono-text-softer mt-1.5 font-medium">{t.sub}</p>
                <p className="text-[13px] text-tono-text-soft leading-[1.6] mt-3">{t.body}</p>
              </article>
            ))}
          </div>
        </div>
      </section>

      {/* ── Privacy / local-only — concrete claim, not marketing fluff ── */}
      <section className="border-t border-tono-border bg-tono-bg-soft">
        <div className="max-w-[1180px] mx-auto px-6 md:px-10 py-16 md:py-20">
          <div className="bg-tono-bg-card border border-tono-border rounded-[18px] p-8 md:p-10 grid md:grid-cols-[1fr_2fr] gap-8 items-center">
            <div>
              <span className="text-[11px] uppercase tracking-wider font-semibold text-tono-accent-light">privacy</span>
              <h2 className="text-[24px] md:text-[28px] font-bold tracking-[-0.02em] text-tono-text mt-3">
                your drafts stay yours.
              </h2>
            </div>
            <div className="space-y-3 text-[14px] text-tono-text-soft leading-[1.65]">
              <p>
                tono's free tier rewrites without signing you in. drafts sit in your browser only — we don't have a server-side copy.
              </p>
              <p>
                signed-in users get a daily rewrite quota and a local history of the last 50 rewrites. nothing about your writing is used to train anything.
              </p>
            </div>
          </div>
        </div>
      </section>

      {/* ── Final CTA ────────────────────────────────────────────────── */}
      <section className="border-t border-tono-border">
        <div className="max-w-[860px] mx-auto px-6 md:px-10 py-20 md:py-24 text-center">
          <h2 className="text-[32px] md:text-[44px] font-bold tracking-[-0.02em] text-tono-text">
            four ways to say it. <em className="not-italic text-tono-accent-light">try tono.</em>
          </h2>
          <p className="text-[16px] text-tono-text-soft leading-[1.6] mt-4 max-w-xl mx-auto">
            free tier — 3 rewrites a day, no credit card. sign in with apple, google, or email.
          </p>
          <div className="mt-8 flex flex-col sm:flex-row gap-3 items-center justify-center">
            <Link
              href="/app/login"
              className="inline-flex items-center justify-center gap-2 px-6 py-3.5 rounded-[12px] bg-tono-accent hover:bg-tono-accent-hover text-white font-semibold transition shadow-[0_8px_32px_rgba(168,85,247,0.30)] min-h-[48px]"
            >
              open tono
              <ArrowIcon />
            </Link>
            <a
              href="mailto:hi@tonoit.com?subject=tono%20feedback"
              className="inline-flex items-center justify-center gap-2 px-6 py-3.5 rounded-[12px] bg-transparent text-tono-text-soft hover:text-tono-text font-semibold transition min-h-[48px]"
            >
              send feedback
            </a>
          </div>
        </div>
      </section>

      <TonoFooter />
    </main>
  );
}

// ── TonoNav ─────────────────────────────────────────────────────────────
// Shared nav for tono public surfaces. Wordmark is prominent: 22px Inter
// SemiBold with a glowing accent dot. Brand-voice: lowercase.
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
        <nav className="flex items-center gap-2 sm:gap-4 text-[14px] font-medium">
          <a
            href="#how"
            className="text-tono-text-soft hover:text-tono-text transition min-h-[44px] flex items-center px-2"
          >
            how it works
          </a>
          <a
            href="mailto:hi@tonoit.com?subject=tono%20feedback"
            className="text-tono-text-soft hover:text-tono-text transition min-h-[44px] hidden sm:flex items-center px-2"
          >
            contact
          </a>
          <Link
            href="/app/login"
            className="inline-flex items-center justify-center gap-2 px-4 py-2.5 rounded-[10px] bg-tono-accent hover:bg-tono-accent-hover text-white font-semibold transition min-h-[44px]"
          >
            sign in
          </Link>
        </nav>
      </div>
    </header>
  );
}

// ── TonoFooter ──────────────────────────────────────────────────────────
function TonoFooter() {
  return (
    <footer className="border-t border-tono-border bg-tono-bg-soft">
      <div className="max-w-[1180px] mx-auto px-6 md:px-10 py-10 grid sm:grid-cols-[1.4fr_1fr_1fr] gap-8">
        <div>
          <div className="flex items-center gap-2.5">
            <span aria-hidden="true" className="w-2.5 h-2.5 rounded-full bg-tono-accent shadow-[0_0_10px_var(--accent-glow)]" />
            <span className="text-[16px] font-bold tracking-[-0.02em] text-tono-text">tono</span>
          </div>
          <p className="text-[13px] text-tono-text-soft leading-[1.6] mt-3 max-w-sm">
            <em className="not-italic text-tono-text">say what you mean.</em> four ways to say it.
          </p>
        </div>
        <div>
          <p className="text-[11px] uppercase tracking-wider font-semibold text-tono-text-softer mb-3">product</p>
          <ul className="space-y-2 text-[13px]">
            <li><a href="#how" className="text-tono-text-soft hover:text-tono-text transition">how it works</a></li>
            <li><a href="/app/login" className="text-tono-text-soft hover:text-tono-text transition">sign in</a></li>
            <li><a href="mailto:hi@tonoit.com?subject=tono%20feedback" className="text-tono-text-soft hover:text-tono-text transition">feedback</a></li>
          </ul>
        </div>
        <div>
          <p className="text-[11px] uppercase tracking-wider font-semibold text-tono-text-softer mb-3">legal</p>
          <ul className="space-y-2 text-[13px]">
            <li><a href="mailto:hi@tonoit.com?subject=tono%20privacy" className="text-tono-text-soft hover:text-tono-text transition">privacy</a></li>
            <li><a href="mailto:hi@tonoit.com?subject=tono%20terms" className="text-tono-text-soft hover:text-tono-text transition">terms</a></li>
          </ul>
        </div>
      </div>
      <div className="border-t border-tono-border">
        <div className="max-w-[1180px] mx-auto px-6 md:px-10 py-4 flex flex-col sm:flex-row items-start sm:items-center justify-between gap-2">
          <p className="text-[11px] text-tono-muted">© {new Date().getFullYear()} tono. all rights reserved.</p>
          <p className="text-[11px] text-tono-muted">drafts stay in your browser. nothing leaves unless you copy it.</p>
        </div>
      </div>
    </footer>
  );
}

// ── ToneChip ────────────────────────────────────────────────────────────
// Compact tone preview for the hero demo card. Lowercase label, dot +
// color matching the live editor (warmer/clearer/funnier/safer).
function ToneChip({ color, label, text }: { color: string; label: string; text: string }) {
  return (
    <div className="bg-tono-bg-elev border border-tono-border rounded-[12px] p-3 hover:border-tono-border-strong transition"
         style={{ borderLeft: `2px solid ${color}` }}>
      <div className="flex items-center gap-1.5 mb-1.5">
        <span className="w-1.5 h-1.5 rounded-full" style={{ background: color, boxShadow: `0 0 6px ${color}80` }} aria-hidden="true" />
        <span className="text-[11px] font-semibold tracking-wide" style={{ color }}>{label}</span>
      </div>
      <p className="text-[12px] text-tono-text-soft leading-[1.5] line-clamp-3">{text}</p>
    </div>
  );
}

function ArrowIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M5 12h14M13 5l7 7-7 7" />
    </svg>
  );
}
