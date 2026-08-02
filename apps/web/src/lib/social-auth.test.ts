import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  APPLE_ICON_PATH,
  APPLE_ICON_VIEWBOX,
  isAppleWebOAuthEnabled,
  isGoogleWebOAuthEnabled,
} from './social-auth.ts';

// ---------------------------------------------------------------------------
// 1. The web OAuth buttons are OFF by default and only 'true' opens them.
//
// Containment for the cross-brand `client_id` / account-fragmentation incident:
// neither provider may render unless its OWN public flag is the literal 'true'.
// A truthy fallback ('1', 'yes', a stray non-empty value) must NOT re-expose it,
// and enabling one provider must NEVER implicitly enable the other.
// ---------------------------------------------------------------------------

test('both web OAuth providers are disabled when no flags are set', () => {
  assert.equal(isAppleWebOAuthEnabled({}), false);
  assert.equal(isGoogleWebOAuthEnabled({}), false);
});

test("only the exact string 'true' enables a provider", () => {
  for (const bad of ['', 'false', 'FALSE', 'True', 'TRUE', '1', 'yes', 'on', ' true', undefined]) {
    assert.equal(
      isAppleWebOAuthEnabled({ NEXT_PUBLIC_TONO_WEB_APPLE_OAUTH_ENABLED: bad }),
      false,
      `apple must stay OFF for ${JSON.stringify(bad)}`
    );
    assert.equal(
      isGoogleWebOAuthEnabled({ NEXT_PUBLIC_TONO_WEB_GOOGLE_OAUTH_ENABLED: bad }),
      false,
      `google must stay OFF for ${JSON.stringify(bad)}`
    );
  }
  assert.equal(
    isAppleWebOAuthEnabled({ NEXT_PUBLIC_TONO_WEB_APPLE_OAUTH_ENABLED: 'true' }),
    true
  );
  assert.equal(
    isGoogleWebOAuthEnabled({ NEXT_PUBLIC_TONO_WEB_GOOGLE_OAUTH_ENABLED: 'true' }),
    true
  );
});

test('the two provider flags are independent — no shared fallback', () => {
  // Turning Apple on must not turn Google on, and vice versa.
  const appleOnly = { NEXT_PUBLIC_TONO_WEB_APPLE_OAUTH_ENABLED: 'true' };
  assert.equal(isAppleWebOAuthEnabled(appleOnly), true);
  assert.equal(isGoogleWebOAuthEnabled(appleOnly), false);

  const googleOnly = { NEXT_PUBLIC_TONO_WEB_GOOGLE_OAUTH_ENABLED: 'true' };
  assert.equal(isGoogleWebOAuthEnabled(googleOnly), true);
  assert.equal(isAppleWebOAuthEnabled(googleOnly), false);
});

// ---------------------------------------------------------------------------
// 2. The Apple icon path renders inside its 0 0 24 24 viewBox.
//
// The previous hand-tuned path extended past the bottom edge and clipped on
// mobile. We parse the `d` string, resolve every command to absolute
// coordinates, and assert every point lies within the viewBox. A cubic/quadratic
// Bézier is contained in the convex hull of its control points, so bounding all
// command points (endpoints AND control points) bounds the rendered glyph.
// ---------------------------------------------------------------------------

// Resolve an SVG path `d` into the list of absolute (x, y) points it references
// (endpoints and control points). Supports the M/L/C/S/Q/T/Z commands and their
// relative forms — enough for a normalized single-glyph icon.
function pathPoints(d: string): Array<[number, number]> {
  const tokens = d.match(/[a-zA-Z]|-?\d*\.?\d+(?:e-?\d+)?/g) ?? [];
  const points: Array<[number, number]> = [];
  let i = 0;
  let cx = 0;
  let cy = 0;
  let startX = 0;
  let startY = 0;
  let cmd = '';

  const num = () => Number(tokens[i++]);
  const isCmd = (t: string) => /^[a-zA-Z]$/.test(t);

  while (i < tokens.length) {
    if (isCmd(tokens[i])) cmd = tokens[i++];
    const rel = cmd === cmd.toLowerCase();
    const abs = (x: number, y: number): [number, number] =>
      rel ? [cx + x, cy + y] : [x, y];

    switch (cmd.toUpperCase()) {
      case 'M': {
        [cx, cy] = abs(num(), num());
        startX = cx;
        startY = cy;
        points.push([cx, cy]);
        cmd = rel ? 'l' : 'L'; // subsequent implicit pairs are line-tos
        break;
      }
      case 'L':
      case 'T': {
        [cx, cy] = abs(num(), num());
        points.push([cx, cy]);
        break;
      }
      case 'C': {
        points.push(abs(num(), num()));
        points.push(abs(num(), num()));
        [cx, cy] = abs(num(), num());
        points.push([cx, cy]);
        break;
      }
      case 'S':
      case 'Q': {
        points.push(abs(num(), num()));
        [cx, cy] = abs(num(), num());
        points.push([cx, cy]);
        break;
      }
      case 'Z': {
        cx = startX;
        cy = startY;
        break;
      }
      default:
        throw new Error(`unsupported path command: ${cmd}`);
    }
  }
  return points;
}

test('APPLE_ICON_VIEWBOX is the normalized 24×24 box', () => {
  assert.equal(APPLE_ICON_VIEWBOX, '0 0 24 24');
});

test('every Apple icon path point lies within its viewBox', () => {
  const [minX, minY, w, h] = APPLE_ICON_VIEWBOX.split(/\s+/).map(Number);
  const maxX = minX + w;
  const maxY = minY + h;
  const tol = 0.05; // sub-pixel rounding slack

  const points = pathPoints(APPLE_ICON_PATH);
  assert.ok(points.length > 0, 'path must contain drawable points');

  for (const [x, y] of points) {
    assert.ok(
      x >= minX - tol && x <= maxX + tol,
      `x=${x} outside [${minX}, ${maxX}] — icon clips horizontally`
    );
    assert.ok(
      y >= minY - tol && y <= maxY + tol,
      `y=${y} outside [${minY}, ${maxY}] — icon clips vertically`
    );
  }
});

// ---------------------------------------------------------------------------
// 3. The login page actually wires the buttons through the off-by-default gate
//    and uses the shared icon geometry — so the fix can't silently regress.
// ---------------------------------------------------------------------------

test('login page gates both OAuth buttons behind the off-by-default flags', () => {
  const pagePath = join(
    dirname(fileURLToPath(import.meta.url)),
    '..',
    'app',
    'login',
    'page.tsx'
  );
  const src = readFileSync(pagePath, 'utf8');

  for (const token of [
    'isAppleWebOAuthEnabled',
    'isGoogleWebOAuthEnabled',
    'NEXT_PUBLIC_TONO_WEB_APPLE_OAUTH_ENABLED',
    'NEXT_PUBLIC_TONO_WEB_GOOGLE_OAUTH_ENABLED',
    'APPLE_ICON_PATH',
  ]) {
    assert.ok(src.includes(token), `login page must reference ${token}`);
  }

  // The buttons must be conditionally rendered, never emitted unconditionally.
  assert.match(src, /appleOAuthEnabled\s*&&/, 'apple button must be flag-gated');
  assert.match(src, /googleOAuthEnabled\s*&&/, 'google button must be flag-gated');
});
