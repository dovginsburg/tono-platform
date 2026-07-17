export default function PrivacyPage() {
  return (
    <main className="min-h-screen bg-soft text-tono">
      <div className="max-w-3xl mx-auto px-6 py-16">
        <a href="/app" className="text-sm text-tono-soft hover:underline">
          ← back
        </a>
        <h1 className="mt-8 text-4xl font-bold tracking-tight">Privacy</h1>
        <p className="mt-2 text-tono-soft text-sm">
          last updated: 2026-07-07
        </p>

        <section className="mt-12 space-y-6 text-[15px] leading-relaxed">
          <p>
            tono is a pre-send communication coach. this page explains, in plain
            language, what we collect and what we don't.
          </p>

          <h2 className="text-2xl font-semibold pt-6">what we don't collect</h2>
          <ul className="list-disc pl-6 space-y-2">
            <li>the drafts you write in tono — your text stays in your browser</li>
            <li>analytics on who you write to, when, or about what</li>
            <li>your contacts, calendar, or any data outside the active session</li>
          </ul>

          <h2 className="text-2xl font-semibold pt-6">what we do collect for subscribed accounts</h2>
          <ul className="list-disc pl-6 space-y-2">
            <li>your email address, for subscription receipts</li>
            <li>your subscription tier, to gate the pro features</li>
            <li>verified trial, subscription, or separately granted promo-access state</li>
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
        </section>
      </div>
    </main>
  );
}
