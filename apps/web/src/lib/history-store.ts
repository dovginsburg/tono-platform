// Local rewrite-history storage keys and isolation helpers.
//
// History is kept on-device (the product deliberately never uploads message
// content). The defect this module fixes: the original single global key
// `tono:history` was shared by every account that used the same browser, so a
// second person signing in saw the first person's rewrites, and sign-out never
// cleared it.
//
// Fix: namespace the store by the signed-in account id. Account A and account B
// read DIFFERENT keys, so neither can ever see the other's history — the
// account-switch isolation the account model already guarantees server-side.
// The pre-namespacing global blob carries no owner tag, so it cannot be safely
// attributed to whoever logs in next; we therefore DISCARD it rather than risk
// handing one person's drafts to another. Continuity across reinstall/second
// device is provided by the server account, not this device-local cache.

export const LEGACY_HISTORY_KEY = 'tono:history'
export const HISTORY_KEY_PREFIX = 'tono:history:v2:'

/** The per-account localStorage key. Empty/unknown ids fall to a shared
 *  anonymous bucket that is still distinct from any signed-in account. */
export function historyStorageKey(userId: string | null | undefined): string {
  return `${HISTORY_KEY_PREFIX}${userId && userId.length > 0 ? userId : 'anon'}`
}

/** Remove the unattributable pre-namespacing global blob if present. Safe to
 *  call on every read/write; returns true when it actually removed something. */
export function dropLegacyHistory(storage: Storage): boolean {
  if (storage.getItem(LEGACY_HISTORY_KEY) === null) return false
  storage.removeItem(LEGACY_HISTORY_KEY)
  return true
}

/** Purge every account's local history (all namespaces + the legacy key). Used
 *  on sign-out so a shared device does not leave one account's drafts behind
 *  for the next person. */
export function purgeAllHistory(storage: Storage): void {
  const doomed: string[] = []
  for (let i = 0; i < storage.length; i++) {
    const k = storage.key(i)
    if (k && (k === LEGACY_HISTORY_KEY || k.startsWith(HISTORY_KEY_PREFIX))) {
      doomed.push(k)
    }
  }
  for (const k of doomed) storage.removeItem(k)
}
