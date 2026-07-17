export default function TermsPage() {
  return (
    <main className="min-h-screen bg-soft text-tono">
      <div className="max-w-3xl mx-auto px-6 py-16">
        <a href="/app" className="text-sm text-tono-soft hover:underline">
          ← back
        </a>
        <h1 className="mt-8 text-4xl font-bold tracking-tight">Terms</h1>
        <p className="mt-2 text-tono-soft text-sm">
          last updated: 2026-07-07
        </p>

        <section className="mt-12 space-y-6 text-[15px] leading-relaxed">
          <p>
            tono is a pre-send communication coach. by using it, you agree to
            these terms in plain language.
          </p>

          <h2 className="text-2xl font-semibold pt-6">what tono is</h2>
          <p>
            a tool that suggests 4 alternative phrasings of a draft you wrote.
            each suggestion is a starting point — you decide whether to use it,
            edit it, or ignore it. tono does not send messages on your behalf.
          </p>

          <h2 className="text-2xl font-semibold pt-6">what tono is not</h2>
          <ul className="list-disc pl-6 space-y-2">
            <li>medical, therapeutic, or mental-health advice</li>
            <li>a substitute for professional communication training</li>
            <li>a guarantee that any suggestion will land well with the recipient</li>
          </ul>

          <h2 className="text-2xl font-semibold pt-6">your responsibility</h2>
          <p>
            you own what you send. tono's suggestions are drafts, not directives.
            read them, edit them, take responsibility for the final message.
          </p>

          <h2 className="text-2xl font-semibold pt-6">subscriptions</h2>
          <p>
            each plan begins with an eligible 7-day trial only after Stripe
            purchase authorization, then auto-renews at $3.99/month or
            $39.99/year unless cancelled. cancel from your account page or via Stripe's customer portal. no
            retention, no dark patterns, no "are you sure" loops.
          </p>

          <h2 className="text-2xl font-semibold pt-6">refunds</h2>
          <p>
            within 14 days of any charge, email{" "}
            <a href="mailto:hi@tonoit.com" className="underline">hi@tonoit.com</a>{" "}
            and we refund. no questions.
          </p>

          <h2 className="text-2xl font-semibold pt-6">no warranty</h2>
          <p>
            tono is provided "as is." we don't promise the suggestions will
            always be appropriate, accurate, or well-received. you use the tool
            at your own discretion.
          </p>

          <h2 className="text-2xl font-semibold pt-6">changes</h2>
          <p>
            we may update these terms. we'll bump the date above and notify
            active subscribers by email.
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
