import assert from 'node:assert/strict';
import test from 'node:test';

import {
  isTonoAppleServicesId,
  appleWebSignInEnabled,
  APPLE_WEB_UNAVAILABLE_COPY,
} from './apple-oauth-binding.ts';

test('fails closed when no Services ID is configured', () => {
  assert.equal(appleWebSignInEnabled(undefined), false);
  assert.equal(appleWebSignInEnabled(''), false);
  assert.equal(appleWebSignInEnabled('   '), false);
  assert.equal(appleWebSignInEnabled(null), false);
});

test('rejects the contaminated sibling-product Services ID', () => {
  // The live blocker: the shared Supabase project is bound to this. It must
  // NEVER satisfy the gate, whether or not an operator pastes it in.
  assert.equal(appleWebSignInEnabled('parentscript.app'), false);
  assert.equal(appleWebSignInEnabled('com.parentscript.web'), false);
  assert.equal(isTonoAppleServicesId('parentscript.app'), false);
});

test('accepts a Tono-owned reverse-DNS Services ID', () => {
  assert.equal(isTonoAppleServicesId('com.tono.web'), true);
  assert.equal(isTonoAppleServicesId('app.tonoit.signin'), true);
  assert.equal(isTonoAppleServicesId('tonoit.web'), true);
  assert.equal(isTonoAppleServicesId('TONO.web'), true); // case-insensitive
});

test('a lookalike host cannot pass as a substring', () => {
  assert.equal(isTonoAppleServicesId('nottono.app'), false);
  assert.equal(isTonoAppleServicesId('tonopoly.web'), false);
  assert.equal(isTonoAppleServicesId('com.notatono'), false);
});

test('an operator-pinned expected id is matched by strict equality', () => {
  // With an expected id set, only that exact value passes — even a Tono-shaped
  // one that differs is rejected (protects against a stale/wrong config).
  assert.equal(appleWebSignInEnabled('com.tono.web', 'com.tono.web'), true);
  assert.equal(appleWebSignInEnabled('com.tono.other', 'com.tono.web'), false);
  // And the contaminated value never matches an expected Tono pin.
  assert.equal(appleWebSignInEnabled('parentscript.app', 'com.tono.web'), false);
});

test('recovery copy names the two paths that work and never claims Apple works', () => {
  assert.match(APPLE_WEB_UNAVAILABLE_COPY, /google/i);
  assert.match(APPLE_WEB_UNAVAILABLE_COPY, /email/i);
});
