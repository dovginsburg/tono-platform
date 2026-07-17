'use client'

// Polls /api/me until the Stripe webhook has promoted the user to
// pro, then triggers confetti. All visual state lives here so the
// server-rendered shell can stay cheap.
//
// Why polling instead of a single fetch: the Stripe webhook
// (POST /v1/stripe/webhook) updates the user's plan AFTER Stripe
// redirects to success_url. There's a 0–30s window where the user
// lands here before the webhook has run. We poll for up to ~60s,
// then surface a "we'll email you when it's on" fallback so the
// page never sits in a loading state forever.

import { useEffect, useRef, useState } from 'react'
import Link from 'next/link'

type MeResponse = {
  device_id?: string | null
  plan?: string
  is_pro?: boolean
  used_today?: number
  daily_limit?: number
  subscription_status?: string | null
  subscription_renews_at?: string | null
}

type Phase = 'polling' | 'active' | 'timed-out' | 'error'

const POLL_INTERVAL_MS = 2000
const POLL_TIMEOUT_MS = 60_000

function fireConfetti() {
  // Lightweight CSS-only confetti — no extra deps. Drops 36 colored
  // squares from the top of the page, then removes them. Safe for
  // prefers-reduced-motion (we skip the animation entirely).
  if (typeof window === 'undefined') return
  if (window.matchMedia?.('(prefers-reduced-motion: reduce)').matches) {
    return
  }
  const colors = [
    '#A855F7', // tono accent
    '#38BDF8', // tono-tone-clearer
    '#F472B6', // tono-tone-warmer
    '#FBBF24', // tono-tone-funnier
    '#34D399', // tono-tone-safer
  ]
  const root = document.body
  const pieces: HTMLSpanElement[] = []
  for (let i = 0; i < 36; i++) {
    const piece = document.createElement('span')
    piece.setAttribute('aria-hidden', 'true')
    const color = colors[i % colors.length]
    const left = Math.random() * 100
    const delay = Math.random() * 0.4
    const size = 6 + Math.random() * 6
    const drift = (Math.random() - 0.5) * 200
    piece.style.cssText = `
      position: fixed;
      top: -16px;
      left: ${left}vw;
      width: ${size}px;
      height: ${size * 0.4}px;
      background: ${color};
      border-radius: 2px;
      pointer-events: none;
      z-index: 9999;
      transform: translate3d(0,0,0) rotate(${Math.random() * 360}deg);
      animation: tono-confetti-fall 1800ms cubic-bezier(0.2, 0.8, 0.2, 1) ${delay}s forwards;
      --drift: ${drift}px;
    `
    root.appendChild(piece)
    pieces.push(piece)
  }
  // Inject the keyframes once.
  if (!document.getElementById('tono-confetti-style')) {
    const style = document.createElement('style')
    style.id = 'tono-confetti-style'
    style.textContent = `
      @keyframes tono-confetti-fall {
        0%   { transform: translate3d(0,0,0) rotate(0deg); opacity: 1; }
        100% { transform: translate3d(var(--drift), 110vh, 0) rotate(720deg); opacity: 0.6; }
      }
    `
    document.head.appendChild(style)
  }
  window.setTimeout(() => {
    pieces.forEach((p) => p.remove())
  }, 2600)
}

export default function CheckoutSuccessClient() {
  const [phase, setPhase] = useState<Phase>('polling')
  const [me, setMe] = useState<MeResponse | null>(null)
  const [errorMsg, setErrorMsg] = useState<string | null>(null)
  const firedRef = useRef(false)

  useEffect(() => {
    let cancelled = false
    let timer: ReturnType<typeof setTimeout> | null = null
    const startedAt = Date.now()

    async function tick() {
      if (cancelled) return
      try {
        const res = await fetch('/api/me', { cache: 'no-store' })
        if (!res.ok) {
          // 502 etc — try again until timeout
          setErrorMsg(null)
        } else {
          const data = (await res.json()) as MeResponse
          if (cancelled) return
          setMe(data)
          if (data.is_pro === true || data.subscription_status === 'active') {
            if (!firedRef.current) {
              firedRef.current = true
              fireConfetti()
            }
            setPhase('active')
            return
          }
        }
      } catch (err) {
        // Network blip — keep polling until timeout, surface error only at end.
        setErrorMsg(err instanceof Error ? err.message : 'network error')
      }
      if (cancelled) return
      if (Date.now() - startedAt > POLL_TIMEOUT_MS) {
        setPhase((prev) => (prev === 'active' ? 'active' : 'timed-out'))
        return
      }
      timer = setTimeout(tick, POLL_INTERVAL_MS)
    }

    tick()
    return () => {
      cancelled = true
      if (timer) clearTimeout(timer)
    }
  }, [])

  if (phase === 'active') {
    return (
      <ActivePanel me={me} />
    )
  }

  if (phase === 'timed-out') {
    return <PendingPanel me={me} note="we're still confirming with stripe — hang tight, we'll email you when it's set." />
  }

  if (phase === 'error') {
    return (
      <PendingPanel
        me={me}
        note={errorMsg ?? "couldn’t reach your account just now. refresh in a moment."}
      />
    )
  }

  // polling
  return (
    <PendingPanel
      me={me}
      note="confirming your subscription with stripe…"
      spinner
    />
  )
}

function ActivePanel({ me }: { me: MeResponse | null }) {
  return (
    <div className="space-y-7 text-center">
      <div className="inline-flex h-16 w-16 items-center justify-center rounded-full bg-tono-accent-soft text-tono-accent-light mx-auto">
        <svg width="32" height="32" viewBox="0 0 24 24" fill="none" aria-hidden="true">
          <path
            d="M5 12.5l4 4L19 7"
            stroke="currentColor"
            strokeWidth="2.5"
            strokeLinecap="round"
            strokeLinejoin="round"
          />
        </svg>
      </div>
      <div>
        <h1 className="text-[32px] md:text-[40px] font-bold tracking-[-0.02em] text-tono-text">
          you're on tono pro.
        </h1>
        <p className="text-[15px] md:text-[16px] text-tono-text-soft leading-[1.6] mt-3 max-w-md mx-auto">
          unlimited rewrites unlocked. the iOS keyboard is on its way — we'll email when it ships.
        </p>
      </div>
      {me?.subscription_renews_at ? (
        <p className="text-[13px] text-tono-text-softer">
          renews {formatDate(me.subscription_renews_at)}
        </p>
      ) : null}
      <div className="flex flex-col sm:flex-row gap-3 justify-center pt-2">
        <Link
          href="/app/app"
          className="inline-flex items-center justify-center gap-2 px-5 py-3 rounded-[12px] bg-tono-accent hover:bg-tono-accent-hover text-white font-semibold transition min-h-[44px] text-[14px] shadow-[0_8px_24px_rgba(168,85,247,0.30)]"
        >
          open the composer
          <ArrowIcon />
        </Link>
        <a
          href="mailto:hello@tonoit.com?subject=pro%20receipt"
          className="inline-flex items-center justify-center gap-2 px-5 py-3 rounded-[12px] bg-transparent border border-tono-border-strong text-tono-text hover:border-tono-accent font-semibold transition min-h-[44px] text-[14px]"
        >
          email me a receipt
        </a>
      </div>
    </div>
  )
}

function PendingPanel({
  me,
  note,
  spinner = false,
}: {
  me: MeResponse | null
  note: string
  spinner?: boolean
}) {
  return (
    <div className="space-y-7 text-center">
      <div className="inline-flex h-16 w-16 items-center justify-center rounded-full bg-tono-bg-elev text-tono-text-softer mx-auto">
        {spinner ? (
          <span
            className="inline-block h-5 w-5 rounded-full border-2 border-tono-text-softer border-t-tono-accent animate-spin"
            aria-hidden="true"
          />
        ) : (
          <svg width="28" height="28" viewBox="0 0 24 24" fill="none" aria-hidden="true">
            <circle cx="12" cy="12" r="9" stroke="currentColor" strokeWidth="1.5" />
            <path
              d="M12 7v5l3 3"
              stroke="currentColor"
              strokeWidth="1.5"
              strokeLinecap="round"
              strokeLinejoin="round"
            />
          </svg>
        )}
      </div>
      <div>
        <h1 className="text-[28px] md:text-[36px] font-bold tracking-[-0.02em] text-tono-text">
          {spinner ? 'one moment…' : 'almost there.'}
        </h1>
        <p className="text-[15px] md:text-[16px] text-tono-text-soft leading-[1.6] mt-3 max-w-md mx-auto">
          {note}
        </p>
      </div>
      {me && !me.is_pro ? (
        <p className="text-[13px] text-tono-text-softer">
          current access: {me.plan ?? 'unpaid'}. we'll update it when Stripe confirms.
        </p>
      ) : null}
      <div className="flex flex-col sm:flex-row gap-3 justify-center pt-2">
        <Link
          href="/app/app"
          className="inline-flex items-center justify-center gap-2 px-5 py-3 rounded-[12px] bg-tono-bg-elev border border-tono-border-strong text-tono-text hover:border-tono-accent font-semibold transition min-h-[44px] text-[14px]"
        >
          try the composer anyway
        </Link>
        <Link
          href="/app/pricing"
          className="inline-flex items-center justify-center gap-2 px-5 py-3 rounded-[12px] bg-transparent text-tono-text-softer hover:text-tono-text font-semibold transition min-h-[44px] text-[14px]"
        >
          ← back to pricing
        </Link>
      </div>
    </div>
  )
}

function ArrowIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" aria-hidden="true">
      <path
        d="M5 12h14M13 6l6 6-6 6"
        stroke="currentColor"
        strokeWidth="2"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  )
}

function formatDate(iso: string): string {
  try {
    return new Date(iso).toLocaleDateString(undefined, {
      year: 'numeric',
      month: 'short',
      day: 'numeric',
    })
  } catch {
    return iso
  }
}
