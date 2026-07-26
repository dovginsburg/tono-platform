// /app/auth/reset — choose a new password.
//
// The screen Build 114 promised on three surfaces and shipped on none. iOS and
// Android both say "open the link we sent to choose a new password"; the link
// landed on the auth callback, which signed the person into the website and
// dropped them in the editor. There was no password field anywhere in the
// product, so the flow could not complete and the person went back to the app
// still locked out.
//
// Server component on purpose: the recovery session either exists or it does
// not, and that is knowable here — before anyone types a password only to be
// told the link was dead. A spent or expired link gets its own panel with the
// one action that helps, which is asking for another.

import Link from 'next/link';

import { createServerSupabase } from '@/lib/supabase';
import { LOGIN_PATH } from '@/lib/auth-redirects';
import { EMAIL_AUTH_COPY } from '@/lib/email-auth';
import { ResetPasswordForm } from './reset-client';

export const dynamic = 'force-dynamic';

export default async function ResetPasswordPage() {
  let hasRecoverySession = false;
  try {
    const supabase = await createServerSupabase();
    const { data } = await supabase.auth.getUser();
    hasRecoverySession = !!data?.user;
  } catch {
    // Treated as "no session". The recovery panel's advice — request another
    // link — is the right next step whether the link is dead or the check
    // could not run, and it is the only one that can help either way.
    hasRecoverySession = false;
  }

  return (
    <div className="min-h-screen bg-tono-bg text-tono-text font-sans antialiased">
      <header className="sticky top-0 z-30 bg-tono-bg/80 backdrop-blur-md border-b border-tono-border">
        <div className="max-w-[1180px] mx-auto px-6 md:px-10 py-4 flex items-center">
          <Link href="/" className="flex items-center gap-2.5 shrink-0" aria-label="tono — back to home">
            <span
              aria-hidden="true"
              className="w-3 h-3 rounded-full bg-tono-accent shadow-[0_0_16px_var(--accent-glow)]"
            />
            <span className="text-[22px] font-bold tracking-[-0.02em] text-tono-text">tono</span>
          </Link>
        </div>
      </header>

      <main className="grid place-items-center px-6 py-12 md:py-20">
        <div className="w-full max-w-[440px] bg-tono-bg-card border border-tono-border rounded-[18px] p-7 md:p-8 shadow-[0_24px_64px_rgba(0,0,0,0.4)]">
          <h1 className="text-[28px] md:text-[32px] font-bold tracking-[-0.02em] text-tono-text leading-[1.15]">
            choose a new password.
          </h1>

          {hasRecoverySession ? (
            <>
              <p className="text-tono-text-softer text-[14px] mt-2 mb-7">
                pick something you&apos;ll remember. you&apos;ll use it on every device.
              </p>
              <ResetPasswordForm />
            </>
          ) : (
            <>
              <p className="text-tono-text-softer text-[14px] mt-2 mb-6">
                {EMAIL_AUTH_COPY.link_expired}
              </p>
              <Link
                href={LOGIN_PATH}
                className="w-full inline-flex items-center justify-center px-5 py-3 rounded-[12px] bg-tono-accent hover:bg-tono-accent-hover text-white font-semibold text-[14px] transition min-h-[48px]"
              >
                request a new link
              </Link>
            </>
          )}
        </div>
      </main>
    </div>
  );
}
