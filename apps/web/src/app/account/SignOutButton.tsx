'use client'

// Sign-out control. Before handing off to the server route that clears the
// session cookies, it purges every account's device-local rewrite history from
// this browser — the server cannot reach localStorage, so without this a shared
// device would keep the previous person's drafts for whoever signs in next.

import { purgeAllHistory } from '../../lib/history-store'

export default function SignOutButton() {
  const onSubmit = () => {
    try {
      if (typeof window !== 'undefined') purgeAllHistory(window.localStorage)
    } catch {
      // localStorage may be unavailable (private mode); the server sign-out
      // still proceeds.
    }
  }

  return (
    <form action="/app/api/auth/signout" method="post" className="mt-6" onSubmit={onSubmit}>
      <button
        type="submit"
        className="inline-flex items-center justify-center gap-2 px-5 py-3 rounded-[12px] bg-transparent border border-tono-border-strong text-tono-text hover:border-tono-accent font-semibold transition min-h-[44px] text-[14px]"
      >
        sign out
      </button>
    </form>
  )
}
