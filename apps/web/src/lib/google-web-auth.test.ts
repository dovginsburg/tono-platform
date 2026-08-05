import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  looksLikeGoogleClientId,
  readGooglePublicClientId,
  GIS_CLIENT_SRC,
} from './google-web-auth.ts';

const VALID_CLIENT = '417785080360-3pjqr5862858hc3capb5772ajd5kap48.apps.googleusercontent.com';

test('looksLikeGoogleClientId accepts a real web client id, rejects foreign values', () => {
  assert.equal(looksLikeGoogleClientId(VALID_CLIENT), true);
  assert.equal(looksLikeGoogleClientId('not-a-client'), false);
  assert.equal(looksLikeGoogleClientId('tonoit.com'), false);
  assert.equal(looksLikeGoogleClientId(''), false);
  assert.equal(looksLikeGoogleClientId(undefined), false);
});

test('readGooglePublicClientId returns the id only when well-shaped (fail closed)', () => {
  assert.equal(readGooglePublicClientId({ NEXT_PUBLIC_GOOGLE_WEB_CLIENT_ID: VALID_CLIENT }), VALID_CLIENT);
  assert.equal(readGooglePublicClientId({ NEXT_PUBLIC_GOOGLE_WEB_CLIENT_ID: 'bogus' }), '');
  assert.equal(readGooglePublicClientId({}), '');
});

test('GIS is loaded from the official Google Identity Services origin', () => {
  assert.equal(GIS_CLIENT_SRC, 'https://accounts.google.com/gsi/client');
});
