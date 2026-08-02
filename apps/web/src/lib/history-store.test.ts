import { test } from 'node:test'
import assert from 'node:assert/strict'

import {
  LEGACY_HISTORY_KEY,
  HISTORY_KEY_PREFIX,
  historyStorageKey,
  dropLegacyHistory,
  purgeAllHistory,
} from './history-store.ts'

// Minimal in-memory Storage stand-in with the DOM Storage surface the helpers
// touch (getItem/setItem/removeItem/length/key).
function fakeStorage(): Storage {
  const map = new Map<string, string>()
  return {
    get length() {
      return map.size
    },
    clear() {
      map.clear()
    },
    getItem(k: string) {
      return map.has(k) ? (map.get(k) as string) : null
    },
    key(i: number) {
      return Array.from(map.keys())[i] ?? null
    },
    removeItem(k: string) {
      map.delete(k)
    },
    setItem(k: string, v: string) {
      map.set(k, v)
    },
  } as Storage
}

test('historyStorageKey namespaces by account id', () => {
  assert.equal(historyStorageKey('user-a'), `${HISTORY_KEY_PREFIX}user-a`)
  assert.equal(historyStorageKey('user-b'), `${HISTORY_KEY_PREFIX}user-b`)
  // Two different accounts never collide.
  assert.notEqual(historyStorageKey('user-a'), historyStorageKey('user-b'))
})

test('historyStorageKey falls to a distinct anon bucket for empty ids', () => {
  assert.equal(historyStorageKey(''), `${HISTORY_KEY_PREFIX}anon`)
  assert.equal(historyStorageKey(null), `${HISTORY_KEY_PREFIX}anon`)
  assert.equal(historyStorageKey(undefined), `${HISTORY_KEY_PREFIX}anon`)
  // The anon bucket is still different from any signed-in account.
  assert.notEqual(historyStorageKey(null), historyStorageKey('user-a'))
})

test('account A cannot read account B history through the namespaced key', () => {
  const s = fakeStorage()
  s.setItem(historyStorageKey('A'), JSON.stringify([{ id: 'a1' }]))
  // B reads its own (empty) namespace, never A's rows.
  assert.equal(s.getItem(historyStorageKey('B')), null)
})

test('dropLegacyHistory removes the unattributable global blob only once', () => {
  const s = fakeStorage()
  s.setItem(LEGACY_HISTORY_KEY, JSON.stringify([{ id: 'legacy' }]))
  s.setItem(historyStorageKey('A'), JSON.stringify([{ id: 'a1' }]))
  assert.equal(dropLegacyHistory(s), true)
  assert.equal(s.getItem(LEGACY_HISTORY_KEY), null)
  // The account namespace is untouched.
  assert.ok(s.getItem(historyStorageKey('A')))
  // Idempotent: a second call finds nothing to remove.
  assert.equal(dropLegacyHistory(s), false)
})

test('purgeAllHistory clears every namespace and the legacy key on sign-out', () => {
  const s = fakeStorage()
  s.setItem(LEGACY_HISTORY_KEY, '[]')
  s.setItem(historyStorageKey('A'), '[{"id":"a"}]')
  s.setItem(historyStorageKey('B'), '[{"id":"b"}]')
  s.setItem('unrelated:key', 'keep-me')
  purgeAllHistory(s)
  assert.equal(s.getItem(LEGACY_HISTORY_KEY), null)
  assert.equal(s.getItem(historyStorageKey('A')), null)
  assert.equal(s.getItem(historyStorageKey('B')), null)
  // Non-history keys are left alone.
  assert.equal(s.getItem('unrelated:key'), 'keep-me')
})
