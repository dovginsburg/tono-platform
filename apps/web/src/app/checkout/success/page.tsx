// /app/checkout/success — legacy post-checkout URL.
//
// The canonical post-checkout page is now /app/welcome-pro (the success_url the
// web checkout proxy sends to Stripe). Any older link or bookmark to this path
// is redirected there so there is exactly one post-purchase experience. The
// polling client lives at ./CheckoutSuccessClient and is imported by
// /welcome-pro.

import { redirect } from 'next/navigation'

export default function CheckoutSuccessPage() {
  // Preserve the `?s=1` marker convention used by the success_url.
  redirect('/welcome-pro?s=1')
}
