// /app/checkout/success — server shell around the polling client.
//
// We split into a server-rendered page that passes no props, plus a
// 'use client' component that owns the polling + confetti. The server
// shell is intentionally thin — keeping RSC island small means the
// page loads even if the user lands here before Supabase session is
// fully reconciled (the polling client retries /api/me until either
// is_pro returns true or 60s elapses).

import type { Metadata } from 'next'
import CheckoutSuccessClient from './CheckoutSuccessClient'

export const metadata: Metadata = {
  title: 'you’re on tono pro — say what you mean',
  description: 'subscription confirmed. welcome to tono pro.',
  robots: { index: false, follow: false },
}

export default function CheckoutSuccessPage() {
  return (
    <main className="min-h-screen bg-tono-bg text-tono-text font-sans antialiased">
      <div className="max-w-[640px] mx-auto px-6 md:px-10 py-16 md:py-24">
        <CheckoutSuccessClient />
      </div>
    </main>
  )
}
