// Build 114 — the web surface's email-account vocabulary.
//
// The website used to offer exactly one email affordance: a magic link. That
// left three of the five flows the product promises — register with a password,
// sign in with it, and finish a password reset — reachable on iOS and Android
// and nowhere on the web, and it left "forgot your password?" a dead end on
// every surface, because the link those two clients mail out lands on the web
// and the web had no screen that could set a password.
//
// This module is the closed vocabulary that surface speaks. Two rules, both
// load bearing:
//
//   1. A failure is a CODE, never a message. Nothing the backend or the auth
//      provider writes is ever rendered — not a status, not a host, not an
//      `error_description`. The page owns the words, and every word is here.
//
//   2. Asking for mail is answered identically whether or not the address is
//      registered. Register, resend and reset all resolve to
//      `check_your_email`. The failures that DO stay distinct are the ones an
//      outsider can already observe (being throttled, an outage) or that
//      describe the string the person just typed — neither of which says
//      whether an account exists.

export const EMAIL_AUTH_OUTCOMES = [
  'check_your_email',
  'signed_in',
  'password_updated',
  'invalid_credentials',
  'verification_required',
  'invalid_input',
  'password_mismatch',
  'link_expired',
  'account_conflict',
  'rate_limited',
  'unavailable',
  'offline',
  'unknown_failure',
] as const;

export type EmailAuthOutcome = (typeof EMAIL_AUTH_OUTCOMES)[number];

/** Keep only a reviewed code. Anything else is dropped, never displayed. */
export function sanitizeEmailAuthOutcome(
  raw: string | null | undefined
): EmailAuthOutcome | null {
  return EMAIL_AUTH_OUTCOMES.includes(raw as EmailAuthOutcome)
    ? (raw as EmailAuthOutcome)
    : null;
}

// The ONLY sentences this surface can show for an email-account outcome.
//
// Lower case and plain, matching the rest of the product's voice. No status
// code, no provider name, no host, no field name, no "token"/"endpoint"/"API".
// Every one of them ends somewhere the person can actually go next — a failure
// with no next step is the defect this build is fixing, not a style problem.
export const EMAIL_AUTH_COPY: Record<EmailAuthOutcome, string> = {
  check_your_email: 'check your inbox. open the link we sent to finish.',
  signed_in: "you're signed in.",
  password_updated: 'your password is updated.',
  invalid_credentials: "that email and password don't match. try again.",
  verification_required: 'confirm your email first — open the link we sent you.',
  invalid_input:
    "that address or password can't be used. try a different password, or check the address.",
  password_mismatch: "those two passwords don't match. type them again.",
  link_expired: 'that link has expired. request a new one below.',
  account_conflict:
    'that address is already spoken for. sign in the way you did before, or use another address.',
  rate_limited: 'too many tries just now. wait a minute and try again.',
  unavailable: "email sign-in isn't available right now. try again in a few minutes.",
  offline: "couldn't reach tono. check your connection and try again.",
  unknown_failure: "that didn't go through. try again.",
};

/** The shortest password this surface will submit. Mirrors the server floor. */
export const MIN_PASSWORD_LENGTH = 8;

/**
 * Shape-only address check, used to keep an obviously-unsendable string from
 * becoming a request. Deliberately permissive: the server and the auth
 * provider own the real rules, and being stricter here would reject addresses
 * that genuinely work.
 */
export function looksLikeEmail(value: string): boolean {
  const trimmed = value.trim();
  if (!trimmed || /\s/.test(trimmed)) return false;
  const at = trimmed.lastIndexOf('@');
  if (at <= 0 || at === trimmed.length - 1) return false;
  return trimmed.slice(at + 1).includes('.');
}

/**
 * Local check before a password is submitted.
 *
 * Returns a code or null. `password_mismatch` is checked FIRST on purpose: if
 * someone typed two different things, telling them the second one is too short
 * answers a question they did not ask.
 */
export function validateNewPassword(
  password: string,
  confirmation: string
): EmailAuthOutcome | null {
  if (password !== confirmation) return 'password_mismatch';
  if (password.length < MIN_PASSWORD_LENGTH) return 'invalid_input';
  return null;
}

/**
 * Turn a canonical-backend response status into a consumer outcome.
 *
 * The status is the ONLY thing read. The body is never consulted, so no
 * sentence written by the backend or forwarded from the auth provider can
 * reach a screen through this path — which is what keeps the surface free of
 * provider detail even when a new failure shape appears upstream.
 *
 * `accepted` names what a success means for this call: asking for mail
 * resolves to `check_your_email` (identical for a known and an unknown
 * address), a login resolves to `signed_in`.
 */
export function classifyBackendStatus(
  status: number,
  accepted: EmailAuthOutcome
): EmailAuthOutcome {
  if (status >= 200 && status < 300) return accepted;
  switch (status) {
    case 400:
      return 'invalid_input';
    case 401:
      return 'invalid_credentials';
    case 403:
      return 'verification_required';
    case 409:
      return 'account_conflict';
    case 429:
      return 'rate_limited';
    default:
      // 5xx and anything unrecognised are both "we could not serve this",
      // which is the same thing to the person and has the same next step.
      return status >= 500 ? 'unavailable' : 'unknown_failure';
  }
}

/**
 * The whole decision table for finishing a password reset.
 *
 * Extracted from the route handler so it can be EXECUTED by a test rather than
 * only inspected. The route around it does I/O and nothing else; every choice
 * about what the person is told is made here, which is what makes "an expired
 * link is never reported as a generic failure" a property with a test behind
 * it instead of a claim in a comment.
 *
 * `hasSession` is false when the recovery link has expired, has already been
 * spent, or was never followed — by far the most likely way this flow fails,
 * and the one with its own next step.
 */
export function resolvePasswordUpdate(input: {
  password: string;
  confirmation: string;
  hasSession: boolean;
  updateError?: unknown;
}): EmailAuthOutcome {
  // Local checks first: there is no point spending a single-use recovery
  // session on a password the person did not mean to set.
  const local = validateNewPassword(input.password, input.confirmation);
  if (local) return local;
  if (!input.hasSession) return 'link_expired';
  if (input.updateError) return classifyProviderFailure(input.updateError);
  return 'password_updated';
}

/**
 * Turn an auth-provider failure into a consumer outcome, by SHAPE.
 *
 * Reads only the numeric status the provider client exposes. A recovery
 * session that has expired or been spent presents as 401/403/410, and that is
 * worth keeping distinct from a generic failure because its next step is
 * different: ask for another link.
 */
export function classifyProviderFailure(error: unknown): EmailAuthOutcome {
  const status = (error as { status?: number } | null | undefined)?.status;
  if (status === 429) return 'rate_limited';
  if (status === 401 || status === 403 || status === 410) return 'link_expired';
  if (status === 422 || status === 400) return 'invalid_input';
  if (typeof status === 'number' && status >= 500) return 'unavailable';
  return 'unknown_failure';
}
