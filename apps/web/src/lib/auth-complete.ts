// Completing the IMPLICIT-flow email links (verification + password recovery).
//
// Why this module has to exist. The email-account flows the backend brokers —
// register, resend confirmation, and password reset — are started SERVER-side:
// the backend calls Supabase's /auth/v1/{signup,resend,recover} over httpx with
// no PKCE `code_challenge`. GoTrue therefore mails a link that, when followed,
// verifies the token and 303-redirects to our callback carrying the freshly
// minted session in the URL FRAGMENT (`#access_token=…&type=…`) — the implicit
// grant. A fragment is never sent to a server: it is not in the request line,
// so the server-only /auth/callback handler, which reads only `?code=` (the
// PKCE shape our BROWSER-initiated OAuth and magic-link flows produce), cannot
// see it. Every brokered link consequently dead-ended at the login page with no
// session established. Recovery was the worst case: the person reached a screen
// that could never set a password — the exact dead end Build 114 tried to close
// and could not, because the remedy lived on the server and the only evidence
// ever existed in the browser.
//
// So the fragment is read in the browser (the callback serves a tiny document
// for exactly that), posted ONCE to /api/auth/email/complete, and settled
// server-side there. This module is the PURE decision half — extracted so a
// test can EXECUTE it, mirroring how `resolvePasswordUpdate` was lifted out of
// the reset route. It speaks the same reviewed vocabulary as the rest of the
// surface: a CODE, never a provider sentence, so no GoTrue error text can reach
// a screen through here either.

import {
  APP_ENTRY_PATH,
  AUTH_RESET_PATH,
  LOGIN_PATH,
  sanitizeNextPath,
  type AuthErrorCode,
} from './auth-redirects.ts';

/**
 * Map GoTrue's implicit-flow error fragment (`#error=…&error_code=…`) to one of
 * the four reviewed callback codes the login page renders.
 *
 * Reads ONLY the stable machine `error`/`error_code`, never `error_description`
 * (free-form provider text). An expired or already-spent link is by far the
 * common failure and keeps its own next step ("ask for a new one"), so it stays
 * distinct from a generic failure.
 */
export function classifyFragmentError(
  error?: string | null,
  errorCode?: string | null,
): AuthErrorCode {
  const code = (errorCode || '').toLowerCase();
  const err = (error || '').toLowerCase();
  if (code.includes('expired') || code === 'otp_expired' || err === 'access_denied') {
    return 'link_expired';
  }
  if (code.includes('rate') || code.includes('over_email_send')) return 'rate_limited';
  if (code.includes('server') || code.includes('unexpected') || err.includes('server')) {
    return 'unavailable';
  }
  return 'sign_in_failed';
}

/**
 * Classify a `setSession` rejection by STATUS only — the same rule every other
 * path on this surface follows. A confirmation/recovery token that expired or
 * was spent between the click and this POST presents as 401/403/410 and is kept
 * distinct because its next step differs: request another link.
 */
export function classifySetSessionFailure(status?: number | null): AuthErrorCode {
  if (status === 429) return 'rate_limited';
  if (status === 401 || status === 403 || status === 410) return 'link_expired';
  if (typeof status === 'number' && status >= 500) return 'unavailable';
  return 'sign_in_failed';
}

/**
 * A login path carrying a reviewed error code and the preserved (sanitized)
 * `next`. Returns a RELATIVE path — the browser lands on it with
 * `location.replace`, and the server never echoes caller input into it.
 */
export function loginPathWithError(code: AuthErrorCode, next?: string | null): string {
  const params = new URLSearchParams();
  params.set('next', sanitizeNextPath(next));
  params.set('error', code);
  return `${LOGIN_PATH}?${params.toString()}`;
}

/**
 * Is this completion a password recovery? `type=recovery` is GoTrue's own
 * fragment marker; `flow=recovery` is ours (the backend appends it to the
 * recovery redirect target — see email_auth.RECOVERY_FLOW_MARKER). Either one
 * settles it, matching `isRecoveryCallback`. It matters that this is a MARKER
 * and not a guess: a recovery that is merely signed in and dropped into the
 * editor is the dead end being fixed.
 */
export function isRecoveryCompletion(
  fragmentType?: string | null,
  flowParam?: string | null,
): boolean {
  return fragmentType === 'recovery' || flowParam === 'recovery';
}

export type CompleteInput = {
  /** The fragment carried a GoTrue error (`#error`/`#error_code`) — link failed. */
  fragmentError?: string | null;
  fragmentErrorCode?: string | null;
  /** The fragment carried a session (both tokens present). */
  hasTokens: boolean;
  /** Whether `setSession` accepted the tokens. */
  sessionEstablished: boolean;
  /** Status of a `setSession` failure, for classification. */
  sessionFailureStatus?: number | null;
  /** This completion is a recovery (fragment `type=recovery` or `?flow=recovery`). */
  recovery: boolean;
  /** Where the person was headed before the link (usually absent for brokered mail). */
  next?: string | null;
};

/**
 * The whole decision table for finishing an implicit-flow email link.
 *
 * Extracted so a test EXECUTES it rather than only inspecting it — the route
 * around it does I/O (setSession, mint the canonical bearer) and nothing else.
 * Every returned value is an internal path built from constants and
 * `sanitizeNextPath`; caller input is never echoed, so this cannot become an
 * open redirect.
 */
export function resolveCompleteRedirect(input: CompleteInput): string {
  // A failed link (expired / spent / provider error) goes back to sign-in with
  // the one reviewed sentence that offers a next step. Recovery failures land
  // there too: the reset screen needs a live session a dead link cannot give,
  // and the login page's "forgot your password?" is the way to another link.
  if (input.fragmentError || input.fragmentErrorCode) {
    return loginPathWithError(
      classifyFragmentError(input.fragmentError, input.fragmentErrorCode),
      input.next,
    );
  }
  // No session in the fragment and no error — nothing to complete. Match the
  // callback's pre-existing "no code, no error" behaviour: quietly to sign-in.
  if (!input.hasTokens) return LOGIN_PATH;
  // Tokens were present but the provider refused them (expired in the gap before
  // this POST, or malformed) — classified by status, never by message.
  if (!input.sessionEstablished) {
    return loginPathWithError(classifySetSessionFailure(input.sessionFailureStatus), input.next);
  }
  // Session established. A recovery lands on the password screen and nowhere
  // else; everything else on wherever the person was headed (default: editor).
  if (input.recovery) return AUTH_RESET_PATH;
  return sanitizeNextPath(input.next) || APP_ENTRY_PATH;
}

/**
 * The document the callback serves when a link lands with its session (or its
 * error) in the fragment.
 *
 * It runs in the browser precisely because a fragment exists nowhere else: it
 * reads `#access_token`/`#error`, posts them ONCE to the server half, and
 * follows the single reviewed path that comes back. It renders no provider
 * text, carries `noindex`, and uses `location.replace` so the token does not
 * linger in history. STATIC — no value is ever interpolated into it, so it is
 * not a template and cannot carry injected data. Guarded by auth-complete.test.
 */
export const FRAGMENT_BOUNCE_HTML = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>finishing sign-in…</title>
</head>
<body style="margin:0;min-height:100vh;display:grid;place-items:center;background:#0f0f10;color:#e8e8ea;font-family:system-ui,-apple-system,'Segoe UI',Roboto,sans-serif">
<p style="font-size:14px;opacity:.75">finishing sign-in…</p>
<noscript><a href="/app/login" style="color:#8ab4f8">continue to sign in</a></noscript>
<script>
(function () {
  function go(p) { location.replace(p || '/app/login'); }
  try {
    var frag = new URLSearchParams((location.hash || '').replace(/^#/, ''));
    var query = new URLSearchParams(location.search || '');
    var accessToken = frag.get('access_token');
    var refreshToken = frag.get('refresh_token');
    var err = frag.get('error');
    var errCode = frag.get('error_code');
    // Nothing actionable in the fragment: behave like the old empty callback.
    if (!accessToken && !err && !errCode) { go('/app/login'); return; }
    fetch('/app/api/auth/email/complete', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        access_token: accessToken || '',
        refresh_token: refreshToken || '',
        type: frag.get('type') || '',
        flow: query.get('flow') || '',
        error: err || '',
        error_code: errCode || '',
        next: query.get('next') || ''
      })
    })
      .then(function (r) { return r.json(); })
      .then(function (d) { go(d && d.redirect); })
      .catch(function () { go('/app/login?error=unavailable'); });
  } catch (e) { go('/app/login'); }
})();
</script>
</body>
</html>`;
