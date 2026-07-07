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
        <div className="max-w-[1180px] mx-auto px-5 sm:px-6 md:px-10 pt-14 sm:pt-20 md:pt-28 pb-12 sm:pb-16 md:pb-24">
          <div className="grid lg:grid-cols-[1.1fr_1fr] gap-10 lg:gap-14 items-center">
            <div>
              <span className="inline-flex items-center gap-2 px-3 py-1 rounded-full bg-tono-accent-soft text-tono-accent-light text-[11px] font-semibold uppercase tracking-wider border border-tono-accent/30">
                <span className="w-1.5 h-1.5 rounded-full bg-tono-accent shadow-[0_0_8px_var(--accent-glow)]" />
                now in public beta · ios keyboard
              </span>
              <p className="text-[12px] md:text-[14px] text-tono-text-softer uppercase tracking-[0.14em] font-semibold mt-4 sm:mt-5">
                For sales, ops, eng, and anyone who writes to be read.
              </p>
              <h1 className="text-[36px] sm:text-[44px] md:text-[60px] leading-[1.05] md:leading-[1.02] font-bold tracking-[-0.025em] text-tono-text mt-2 sm:mt-3">
                paste a draft.{' '}
                <em className="not-italic text-tono-accent-light">get four ways to say it.</em>
              </h1>
              <div className="mt-5 flex flex-wrap items-center gap-x-3 gap-y-2 text-[15px] md:text-[16px] text-tono-text-soft leading-[1.5]">
                <span className="text-tono-text-softer">pick one —</span>
                <span className="inline-flex items-center gap-1.5 px-2 py-1 rounded-[8px] bg-[#F472B6]/10 text-[#F472B6] font-semibold text-[13px]">warmer</span>
                <span className="inline-flex items-center gap-1.5 px-2 py-1 rounded-[8px] bg-[#38BDF8]/10 text-[#38BDF8] font-semibold text-[13px]">clearer</span>
                <span className="inline-flex items-center gap-1.5 px-2 py-1 rounded-[8px] bg-[#FBBF24]/10 text-[#FBBF24] font-semibold text-[13px]">funnier</span>
                <span className="inline-flex items-center gap-1.5 px-2 py-1 rounded-[8px] bg-[#34D399]/10 text-[#34D399] font-semibold text-[13px]">safer</span>
                <span className="text-tono-text">— copy, send.</span>
              </div>
              <div className="mt-8 flex flex-col sm:flex-row gap-3">
                <Link
                  href="/login"
                  className="inline-flex items-center justify-center gap-2 px-6 py-3.5 rounded-[12px] bg-tono-accent hover:bg-tono-accent-hover text-white font-semibold transition shadow-[0_8px_32px_rgba(168,85,247,0.30)] min-h-[48px]"
                >
                  try tono free
                  <ArrowIcon />
                </Link>
                <a
                  href="#how"
                  className="inline-flex items-center justify-center gap-2 px-5 py-3.5 rounded-[12px] bg-transparent text-tono-text-soft hover:text-tono-text font-semibold transition min-h-[48px] text-[15px] underline-offset-4 hover:underline"
                >
                  see how it works
                </a>
              </div>
              <p className="text-xs text-tono-muted mt-4">
                free tier — 3 rewrites a day. no credit card. no sign-in required.
              </p>
            </div>

            {/* ── Inline demo — iOS phone frame, real keyboard surface, not nested cards ── */}
            <aside
              aria-label="tono iOS keyboard preview"
              className="relative"
            >
              {/* soft glow behind the phone */}
              <div
                aria-hidden="true"
                className="absolute -inset-6 rounded-[44px] bg-tono-accent/10 blur-2xl pointer-events-none"
              />
              {/* phone bezel */}
              <div className="relative rounded-[40px] bg-[#1A1A1F] p-3 shadow-[0_24px_64px_rgba(0,0,0,0.55)] border border-[#2A2A30]">
                {/* dynamic-island / status bar */}
                <div className="flex items-center justify-between px-5 pt-2 pb-3">
                  <span className="text-[10px] font-mono font-semibold text-tono-text">9:41</span>
                  <div className="w-20 h-5 rounded-full bg-black" aria-hidden="true" />
                  <div className="flex items-center gap-1 text-tono-text" aria-hidden="true">
                    <svg width="13" height="9" viewBox="0 0 13 9" fill="currentColor"><rect x="0" y="6" width="2" height="3" rx="0.5"/><rect x="3.5" y="4" width="2" height="5" rx="0.5"/><rect x="7" y="2" width="2" height="7" rx="0.5"/><rect x="10.5" y="0" width="2" height="9" rx="0.5"/></svg>
                    <svg width="14" height="9" viewBox="0 0 14 9" fill="none" stroke="currentColor" strokeWidth="1.2"><rect x="0.6" y="0.6" width="11" height="7.8" rx="1.4"/><rect x="12.4" y="3" width="1.4" height="3" fill="currentColor"/></svg>
                  </div>
                </div>
                {/* screen surface — the keyboard */}
                <div className="rounded-[28px] bg-tono-bg-card border border-tono-border overflow-hidden">
                  {/* composer — pasted draft */}
                  <div className="px-4 pt-5 pb-3 border-b border-tono-border">
                    <div className="flex items-center gap-2 mb-2">
                      <span className="w-1.5 h-1.5 rounded-full bg-tono-accent shadow-[0_0_8px_var(--accent-glow)]" />
                      <span className="text-[10px] font-semibold tracking-[0.06em] text-tono-text uppercase">tono · draft</span>
                    </div>
                    <p className="text-[13px] sm:text-[14px] text-tono-text-soft leading-[1.5] italic">
                      &ldquo;Q3 timeline keeps slipping. I need the design files by Friday or we are missing the launch.&rdquo;
                    </p>
                  </div>
                  {/* four tone rewriters */}
                  <div className="px-2.5 py-2 space-y-1.5">
                    <ToneChip color="#F472B6" label="warmer" text="Hey — totally hear the urgency. Could we get the design files by Friday? Without them we're at risk of slipping past the launch window." />
                    <ToneChip color="#38BDF8" label="clearer" text="The Q3 launch depends on design files arriving by Friday. Can you confirm whether that deadline is feasible?" />
                    <ToneChip color="#FBBF24" label="funnier" text="Design files by Friday or we are all attending the post-launch pizza party in our PJs. No pressure." />
                    <ToneChip color="#34D399" label="safer" text="Friendly nudge on the design files — Friday is the launch cutoff. Happy to scope the ask if you need a different target." />
                  </div>
                  {/* keyboard hint footer */}
                  <div className="flex items-center justify-between px-4 py-2.5 bg-tono-bg border-t border-tono-border">
                    <span className="text-[10px] font-mono lowercase text-tono-muted">tap any → copy</span>
                    <span className="text-[10px] font-mono lowercase text-tono-accent-light">↩︎ send</span>
                  </div>
                </div>
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
              tono's free tier rewrites without signing you in. drafts sit in your browser only — we don't have a server-side copy.
            </p>
            <p>
              signed-in users get a daily rewrite quota and a local history of the last 50 rewrites. nothing about your writing is used to train anything.
            </p>
          </div>
          <ul className="mt-8 flex flex-wrap items-center justify-center gap-x-6 gap-y-2 text-[12px] uppercase tracking-[0.14em] font-semibold text-tono-text-softer">
            <li className="flex items-center gap-2"><span className="w-1.5 h-1.5 rounded-full bg-tono-tone-safer" aria-hidden="true" />no login required</li>
            <li className="flex items-center gap-2"><span className="w-1.5 h-1.5 rounded-full bg-tono-tone-safer" aria-hidden="true" />no server-side copy</li>
            <li className="flex items-center gap-2"><span className="w-1.5 h-1.5 rounded-full bg-tono-tone-safer" aria-hidden="true" />no training on your writing</li>
          </ul>
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
              href="/login"
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
            href="/login"
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
            <li><Link href="/login" className="text-tono-text-soft hover:text-tono-text transition">sign in</Link></li>
            <li><a href="mailto:hi@tonoit.com?subject=tono%20feedback" className="text-tono-text-soft hover:text-tono-text transition">feedback</a></li>
          </ul>
        </div>
        <div>
          <p className="text-[11px] uppercase tracking-wider font-semibold text-tono-text-softer mb-3">legal</p>
          <ul className="space-y-2 text-[13px]">
            <li><Link href="/privacy" className="text-tono-text-soft hover:text-tono-text transition">privacy</Link></li>
            <li><Link href="/terms" className="text-tono-text-soft hover:text-tono-text transition">terms</Link></li>
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
// Compact tone preview for the hero demo card. Single-column list inside
// the iOS phone screen so the demo reads finished on mobile too. Border-
// left in tone color, label + dot in tone color.
function ToneChip({ color, label, text }: { color: string; label: string; text: string }) {
  return (
    <div
      className="bg-tono-bg-elev border border-tono-border rounded-[10px] p-2.5 hover:border-tono-border-strong transition"
      style={{ borderLeft: `2px solid ${color}` }}
    >
      <div className="flex items-center gap-1.5 mb-1">
        <span className="w-1.5 h-1.5 rounded-full" style={{ background: color, boxShadow: `0 0 6px ${color}80` }} aria-hidden="true" />
        <span className="text-[10px] font-semibold tracking-[0.04em] uppercase" style={{ color }}>{label}</span>
      </div>
      <p className="text-[12px] text-tono-text-soft leading-[1.45]">{text}</p>
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
