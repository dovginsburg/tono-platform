import Link from 'next/link'

export default function PrivacyPage() {
  return (
    <main className="min-h-screen bg-soft text-tono">
      <div className="max-w-3xl mx-auto px-6 py-16">
        <Link href="/" className="text-sm text-tono-soft hover:underline">
          ← back
        </Link>
        <h1 className="mt-8 text-4xl font-bold tracking-tight">Privacy</h1>
        <p className="mt-2 text-tono-soft text-sm">
          last updated: 2026-07-07
        </p>

        <section className="mt-12 space-y-6 text-[15px] leading-relaxed">
          <p>
            tono is a pre-send communication coach. this page explains, in plain
            language, what we collect and what we don't.
          </p>

          <h2 className="text-2xl font-semibold pt-6">how drafts are handled</h2>
          <ul className="list-disc pl-6 space-y-2">
            <li>your draft stays in your browser until you choose rewrite</li>
            <li>when you choose rewrite, the draft is sent securely to tono's rewrite service to generate the result</li>
            <li>your writing is not used to train models</li>
            <li>analytics on who you write to, when, or about what</li>
            <li>your contacts, calendar, or any data outside the active session</li>
          </ul>

          <h2 className="text-2xl font-semibold pt-6">what we do collect (pro tier only)</h2>
          <ul className="list-disc pl-6 space-y-2">
            <li>your email address, for subscription receipts</li>
            <li>your subscription tier, to gate the pro features</li>
            <li>the count of rewrites you make per day, to prevent abuse and enforce subscription limits</li>
          </ul>

          <h2 className="text-2xl font-semibold pt-6">third parties</h2>
          <p>
            we use stripe for payments. stripe's privacy policy applies to the
            data they collect at checkout. we use supabase for auth and
            subscription state. supabase's privacy policy applies to that data.
          </p>

          <h2 className="text-2xl font-semibold pt-6">data location</h2>
          <p>
            supabase data is hosted on AWS us-east-1. stripe data is hosted on
            stripe's infrastructure (see stripe.com/privacy). no tono data is
            sold, traded, or shared with anyone outside the two services named
            above.
          </p>

          <h2 className="text-2xl font-semibold pt-6">deletion</h2>
          <p>
            email <a href="mailto:hi@tonoit.com" className="underline">hi@tonoit.com</a>{" "}
            and your account + all associated data will be deleted within 7 days.
          </p>

          <h2 className="text-2xl font-semibold pt-6">contact</h2>
          <p>
            questions: <a href="mailto:hi@tonoit.com" className="underline">hi@tonoit.com</a>
          </p>

          <h2 className="text-2xl font-semibold pt-6">subscription</h2>
          <p>
            Tono Pro is a paid subscription. Every new user starts with a real 7-day free trial. After the trial, the subscription auto-renews at $3.99/month or $39.99/year unless cancelled. Cancel anytime from your account settings — no retention, no dark patterns. Checkout is handled by Stripe (web) or App Store / Google Play (mobile); your card details never touch Tono.
          </p>
        </section>
      </div>
    </main>
  );
}