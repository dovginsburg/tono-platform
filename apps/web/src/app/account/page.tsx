// /app/account — the signed-in user's billing home.
//
// This is the "account page" the terms and privacy copy promise: view your
// plan, manage or cancel your subscription via the Stripe billing portal, and
// sign out. It reads the canonical entitlement server-side from the backend
// /v1/me (authoritative — never trusts a client flag) using the httpOnly
// tono_api_token cookie. A visitor with no session is invited to sign in.

import type { Metadata } from 'next'
import Link from 'next/link'
import { cookies } from 'next/headers'
import ManageBillingButton from './ManageBillingButton'
import PasskeyManager from './PasskeyManager'

export const metadata: Metadata = {
  title: 'your account — tono',
  description: 'view your plan, manage billing, and sign out.',
  robots: { index: false, follow: false },
}

type Me = {
  plan?: string
  is_pro?: boolean
  subscription_status?: string | null
  subscription_renews_at?: string | null
}

async function loadMe(): Promise<{ signedIn: boolean; me: Me | null; error: boolean }> {
  const cookieStore = await cookies()
  const token = cookieStore.get('tono_api_token')?.value
  if (!token) return { signedIn: false, me: null, error: false }

  const backendUrl = process.env.TONO_BACKEND_URL || 'https://api.tonoit.com'
  try {
    const res = await fetch(`${backendUrl}/v1/me`, {
      headers: { Authorization: `Bearer ${token}` },
      cache: 'no-store',
    })
    // A 401/403 means the session is stale — treat as signed out so the visitor
    // is invited to sign in again rather than shown a confusing blank plan.
    if (res.status === 401 || res.status === 403) return { signedIn: false, me: null, error: false }
    // Any other non-OK response is a backend fault: surface it as an explicit
    // error state, never as a silent "free" plan (which would misreport a
    // paying customer as unsubscribed).
    if (!res.ok) return { signedIn: true, me: null, error: true }
    const me = (await res.json()) as Me
    return { signedIn: true, me, error: false }
  } catch {
    return { signedIn: true, me: null, error: true }
  }
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

export default async function AccountPage() {
  const { signedIn, me, error } = await loadMe()

  return (
    <main className="min-h-screen bg-tono-bg text-tono-text font-sans antialiased">
      <div className="max-w-[640px] mx-auto px-6 md:px-10 py-16 md:py-24">
        <h1 className="text-[32px] md:text-[40px] font-bold tracking-[-0.02em] text-tono-text">
          your account
        </h1>

        {!signedIn ? (
          <div className="mt-8 space-y-6">
            <p className="text-[15px] text-tono-text-soft leading-[1.6]">
              you're not signed in. sign in to view your plan and manage billing.
            </p>
            <Link
              href="/login"
              className="inline-flex items-center justify-center gap-2 px-5 py-3 rounded-[12px] bg-tono-accent hover:bg-tono-accent-hover text-white font-semibold transition min-h-[44px] text-[14px]"
            >
              sign in
            </Link>
          </div>
        ) : error ? (
          <div className="mt-8 space-y-6">
            <div
              role="alert"
              className="rounded-[14px] border border-tono-danger/40 bg-tono-danger/10 p-5 text-[14px] text-tono-text-soft leading-[1.6]"
            >
              we couldn't reach your account right now. your plan and billing are
              safe — this is a temporary connection issue on our end, not a change
              to your subscription. please try again in a moment.
            </div>
            <Link
              href="/account"
              className="inline-flex items-center justify-center gap-2 px-5 py-3 rounded-[12px] bg-tono-accent hover:bg-tono-accent-hover text-white font-semibold transition min-h-[44px] text-[14px]"
            >
              retry
            </Link>
          </div>
        ) : (
          <div className="mt-8 space-y-8">
            <section className="bg-tono-bg-card border border-tono-border rounded-[18px] p-6 md:p-7">
              <h2 className="text-[13px] font-semibold uppercase tracking-wider text-tono-text-softer">
                plan
              </h2>
              <p className="mt-2 text-[22px] font-bold text-tono-text">
                {me?.is_pro ? 'tono pro' : 'free'}
              </p>
              {me?.subscription_status ? (
                <p className="mt-1 text-[13px] text-tono-text-soft">
                  status: {me.subscription_status}
                </p>
              ) : null}
              {me?.is_pro && me?.subscription_renews_at ? (
                <p className="mt-1 text-[13px] text-tono-text-softer">
                  renews {formatDate(me.subscription_renews_at)}
                </p>
              ) : null}
            </section>

            <section className="space-y-4">
              <h2 className="text-[13px] font-semibold uppercase tracking-wider text-tono-text-softer">
                billing
              </h2>
              {me?.is_pro ? (
                <>
                  <p className="text-[14px] text-tono-text-soft leading-[1.6]">
                    update your card, download receipts, or cancel anytime — no
                    retention, no dark patterns. cancelling keeps pro until the end
                    of your current period.
                  </p>
                  <ManageBillingButton label="manage billing & cancel" />
                </>
              ) : (
                <>
                  <p className="text-[14px] text-tono-text-soft leading-[1.6]">
                    you're not subscribed. if eligible, start your one lifetime 14-day trial; paid plans include unlimited rewrites.
                  </p>
                  <Link
                    href="/pricing"
                    className="inline-flex items-center justify-center gap-2 px-5 py-3 rounded-[12px] bg-tono-accent hover:bg-tono-accent-hover text-white font-semibold transition min-h-[44px] text-[14px]"
                  >
                    see pricing
                  </Link>
                </>
              )}
            </section>

            <section className="pt-2 border-t border-tono-border">
              <PasskeyManager />
            </section>

            <section className="pt-2 border-t border-tono-border">
              <form action="/app/api/auth/signout" method="post" className="mt-6">
                <button
                  type="submit"
                  className="inline-flex items-center justify-center gap-2 px-5 py-3 rounded-[12px] bg-transparent border border-tono-border-strong text-tono-text hover:border-tono-accent font-semibold transition min-h-[44px] text-[14px]"
                >
                  sign out
                </button>
              </form>
            </section>
          </div>
        )}
      </div>
    </main>
  )
}
