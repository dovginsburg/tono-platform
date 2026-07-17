// ProCheckoutButton — wires the marketing Pro Subscribe CTA into the
// Tono backend's Stripe Checkout endpoint.
//
// Posts to /api/checkout (which proxies to api.tonoit.com/v1/checkout).
// The server-side proxy forwards the signed-in user's API token. On 200,
// redirects to body.url. On non-200,
// shows an inline error message and keeps the user on the page so
// they can retry. Matches the behavior of the static pricing.html
// (tono-platform-claude repo) for parity between surfaces.
//
// Brand voice: lowercase, no exclamation, "opening checkout…" while
// loading, "couldn't reach checkout." on network failure.

'use client'

import { useEffect, useState } from 'react'

type Interval = 'month' | 'year'

type Props = {
  interval: Interval
  label: string
  className?: string
  children?: React.ReactNode
}

type CheckoutResponse = {
  url?: string
  session_id?: string
  detail?: string
  error?: string
  message?: string
}

type OfferResponse = {
  currency: string
  unit_amount: number
  trial_eligible: boolean
  trial_days: number
}

export default function ProCheckoutButton({
  interval,
  label,
  className,
  children,
}: Props) {
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [offer, setOffer] = useState<OfferResponse | null>(null)

  useEffect(() => {
    let active = true
    fetch(`/api/offer?interval=${interval}`, { cache: 'no-store' })
      .then(async (response) => (response.ok ? (await response.json()) as OfferResponse : null))
      .then((value) => {
        if (active && value) setOffer(value)
      })
      .catch(() => undefined)
    return () => {
      active = false
    }
  }, [interval])

  const localizedPrice = offer
    ? new Intl.NumberFormat(undefined, {
        style: 'currency',
        currency: offer.currency.toUpperCase(),
      }).format(offer.unit_amount / 100)
    : null
  const providerOfferLabel = localizedPrice
    ? offer?.trial_eligible
      ? `7-day trial, then auto-renews at ${localizedPrice}/${interval} unless canceled`
      : `auto-renews at ${localizedPrice}/${interval} unless canceled`
    : null

  async function handleClick() {
    if (busy) return
    setError(null)
    setBusy(true)
    try {
      const res = await fetch('/api/checkout', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ interval }),
      })
      let body: CheckoutResponse = {}
      try {
        body = (await res.json()) as CheckoutResponse
      } catch {
        // ignore — empty body
      }
      if (res.ok && body.url) {
        window.location.href = body.url
        return
      }
      if (res.status === 401 || res.status === 403) {
        window.location.href = `/login?next=${encodeURIComponent('/pricing')}`
        return
      }
      const msg =
        body.detail ||
        body.error ||
        body.message ||
        (res.status === 502
          ? "couldn't reach checkout. check your connection and try again."
          : 'checkout failed. please try again in a moment.')
      setError(msg)
    } catch {
      setError("couldn't reach checkout. check your connection and try again.")
    } finally {
      setBusy(false)
    }
  }

  return (
    <>
      <button
        type="button"
        onClick={handleClick}
        disabled={busy}
        aria-busy={busy}
        data-interval={interval}
        className={
          className ??
          'inline-flex items-center justify-center gap-2 px-5 py-3 rounded-[12px] bg-tono-accent hover:bg-tono-accent-hover disabled:opacity-60 disabled:pointer-events-none text-white font-semibold transition min-h-[44px] text-[14px] shadow-[0_8px_24px_rgba(168,85,247,0.30)]'
        }
      >
        {busy ? 'opening checkout…' : providerOfferLabel ?? children ?? label}
      </button>
      {error ? (
        <p
          role="alert"
          className="mt-3 text-[13px] text-tono-tone-warmer font-medium"
        >
          {error}
        </p>
      ) : null}
    </>
  )
}
