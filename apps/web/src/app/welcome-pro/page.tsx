// /app/welcome-pro — the canonical post-checkout landing page.
//
// This is the URL the web checkout proxy (src/app/api/checkout/route.ts) hands
// Stripe as success_url, so it must exist and reconcile entitlement. It reuses
// the same server-shell + polling client as /checkout/success (which now
// redirects here) so there is exactly one post-purchase experience: poll
// /api/me until the Stripe webhook has flipped the account to Pro, then confirm
// and offer billing management.

import type { Metadata } from 'next'
import CheckoutSuccessClient from '../checkout/success/CheckoutSuccessClient'

export const metadata: Metadata = {
  title: 'you’re on tono pro — say what you mean',
  description: 'subscription confirmed. welcome to tono pro.',
  robots: { index: false, follow: false },
}

export default function WelcomeProPage() {
  return (
    <main className="min-h-screen bg-tono-bg text-tono-text font-sans antialiased">
      <div className="max-w-[640px] mx-auto px-6 md:px-10 py-16 md:py-24">
        <CheckoutSuccessClient />
      </div>
    </main>
  )
}
