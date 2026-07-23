'use client'

// Opens the Stripe billing portal. POSTs to the same-origin /api/portal proxy
// (which attaches the httpOnly bearer server-side) and redirects the browser to
// the returned portal URL. On 400 (no Stripe customer yet) or any other error,
// shows an inline message and keeps the user on the page.

import { useState } from 'react'

type PortalResponse = {
  url?: string
  error?: string
  detail?: string
  message?: string
}

export default function ManageBillingButton({
  label = 'manage billing',
  className,
}: {
  label?: string
  className?: string
}) {
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function handleClick() {
    if (busy) return
    setError(null)
    setBusy(true)
    try {
      const res = await fetch('/api/portal', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: '{}',
      })
      let body: PortalResponse = {}
      try {
        body = (await res.json()) as PortalResponse
      } catch {
        // ignore — empty body
      }
      if (res.ok && body.url) {
        window.location.href = body.url
        return
      }
      if (res.status === 401 || body.error === 'auth-required') {
        window.location.assign('/app/login')
        return
      }
      setError(
        body.detail ||
          body.message ||
          body.error ||
          "couldn't open the billing portal. try again in a moment."
      )
    } catch {
      setError("couldn't reach billing. check your connection and try again.")
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
        className={
          className ??
          'inline-flex items-center justify-center gap-2 px-5 py-3 rounded-[12px] bg-tono-accent hover:bg-tono-accent-hover disabled:opacity-60 disabled:pointer-events-none text-white font-semibold transition min-h-[44px] text-[14px]'
        }
      >
        {busy ? 'opening…' : label}
      </button>
      {error ? (
        <p role="alert" className="mt-3 text-[13px] text-tono-tone-warmer font-medium">
          {error}
        </p>
      ) : null}
    </>
  )
}
