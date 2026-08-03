'use client'

// The signed-in account's billing timeline. Reads the owner-scoped backend
// endpoint through the same-origin proxy (bearer stays in the httpOnly cookie)
// and renders each subscription/purchase as a human-readable row — never a raw
// provider or transaction id. Includes an accessible export-to-JSON control so
// a person can take their own billing record with them (contract §7:
// correction/delete/export; here export + a truthful record).

import { useCallback, useEffect, useState } from 'react'
import { apiPath } from '../../lib/auth-redirects'

type PaymentHistoryItem = {
  id: string
  provider: string
  product_id: string
  entitlement: string
  ownership_type: string
  grant_kind: string
  entitlement_state: string
  purchase_state: string
  is_current: boolean
  trial_consumed: boolean
  // Verified plan price, present only where the provider gives an authoritative
  // normalized amount (Stripe). Null for providers we don't normalize.
  amount_minor?: number | null
  currency?: string | null
  environment: string
  effective_at: string
  expires_at: string | null
  revoked_at: string | null
  created_at: string
  updated_at: string
}

type Payload = {
  account_id: string | null
  is_pro?: boolean
  items: PaymentHistoryItem[]
}

const PROVIDER_LABEL: Record<string, string> = {
  stripe: 'web (card / wallet)',
  apple: 'apple',
  google_play: 'google play',
  // RevenueCat canary (Build 123): a RevenueCat-sourced provider fact renders with
  // its own label if the backend payment history surfaces one. Web checkout itself
  // stays Stripe-hosted — see src/lib/revenuecat-config.ts.
  revenuecat: 'revenuecat',
}

const PRODUCT_LABEL: Record<string, string> = {
  'com.tonoit.pro.monthly': 'tono pro — monthly',
  'com.tonoit.pro.yearly': 'tono pro — yearly',
}

function providerLabel(p: string): string {
  return PROVIDER_LABEL[p] ?? p
}

function productLabel(id: string): string {
  return PRODUCT_LABEL[id] ?? id
}

// Render a verified price only when BOTH minor-unit amount and ISO currency are
// present. Never fabricate a price for a provider we didn't normalize.
function formatAmount(minor?: number | null, currency?: string | null): string | null {
  if (typeof minor !== 'number' || !currency) return null
  try {
    return new Intl.NumberFormat(undefined, {
      style: 'currency',
      currency: currency.toUpperCase(),
    }).format(minor / 100)
  } catch {
    return null
  }
}

function formatDate(iso: string | null): string {
  if (!iso) return '—'
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

function statusLabel(item: PaymentHistoryItem): string {
  if (item.is_current) return 'active'
  if (item.entitlement_state === 'revoked') return 'revoked'
  if (item.purchase_state === 'refunded') return 'refunded'
  if (item.purchase_state === 'expired') return 'expired'
  return item.purchase_state
}

export default function PaymentHistory() {
  const [state, setState] = useState<'loading' | 'ready' | 'error'>('loading')
  const [items, setItems] = useState<PaymentHistoryItem[]>([])

  const load = useCallback(async () => {
    setState('loading')
    try {
      const res = await fetch(apiPath('/api/account/payment-history'), {
        cache: 'no-store',
      })
      if (!res.ok) {
        setState('error')
        return
      }
      const data = (await res.json()) as Payload
      setItems(Array.isArray(data.items) ? data.items : [])
      setState('ready')
    } catch {
      setState('error')
    }
  }, [])

  useEffect(() => {
    void load()
  }, [load])

  const onExport = useCallback(() => {
    // Export the person's OWN billing record as JSON — no raw ids beyond the
    // opaque row handles the server already returned.
    const blob = new Blob([JSON.stringify({ exported_at: new Date().toISOString(), items }, null, 2)], {
      type: 'application/json',
    })
    const url = URL.createObjectURL(blob)
    const a = document.createElement('a')
    a.href = url
    a.download = 'tono-payment-history.json'
    document.body.appendChild(a)
    a.click()
    document.body.removeChild(a)
    URL.revokeObjectURL(url)
  }, [items])

  return (
    <section aria-labelledby="payment-history-heading" className="space-y-4">
      <div className="flex items-center justify-between gap-3">
        <h2
          id="payment-history-heading"
          className="text-[13px] font-semibold uppercase tracking-wider text-tono-text-softer"
        >
          payment history
        </h2>
        {state === 'ready' && items.length > 0 ? (
          <button
            type="button"
            onClick={onExport}
            className="text-[13px] font-semibold text-tono-accent hover:underline min-h-[44px] px-2"
          >
            export
          </button>
        ) : null}
      </div>

      {state === 'loading' ? (
        <p role="status" className="text-[14px] text-tono-text-softer">
          loading your billing timeline…
        </p>
      ) : state === 'error' ? (
        <div
          role="alert"
          className="rounded-[14px] border border-tono-danger/40 bg-tono-danger/10 p-5 text-[14px] text-tono-text-soft leading-[1.6]"
        >
          we couldn't load your payment history right now. your plan and billing
          are unaffected — this is a temporary connection issue.{' '}
          <button type="button" onClick={() => void load()} className="font-semibold text-tono-accent hover:underline">
            retry
          </button>
        </div>
      ) : items.length === 0 ? (
        <p className="text-[14px] text-tono-text-soft leading-[1.6]">
          no purchases yet. when you subscribe — on the web, an iPhone, or an
          Android phone — every payment shows up here, tied to this account.
        </p>
      ) : (
        <ul className="space-y-3">
          {items.map((item) => (
            <li
              key={item.id}
              className="bg-tono-bg-card border border-tono-border rounded-[14px] p-4 md:p-5"
            >
              <div className="flex items-start justify-between gap-3">
                <div>
                  <p className="text-[15px] font-semibold text-tono-text">
                    {productLabel(item.product_id)}
                  </p>
                  <p className="mt-0.5 text-[13px] text-tono-text-softer">
                    via {providerLabel(item.provider)}
                    {item.grant_kind === 'family' ? ' · family sharing' : ''}
                    {item.environment === 'Sandbox' ? ' · sandbox' : ''}
                  </p>
                </div>
                <span
                  className={
                    'shrink-0 rounded-full px-2.5 py-1 text-[12px] font-semibold ' +
                    (item.is_current
                      ? 'bg-tono-accent/15 text-tono-accent'
                      : 'bg-tono-border/40 text-tono-text-softer')
                  }
                >
                  {statusLabel(item)}
                </span>
              </div>
              <dl className="mt-3 grid grid-cols-2 gap-x-4 gap-y-1 text-[13px]">
                {formatAmount(item.amount_minor, item.currency) ? (
                  <>
                    <dt className="text-tono-text-softer">plan price</dt>
                    <dd className="text-tono-text-soft text-right">
                      {formatAmount(item.amount_minor, item.currency)}
                    </dd>
                  </>
                ) : null}
                <dt className="text-tono-text-softer">started</dt>
                <dd className="text-tono-text-soft text-right">{formatDate(item.effective_at)}</dd>
                {item.expires_at ? (
                  <>
                    <dt className="text-tono-text-softer">{item.is_current ? 'renews / ends' : 'ended'}</dt>
                    <dd className="text-tono-text-soft text-right">{formatDate(item.expires_at)}</dd>
                  </>
                ) : null}
                {item.revoked_at ? (
                  <>
                    <dt className="text-tono-text-softer">revoked</dt>
                    <dd className="text-tono-text-soft text-right">{formatDate(item.revoked_at)}</dd>
                  </>
                ) : null}
              </dl>
            </li>
          ))}
        </ul>
      )}
    </section>
  )
}
