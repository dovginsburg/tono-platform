import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';

const root = join(process.cwd(), 'src', 'app');
const source = (path: string) => readFileSync(join(root, path), 'utf8');

test('signup exposes an optional promo and forwards only to the server route', () => {
  const page = source('login/page.tsx');
  const route = source('api/auth/email/register/route.ts');
  assert.match(page, /promo code/);
  assert.match(page, /promo_code: promoCode/);
  assert.match(route, /promo_code: promoCode \|\| undefined/);
  assert.match(route, /status: 200/);
});

test('signed-in redemption exchanges the httpOnly bearer server-side', () => {
  const route = source('api/coupon/redeem/route.ts');
  const ui = source('account/PromoRedemption.tsx');
  const vercel = readFileSync(join(process.cwd(), 'vercel.json'), 'utf8');
  assert.match(route, /get\('tono_api_token'\)/);
  assert.match(route, /Authorization: `Bearer \$\{token\}`/);
  assert.doesNotMatch(ui, /tono_api_token|Authorization|Bearer/);
  assert.match(ui, /window\.location\.reload/);
  assert.doesNotMatch(vercel, /"source": "\/api\/coupon\/redeem"/);
});
