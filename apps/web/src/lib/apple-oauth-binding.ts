// Web "Continue with Apple" — a fail-closed product-branding gate.
//
// The website starts Apple sign-in through Supabase's OAuth authorize endpoint,
// which redirects to appleid.apple.com using the Apple *Services ID* configured
// on the Supabase project's Apple provider — a value that lives in the Supabase
// dashboard, NOT in this bundle. On the shared project that binding is currently
// a SIBLING PRODUCT's Services ID, so Apple shows "Use your Apple Account to
// sign in to <that other product>." Sending a Tono user into another product's
// consent screen is a hard blocker.
//
// The browser cannot read the dashboard binding, so correctness here is an
// operator ATTESTATION: the Apple button stays hidden until an operator names
// the corrected Tono Services ID in `NEXT_PUBLIC_APPLE_WEB_SERVICES_ID` (set
// only once the Supabase Apple provider is re-bound to Tono's own Services ID).
// Absent that — today's live state — the button is unavailable and the page
// shows truthful recovery copy instead of a control that would redirect into
// the sibling product's consent screen.
//
// Why an ALLOWLIST by Tono shape, never a denylist of the sibling id: embedding
// the contaminated literal in this module would itself put a sibling tenant's
// client id into the compiled artifact — the exact thing the contract forbids.
// We instead require the configured value to be a Tono-owned reverse-DNS
// Services ID (or to exactly equal an operator-pinned expected id), so a
// copy-paste of the contaminated value can never satisfy the gate.

/**
 * True only when `id` is a Tono-owned Apple Services ID.
 *
 * When `expected` is provided (operator pins the exact Services ID they
 * configured on Supabase), the match is strict equality — the safest form.
 * Otherwise the value must sit in a Tono-owned reverse-DNS namespace
 * (`tonoit`/`tono`), which a foreign product's Services ID cannot satisfy.
 */
export function isTonoAppleServicesId(
  id: string | undefined | null,
  expected?: string | undefined | null,
): boolean {
  const value = (id ?? '').trim().toLowerCase();
  if (!value) return false;

  const exp = (expected ?? '').trim().toLowerCase();
  if (exp) return value === exp;

  // Tono-owned reverse-DNS Services ID, e.g. `com.tono.web`, `app.tonoit.web`,
  // `tonoit.web`. The `tono`/`tonoit` label must be a whole dotted segment so a
  // lookalike host (e.g. `nottono.app`) cannot slip through as a substring.
  return /(^|\.)(tono|tonoit)(\.|$)/.test(value);
}

/** Whether the web Apple OAuth button may render at all (fail closed). */
export function appleWebSignInEnabled(
  servicesId: string | undefined | null,
  expected?: string | undefined | null,
): boolean {
  return isTonoAppleServicesId(servicesId, expected);
}

/**
 * Shown in place of the Apple button while the provider binding is unverified.
 * Truthful (it is genuinely being finished), and it points at the two sign-in
 * paths that DO work today, so no one is stranded.
 */
export const APPLE_WEB_UNAVAILABLE_COPY =
  'apple sign-in for tono is being finished — use google or email below for now.';
