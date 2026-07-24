import Link from 'next/link'
import CampaignVideos from './CampaignVideos'
import ProCheckoutButton from './ProCheckoutButton'
import TonoBrand from './TonoBrand'

const heroRewrites = [
  {
    tone: 'warmer',
    text: 'Hey — could you send the final version by EOD? I know you’re juggling a lot, and I need it to close this out.',
  },
  {
    tone: 'clearer',
    text: 'Could you send the final version by EOD? I need it to close this out.',
  },
  {
    tone: 'safer',
    text: 'Could you send the final version by EOD? If that timing doesn’t work, please tell me what does.',
  },
] as const

const steps = [
  ['write what you mean', 'Your original stays visible.'],
  ['compare the landing', 'See warmer, clearer, funnier, and safer options.'],
  ['choose, copy, send', 'You keep control of the final words.'],
] as const

function ArrowIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M5 12h14M13 5l7 7-7 7" />
    </svg>
  )
}

function LandingNav() {
  return (
    <header className="sticky top-0 z-40 border-b border-tono-border bg-tono-bg/90 backdrop-blur-md">
      <div className="max-w-[1180px] mx-auto min-h-[76px] px-5 sm:px-6 md:px-10 flex items-center justify-between gap-4">
        <TonoBrand />
        <nav aria-label="Landing page" className="flex items-center gap-6">
          <a href="#proof" className="hidden md:inline text-[13px] font-semibold text-tono-text-soft hover:text-tono-text transition">
            see it work
          </a>
          <a href="#videos" className="hidden md:inline text-[13px] font-semibold text-tono-text-soft hover:text-tono-text transition">
            video
          </a>
          <Link
            href="/pricing"
            className="inline-flex items-center justify-center min-h-[46px] px-5 rounded-[12px] bg-tono-accent hover:bg-tono-accent-hover text-white text-[14px] font-bold transition shadow-[0_8px_28px_rgba(168,85,247,0.24)]"
          >
            start trial
          </Link>
        </nav>
      </div>
    </header>
  )
}

function HeroProof() {
  return (
    <aside aria-label="Before and after tono rewrite example" className="rounded-[22px] border border-tono-border bg-tono-bg-card overflow-hidden min-w-0">
      <div className="flex items-center justify-between gap-3 px-5 py-4 border-b border-tono-border text-[10px] uppercase tracking-[0.14em] font-semibold text-tono-text-softer">
        <span className="inline-flex items-center gap-2"><span className="w-2 h-2 rounded-full bg-tono-accent" aria-hidden="true" />tono · coach</span>
        <span>before → after</span>
      </div>
      <div className="p-5 sm:p-6 border-b border-tono-border">
        <p className="text-[11px] uppercase tracking-[0.14em] font-bold text-tono-text-softer">your draft</p>
        <p className="mt-3 text-[17px] sm:text-[19px] font-semibold text-tono-text leading-snug">Can you send that by EOD? I already asked twice.</p>
        <span className="mt-4 inline-flex rounded-[8px] px-2.5 py-1.5 bg-[rgba(244,114,182,0.12)] text-[12px] font-semibold tone-text-warmer">could land as frustrated</span>
      </div>
      <div className="p-3.5 sm:p-4 space-y-2.5">
        {heroRewrites.map((rewrite) => (
          <div key={rewrite.tone} className={`rounded-[13px] border border-tono-border bg-tono-bg-elev p-4 tone-rule-l-${rewrite.tone}`}>
            <p className={`text-[11px] uppercase tracking-[0.12em] font-bold tone-text-${rewrite.tone}`}>{rewrite.tone}</p>
            <p className="mt-2 text-[13px] sm:text-[14px] text-tono-text-soft leading-relaxed">{rewrite.text}</p>
          </div>
        ))}
      </div>
    </aside>
  )
}

export default function LandingPage() {
  return (
    <main className="min-h-screen bg-tono-bg text-tono-text font-sans antialiased overflow-x-clip">
      <LandingNav />

      <section className="border-b border-tono-border">
        <div className="max-w-[1180px] mx-auto px-5 sm:px-6 md:px-10 py-16 sm:py-20 md:py-24 lg:py-28 grid grid-cols-1 lg:grid-cols-[0.92fr_1.08fr] gap-12 lg:gap-16 items-center">
          <div>
            <p className="text-[11px] sm:text-[12px] uppercase tracking-[0.14em] font-bold text-tono-accent-light">
              message tone coach
            </p>
            <h1 className="mt-5 text-[46px] sm:text-[58px] lg:text-[68px] leading-[0.98] font-extrabold tracking-[-0.055em] text-tono-text">
              before you send it, <span className="text-tono-accent-light">see how it can land.</span>
            </h1>
            <p className="mt-6 max-w-xl text-[17px] sm:text-[19px] leading-[1.65] text-tono-text-soft">
              Paste a draft. tono gives you warmer, clearer, funnier, and safer rewrites. You choose what still sounds like you.
            </p>
            <div className="mt-8 flex flex-col sm:flex-row gap-3">
              <ProCheckoutButton
                interval="month"
                label="start 14-day free trial"
                className="inline-flex items-center justify-center gap-2 min-h-[48px] px-6 py-3.5 rounded-[12px] bg-tono-accent hover:bg-tono-accent-hover disabled:opacity-60 disabled:pointer-events-none text-white font-bold transition shadow-[0_8px_32px_rgba(168,85,247,0.30)]"
              >
                start 14-day free trial <ArrowIcon />
              </ProCheckoutButton>
              <a href="#proof" className="inline-flex items-center justify-center min-h-[48px] px-6 py-3.5 rounded-[12px] border border-tono-border-strong bg-tono-bg-card text-tono-text font-bold hover:border-tono-accent transition">
                watch a real rewrite
              </a>
            </div>
            <p className="mt-4 text-[12px] leading-relaxed text-tono-text-softer">
              one lifetime 14-day trial, then $3.99/month or $39.99/year · paid unlimited · no free tier · tono never sends a message for you
            </p>
          </div>
          <HeroProof />
        </div>
      </section>

      <section id="proof" className="border-b border-tono-border scroll-mt-20">
        <div className="max-w-[1180px] mx-auto px-5 sm:px-6 md:px-10 py-20 md:py-28">
          <p className="text-[11px] uppercase tracking-[0.16em] font-bold text-tono-accent-light">product proof, not promises</p>
          <h2 className="mt-4 text-[38px] sm:text-[48px] leading-none font-extrabold tracking-[-0.045em]">the message stays yours.</h2>
          <p className="mt-5 max-w-2xl text-[16px] sm:text-[18px] leading-relaxed text-tono-text-soft">
            tono does not write a personality for you. It shows the tradeoff in your draft, then gives you choices before you hit send.
          </p>

          <div className="mt-12 grid grid-cols-1 md:grid-cols-[0.78fr_1.22fr] gap-8 lg:gap-14 items-center">
            <ol className="border-l border-tono-border">
              {steps.map(([title, body], index) => (
                <li key={title} className={`px-6 py-5 ${index === 0 ? 'border-l-2 border-tono-accent bg-tono-accent-softer' : ''}`}>
                  <p className={`text-[16px] font-bold ${index === 0 ? 'text-tono-text' : 'text-tono-text-softer'}`}>{index + 1} · {title}</p>
                  <p className="mt-1 text-[14px] leading-relaxed text-tono-text-soft">{body}</p>
                </li>
              ))}
            </ol>

            <article className="rounded-[20px] border border-tono-border bg-tono-bg-card p-5 sm:p-7">
              <p className="text-[11px] uppercase tracking-[0.14em] font-bold text-tono-text-softer">real before → after format</p>
              <div className="mt-4 ml-auto max-w-[82%] rounded-[18px] bg-[#2A2A30] px-5 py-4 text-[16px] font-medium text-tono-text">Fine. Do whatever you want.</div>
              <p className="mt-6 text-[11px] uppercase tracking-[0.14em] font-bold text-tono-accent-light">safer rewrite</p>
              <div className="mt-3 max-w-[88%] rounded-[18px] border border-tono-accent/50 bg-tono-accent-soft px-5 py-4 text-[16px] leading-relaxed text-tono-text">
                I don’t think we’re aligned yet. Can we pause and compare what each of us needs?
              </div>
              <button type="button" className="mt-4 min-h-[44px] min-w-[72px] rounded-[10px] border border-tono-border-strong px-4 text-[13px] font-semibold text-tono-text-soft hover:text-tono-text hover:border-tono-accent transition" aria-label="Copy safer rewrite example">
                copy
              </button>
            </article>
          </div>
        </div>
      </section>

      <section id="videos" className="border-b border-tono-border scroll-mt-20">
        <div className="max-w-[1180px] mx-auto px-5 sm:px-6 md:px-10 py-20 md:py-28">
          <p className="text-[11px] uppercase tracking-[0.16em] font-bold text-tono-accent-light">product video</p>
          <h2 className="mt-4 text-[38px] sm:text-[48px] leading-none font-extrabold tracking-[-0.045em]">texts i almost sent.</h2>
          <p className="mt-5 mb-12 max-w-2xl text-[16px] sm:text-[18px] leading-relaxed text-tono-text-soft">
            A short-form series built around the half-second before send: the synthetic draft, the likely landing, and the rewrite you actually choose.
          </p>
          <CampaignVideos />
        </div>
      </section>

      <section className="border-b border-tono-border">
        <div className="max-w-[1180px] mx-auto px-5 sm:px-6 md:px-10 py-20 md:py-28">
          <p className="max-w-4xl text-[28px] sm:text-[40px] leading-[1.2] tracking-[-0.035em]">
            <del className="block text-tono-text-softer decoration-2">“Just checking in again.”</del>
            <span className="block mt-2 text-tono-accent-light">“Could you confirm whether Friday still works?”</span>
          </p>
          <p className="mt-8 text-[17px] text-tono-text-soft">Same intent. Less room for the wrong read.</p>
        </div>
      </section>

      <section id="pricing" className="border-b border-tono-border">
        <div className="max-w-[900px] mx-auto px-5 sm:px-6 md:px-10 py-20 md:py-28 text-center">
          <p className="text-[11px] uppercase tracking-[0.16em] font-bold text-tono-accent-light">one plan · two billing choices</p>
          <h2 className="mt-4 text-[38px] sm:text-[48px] leading-none font-extrabold tracking-[-0.045em]">paid means unlimited.</h2>
          <p className="mt-5 text-[16px] sm:text-[18px] leading-relaxed text-tono-text-soft">
            One lifetime 14-day trial per customer. Then $3.99/month or $39.99/year. Both paid options include unlimited rewrites. There is no free tier.
          </p>
          <div className="mt-8 flex flex-col sm:flex-row justify-center gap-3">
            <ProCheckoutButton interval="month" label="start trial — then $3.99/month">
              start trial — then $3.99/month
            </ProCheckoutButton>
            <ProCheckoutButton
              interval="year"
              label="start trial — then $39.99/year"
              className="inline-flex items-center justify-center min-h-[44px] px-5 py-3 rounded-[12px] border border-tono-border-strong bg-tono-bg-card text-tono-text font-semibold hover:border-tono-accent disabled:opacity-60 disabled:pointer-events-none transition"
            >
              start trial — then $39.99/year
            </ProCheckoutButton>
          </div>
          <p className="mt-5 text-[12px] text-tono-text-softer">subscriptions renew automatically unless cancelled. cancel anytime.</p>
        </div>
      </section>

      <section className="border-b border-tono-border">
        <div className="max-w-[1000px] mx-auto px-5 sm:px-6 md:px-10 py-20 md:py-28 text-center">
          <p className="text-[12px] uppercase tracking-[0.16em] font-bold text-tono-accent-light">tono — just tone it!</p>
          <h2 className="mt-4 text-[38px] sm:text-[52px] leading-[1.03] font-extrabold tracking-[-0.05em]">check the draft before the draft checks you.</h2>
          <p className="mt-5 text-[17px] text-tono-text-soft">One lifetime 14-day trial. Then $3.99/month or $39.99/year. Paid unlimited. No free tier.</p>
          <ProCheckoutButton
            interval="month"
            label="start 14-day free trial"
            className="mt-8 inline-flex items-center justify-center gap-2 min-h-[48px] px-6 py-3.5 rounded-[12px] bg-tono-accent hover:bg-tono-accent-hover disabled:opacity-60 disabled:pointer-events-none text-white font-bold transition shadow-[0_8px_32px_rgba(168,85,247,0.30)]"
          >
            start 14-day free trial <ArrowIcon />
          </ProCheckoutButton>
        </div>
      </section>
    </main>
  )
}
