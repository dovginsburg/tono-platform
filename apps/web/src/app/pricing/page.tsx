import Link from 'next/link'
import ProCheckoutButton from '../ProCheckoutButton'
import TonoBrand from '../TonoBrand'

function CheckIcon() {
  return <span className="text-tono-tone-safer font-semibold" aria-hidden="true">✓</span>
}

export default function PricingPage() {
  return (
    <main className="min-h-screen bg-tono-bg text-tono-text font-sans antialiased">
      <div className="max-w-[920px] mx-auto px-5 sm:px-6 md:px-10 py-12 md:py-20">
        <TonoBrand lockup />
        <header className="mt-14 max-w-3xl">
          <p className="text-[11px] uppercase tracking-[0.16em] font-bold text-tono-accent-light">pricing</p>
          <h1 className="mt-4 text-[42px] sm:text-[56px] leading-[0.98] font-extrabold tracking-[-0.05em]">
            one plan. two ways to pay.
          </h1>
          <p className="mt-6 text-[17px] leading-relaxed text-tono-text-soft">
            One lifetime 14-day trial per customer. Then choose $3.99/month or $39.99/year. Both paid options include unlimited rewrites. There is no free tier.
          </p>
        </header>

        <section aria-label="Tono subscription options" className="mt-12 rounded-[22px] border border-tono-accent/40 bg-tono-bg-card p-6 sm:p-9 shadow-[0_8px_36px_rgba(168,85,247,0.16)]">
          <div className="flex flex-col md:flex-row md:items-start md:justify-between gap-6">
            <div>
              <p className="text-[11px] uppercase tracking-[0.15em] font-bold text-tono-accent-light">tono pro</p>
              <h2 className="mt-3 text-[34px] font-extrabold tracking-[-0.04em]">paid unlimited</h2>
              <p className="mt-3 max-w-xl text-[14px] leading-relaxed text-tono-text-soft">
                Start with the same one-time trial on either billing schedule. Your subscription renews automatically unless cancelled.
              </p>
            </div>
            <div className="shrink-0 rounded-[14px] border border-tono-border bg-tono-bg-elev px-5 py-4">
              <p className="text-[11px] uppercase tracking-[0.12em] text-tono-text-softer">trial</p>
              <p className="mt-1 text-[20px] font-bold">14 days</p>
              <p className="text-[12px] text-tono-text-softer">once per customer</p>
            </div>
          </div>

          <ul className="mt-8 grid grid-cols-1 sm:grid-cols-2 gap-3 text-[14px] text-tono-text-soft">
            <li className="flex gap-2"><CheckIcon /><span>unlimited rewrites while paid</span></li>
            <li className="flex gap-2"><CheckIcon /><span>warmer, clearer, funnier, and safer options</span></li>
            <li className="flex gap-2"><CheckIcon /><span>you choose what to copy and send</span></li>
            <li className="flex gap-2"><CheckIcon /><span>cancel anytime</span></li>
          </ul>

          <div className="mt-9 grid grid-cols-1 sm:grid-cols-2 gap-4">
            <div className="rounded-[16px] border border-tono-border bg-tono-bg-elev p-5">
              <p className="text-[12px] uppercase tracking-[0.12em] font-bold text-tono-text-softer">monthly</p>
              <p className="mt-2 text-[36px] font-extrabold tracking-[-0.04em]">$3.99<span className="text-[14px] font-normal text-tono-text-softer">/month</span></p>
              <ProCheckoutButton interval="month" label="start trial — then $3.99/month" className="mt-5 w-full inline-flex items-center justify-center min-h-[46px] px-5 py-3 rounded-[12px] bg-tono-accent hover:bg-tono-accent-hover disabled:opacity-60 disabled:pointer-events-none text-white font-bold transition">
                start 14-day trial
              </ProCheckoutButton>
            </div>
            <div className="rounded-[16px] border border-tono-border bg-tono-bg-elev p-5">
              <p className="text-[12px] uppercase tracking-[0.12em] font-bold text-tono-text-softer">yearly</p>
              <p className="mt-2 text-[36px] font-extrabold tracking-[-0.04em]">$39.99<span className="text-[14px] font-normal text-tono-text-softer">/year</span></p>
              <ProCheckoutButton interval="year" label="start trial — then $39.99/year" className="mt-5 w-full inline-flex items-center justify-center min-h-[46px] px-5 py-3 rounded-[12px] border border-tono-border-strong bg-tono-bg-card hover:border-tono-accent disabled:opacity-60 disabled:pointer-events-none text-tono-text font-bold transition">
                start 14-day trial
              </ProCheckoutButton>
            </div>
          </div>
          <p className="mt-6 text-[12px] leading-relaxed text-tono-text-softer">
            No charge during the trial. On day 15, the selected subscription begins unless cancelled. Prices are USD. Checkout is handled by Stripe.
          </p>
        </section>

        <div className="mt-10 text-center">
          <Link href="/" className="inline-flex min-h-[44px] items-center text-[13px] font-semibold text-tono-text-soft hover:text-tono-text transition">← back to tono</Link>
        </div>
      </div>
    </main>
  )
}
