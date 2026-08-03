// Source-contract guard for the login page's Apple mark.
//
// Live-failure origin: the "continue with apple" button rendered a distorted,
// clipped glyph that read as a malformed bag/mug and was rejected in production.
// Root cause was NOT the fill or the copy — it was geometry. The prior <path>
// carried coordinates that spilled outside the SVG's own `0 0 24 24` viewBox
// (true rendered bounding box ran to x=-3.955 on the left and y=25.040 at the
// bottom). An SVG viewport clips to its viewBox, so the left flank and base of
// the mark were cut off and the survivor looked malformed.
//
// This test reads the SHIPPING source and re-derives the rendered geometry of
// the <path> inside AppleIcon(), asserting the invariants that a clipped or
// stretched mark would violate:
//   * the AppleIcon svg declares a square `0 0 24 24` viewBox;
//   * width === height (a square viewport — nothing can stretch);
//   * the path's true (bezier-accurate) bounding box sits WHOLLY inside the
//     viewBox, so no part of the glyph is clipped;
//   * the glyph is reasonably centered — comparable margin on left/right and
//     top/bottom — so it cannot be jammed into a corner;
//   * accessibility: the icon stays decorative (aria-hidden) because the button
//     carries the accessible name, and the mark is a real vector <path> (not an
//     emoji, text node, <img>, or font glyph).
//
// It is intentionally geometry-based, not a string match on today's path data:
// any future path — stretched, off-center, or overflowing — that reintroduces
// the defect fails here, and any correctly-fitted canonical Apple path passes.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const loginPage = fs.readFileSync(
  path.join(__dirname, '..', 'src/app/login/page.tsx'),
  'utf8',
);

// --- extract the AppleIcon svg + its path from the shipping source ----------

// Isolate the AppleIcon() function body so we never accidentally inspect the
// sibling GoogleIcon.
function appleIconSource() {
  const marker = 'function AppleIcon(';
  const start = loginPage.indexOf(marker);
  assert.notEqual(start, -1, 'AppleIcon() must exist in the login page');
  // Grab a generous slice; the function is small and self-contained.
  return loginPage.slice(start, start + 2000);
}

const apple = appleIconSource();

// --- bezier-accurate path bounding box --------------------------------------
//
// Handles the M/m/L/l/C/c/Z/z the mark uses. For each cubic segment it takes
// the true axis extrema (derivative roots in (0,1)), not the control-point
// envelope, so the box equals what the browser actually paints.
function pathBoundingBox(d) {
  const toks = d.match(/[MmCcZzLlHhVv]|-?\d*\.?\d+/g);
  let i = 0, x = 0, y = 0, sx = 0, sy = 0, cmd = null;
  const b = { minX: Infinity, minY: Infinity, maxX: -Infinity, maxY: -Infinity };
  const upd = (px, py) => {
    b.minX = Math.min(b.minX, px); b.minY = Math.min(b.minY, py);
    b.maxX = Math.max(b.maxX, px); b.maxY = Math.max(b.maxY, py);
  };
  const cubic = (p0, p1, p2, p3) => {
    upd(p0[0], p0[1]); upd(p3[0], p3[1]);
    for (let a = 0; a < 2; a++) {
      const c0 = p0[a], c1 = p1[a], c2 = p2[a], c3 = p3[a];
      const aa = c3 - c0 + 3 * (c1 - c2);
      const bb = 2 * (c0 - 2 * c1 + c2);
      const cc = c1 - c0;
      const roots = [];
      if (Math.abs(aa) < 1e-9) {
        if (Math.abs(bb) > 1e-9) roots.push(-cc / bb);
      } else {
        const disc = bb * bb - 4 * aa * cc;
        if (disc >= 0) {
          const s = Math.sqrt(disc);
          roots.push((-bb + s) / (2 * aa), (-bb - s) / (2 * aa));
        }
      }
      for (const t of roots) {
        if (t > 0 && t < 1) {
          const mt = 1 - t;
          const val =
            mt * mt * mt * c0 + 3 * mt * mt * t * c1 + 3 * mt * t * t * c2 + t * t * t * c3;
          if (a === 0) { b.minX = Math.min(b.minX, val); b.maxX = Math.max(b.maxX, val); }
          else { b.minY = Math.min(b.minY, val); b.maxY = Math.max(b.maxY, val); }
        }
      }
    }
  };
  while (i < toks.length) {
    const t = toks[i];
    if (/[A-Za-z]/.test(t)) { cmd = t; i++; }
    if (cmd === 'M') { x = +toks[i++]; y = +toks[i++]; sx = x; sy = y; upd(x, y); cmd = 'L'; }
    else if (cmd === 'm') { x += +toks[i++]; y += +toks[i++]; sx = x; sy = y; upd(x, y); cmd = 'l'; }
    else if (cmd === 'L') { x = +toks[i++]; y = +toks[i++]; upd(x, y); }
    else if (cmd === 'l') { x += +toks[i++]; y += +toks[i++]; upd(x, y); }
    else if (cmd === 'H') { x = +toks[i++]; upd(x, y); }
    else if (cmd === 'h') { x += +toks[i++]; upd(x, y); }
    else if (cmd === 'V') { y = +toks[i++]; upd(x, y); }
    else if (cmd === 'v') { y += +toks[i++]; upd(x, y); }
    else if (cmd === 'C') {
      const p0 = [x, y];
      const p1 = [+toks[i++], +toks[i++]];
      const p2 = [+toks[i++], +toks[i++]];
      const p3 = [+toks[i++], +toks[i++]];
      cubic(p0, p1, p2, p3); x = p3[0]; y = p3[1];
    } else if (cmd === 'c') {
      const p0 = [x, y];
      const p1 = [x + +toks[i++], y + +toks[i++]];
      const p2 = [x + +toks[i++], y + +toks[i++]];
      const p3 = [x + +toks[i++], y + +toks[i++]];
      cubic(p0, p1, p2, p3); x = p3[0]; y = p3[1];
    } else if (cmd === 'Z' || cmd === 'z') { x = sx; y = sy; }
    else { i++; }
  }
  return b;
}

// --- the svg element attributes ---------------------------------------------

test('AppleIcon declares a square 0 0 24 24 viewBox', () => {
  const vb = apple.match(/viewBox=["']([^"']+)["']/);
  assert.ok(vb, 'AppleIcon svg must declare a viewBox');
  const nums = vb[1].trim().split(/[\s,]+/).map(Number);
  assert.deepEqual(nums, [0, 0, 24, 24], 'viewBox must be the canonical 0 0 24 24');
  assert.equal(nums[2], nums[3], 'viewBox must be square so the mark cannot stretch');
});

test('AppleIcon draws into a square viewport (width === height)', () => {
  const w = apple.match(/width=["'](\d+)["']/);
  const h = apple.match(/height=["'](\d+)["']/);
  assert.ok(w && h, 'AppleIcon svg must state explicit width and height');
  assert.equal(w[1], h[1], 'width must equal height so the aspect ratio is preserved');
});

test('AppleIcon renders a real vector <path>, not text/emoji/img/font glyph', () => {
  assert.match(apple, /<path\b[^>]*\bd=["']/, 'the mark must be an SVG <path>');
  assert.doesNotMatch(apple, /<img\b/i, 'the mark must not be a raster <img>');
  // No stray text node inside the svg that could be an emoji/character glyph.
  assert.doesNotMatch(apple, />\s*[\uD800-\uDBFF]/, 'no emoji/surrogate glyph as a substitute');
});

test('AppleIcon stays decorative; the button carries the accessible name', () => {
  assert.match(apple, /aria-hidden/, 'the icon must be aria-hidden (button labels it)');
  // The button that hosts it is labelled — re-assert that invariant here so a
  // future edit that drops the icon into an unlabelled control is caught.
  assert.match(loginPage, /aria-label="Continue with Apple"/);
});

// --- the load-bearing geometry: no clipping, and centered -------------------

test('the Apple glyph fits WHOLLY inside its viewBox (no clipping)', () => {
  const dMatch = apple.match(/<path\b[^>]*\bd=["']([^"']+)["']/);
  assert.ok(dMatch, 'AppleIcon must have a path with d=');
  const box = pathBoundingBox(dMatch[1]);
  // A hair of tolerance for floating-point curve extrema and canonical marks
  // authored to kiss an edge; the rejected path overflowed by whole units
  // (x=-3.955, y=25.040), far beyond this.
  const EPS = 0.06;
  assert.ok(box.minX >= -EPS, `glyph clipped on the left (minX=${box.minX.toFixed(3)})`);
  assert.ok(box.minY >= -EPS, `glyph clipped on the top (minY=${box.minY.toFixed(3)})`);
  assert.ok(box.maxX <= 24 + EPS, `glyph clipped on the right (maxX=${box.maxX.toFixed(3)})`);
  assert.ok(box.maxY <= 24 + EPS, `glyph clipped on the bottom (maxY=${box.maxY.toFixed(3)})`);
});

test('the Apple glyph is reasonably centered in its viewBox', () => {
  const dMatch = apple.match(/<path\b[^>]*\bd=["']([^"']+)["']/);
  const box = pathBoundingBox(dMatch[1]);
  const leftMargin = box.minX;
  const rightMargin = 24 - box.maxX;
  const topMargin = box.minY;
  const bottomMargin = 24 - box.maxY;
  // Center of mass must be near the middle of the box on each axis. Canonical
  // Apple marks are taller than wide and some bleed to the top/bottom edges, so
  // this guards against gross off-centering (a corner-jammed glyph), not pixel
  // symmetry.
  const cx = (box.minX + box.maxX) / 2;
  const cy = (box.minY + box.maxY) / 2;
  assert.ok(Math.abs(cx - 12) <= 2.5, `glyph horizontally off-center (cx=${cx.toFixed(2)})`);
  assert.ok(Math.abs(cy - 12) <= 2.5, `glyph vertically off-center (cy=${cy.toFixed(2)})`);
  // And it must actually occupy the box — not a sliver.
  assert.ok(box.maxX - box.minX >= 8, 'glyph too narrow to be the Apple mark');
  assert.ok(box.maxY - box.minY >= 8, 'glyph too short to be the Apple mark');
  void leftMargin; void rightMargin; void topMargin; void bottomMargin;
});
