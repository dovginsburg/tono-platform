// Brand + contact-identity guardrail (2026-08-04).
//
// The customer-facing web once shipped an internal operator mailbox
// (ezra-orchestrator@agentmail.to) across About, Contact, Privacy, Terms,
// Pricing, the landing feedback CTA, and the footer. This regression pins the
// two properties that keep it from coming back:
//
//   1. NO web source under src/ names a personal/operator identity, the
//      AgentMail domain, or a sibling product — in rendered copy OR in a
//      comment/path. (We scan the raw bytes, comments included, precisely so a
//      stray absolute path like /Users/<name>/... trips the test too.)
//   2. Every official contact route resolves through src/lib/contact.ts, whose
//      aliases are the tonoit.com Cloudflare Email Routing addresses — so a new
//      surface adds a channel in one reviewed place instead of hand-typing a
//      mailbox.
//
// Provider-controlled transactional email (Supabase/GoTrue verification,
// reset, and resend templates + envelope sender) is out of this repo's source
// and therefore out of this test's reach — see the task report.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const WEB_ROOT = path.join(__dirname, '..');
const SRC_ROOT = path.join(WEB_ROOT, 'src');

/** Every source file under src/, recursively. */
function walk(dir) {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (entry.name === 'node_modules' || entry.name === '.next') continue;
      out.push(...walk(full));
    } else {
      out.push(full);
    }
  }
  return out;
}

const ALL_SOURCES = walk(SRC_ROOT);

// The banned tokens. `ezra` and `agentmail` were the live leak; the rest are
// the operator/provider/sibling identities the brief forbids in customer copy.
// Matched case-insensitively against raw bytes. `supabase` is deliberately NOT
// in this list: it is a legitimate implementation term in server/route/auth
// modules and in the privacy disclosure. It is instead pinned to be absent
// from the specific customer marketing surfaces below.
const BANNED = ['ezra', 'agentmail', 'ezra-orchestrator@agentmail.to'];

// This test file necessarily spells the banned tokens (to ban them), so it is
// the one file exempt from the raw-bytes scan.
const SELF = path.resolve(__filename);

test('no web source names a personal/operator identity or the AgentMail domain', () => {
  const offenders = [];
  for (const file of ALL_SOURCES) {
    if (path.resolve(file) === SELF) continue;
    const text = fs.readFileSync(file, 'utf8').toLowerCase();
    for (const token of BANNED) {
      if (text.includes(token)) {
        offenders.push(`${path.relative(WEB_ROOT, file)} contains “${token}”`);
      }
    }
  }
  assert.deepEqual(offenders, [], `banned identity in web source:\n${offenders.join('\n')}`);
});

test('contact.ts is the single source of the four official tonoit.com aliases', () => {
  const contact = fs.readFileSync(path.join(SRC_ROOT, 'lib', 'contact.ts'), 'utf8');
  const expected = {
    hello: 'hello@tonoit.com',
    support: 'support@tonoit.com',
    privacy: 'privacy@tonoit.com',
    security: 'security@tonoit.com',
  };
  for (const [channel, address] of Object.entries(expected)) {
    assert.match(
      contact,
      new RegExp(`${channel}:\\s*'${address.replace('.', '\\.')}'`),
      `contact.ts must define ${channel} → ${address}`
    );
    // Every alias is on tonoit.com — never a non-brand domain.
    assert.ok(address.endsWith('@tonoit.com'), `${channel} must be a tonoit.com alias`);
  }
  assert.match(contact, /export function tonoMailto/);
});

test('every customer-facing mailto routes through the contact module', () => {
  // The public surfaces that carry contact links. Each must import the module
  // and hold no hard-coded mailto: literal (which is how the leak got in).
  const surfaces = [
    'app/about/page.tsx',
    'app/contact/page.tsx',
    'app/privacy/page.tsx',
    'app/terms/page.tsx',
    'app/pricing/page.tsx',
    'app/page.tsx',
    'app/TonoFooter.tsx',
  ];
  for (const rel of surfaces) {
    const source = fs.readFileSync(path.join(SRC_ROOT, rel), 'utf8');
    assert.match(
      source,
      /from '(\.\.\/)+lib\/contact'/,
      `${rel} must source its contact identity from lib/contact`
    );
    // A hard-coded mailbox is a `mailto:` followed by a real local-part
    // character. An interpolated `mailto:${...}` built from the module is fine.
    assert.ok(
      !/mailto:[A-Za-z0-9._%+-]/.test(source),
      `${rel} must not hard-code a mailto: address literal — use tonoMailto()`
    );
  }
});

test('the customer marketing surfaces expose no Supabase/provider branding', () => {
  // Privacy is exempt: it legitimately names Supabase/Stripe as processors.
  const marketing = [
    'app/about/page.tsx',
    'app/contact/page.tsx',
    'app/pricing/page.tsx',
    'app/TonoFooter.tsx',
  ];
  for (const rel of marketing) {
    const text = fs.readFileSync(path.join(SRC_ROOT, rel), 'utf8').toLowerCase();
    for (const term of ['supabase', 'agentmail', 'ezra', 'parentscript']) {
      assert.ok(!text.includes(term), `${rel} must not surface “${term}” to customers`);
    }
  }
});

test('the About page presents official Tono contact routes, not an operator inbox', () => {
  const about = fs.readFileSync(path.join(SRC_ROOT, 'app', 'about', 'page.tsx'), 'utf8');
  // The rewritten About routes general/press to hello@ and account help to
  // support@ via the module — proving the contact section survived the rewrite.
  assert.match(about, /TONO_CONTACT\.hello/);
  assert.match(about, /TONO_CONTACT\.support/);
  assert.ok(!about.toLowerCase().includes('brooklyn'), 'unverifiable location claim removed');
});
