// Canned data + pure helpers for the pre-signup landing demo.
//
// Everything a signed-out visitor sees in the hero demo lives here as plain
// constants. There is deliberately NO network path: under the no-free-tier
// contract there is no anonymous /api/analyze, so the demo shows the shape of
// the product honestly with precomputed outputs rather than implying a live
// model ran. DemoRewrite.tsx renders these; the logic stays here so it can be
// unit-tested without a DOM (mirrors social-auth.ts / social-auth.test.ts).

export type Axis = 'warmer' | 'clearer' | 'funnier' | 'safer';

// Canonical tone order — matches the iOS/editor rail and the copy in page.tsx.
export const DEMO_TONE_ORDER: readonly Axis[] = ['warmer', 'clearer', 'funnier', 'safer'];

// The one fixed draft the demo rewrites. A real, relatable friction message.
export const DEMO_SAMPLE_DRAFT = 'you still haven’t sent the file — what’s the holdup?';

// The four precomputed rewrites. Constants — no model, no request, no I/O.
export const DEMO_REWRITES: readonly { axis: Axis; text: string }[] = [
  { axis: 'warmer', text: 'hey — any update on that file when you get a moment?' },
  { axis: 'clearer', text: 'can you send the file today? i’m blocked without it.' },
  { axis: 'funnier', text: 'the file and i have never met — can you introduce us?' },
  { axis: 'safer', text: 'i might’ve missed it — did the file already go out?' },
];

// The honesty label that must sit on the rewrites. This is the one claim the
// demo makes about itself: a sample, not a live AI rewrite. It must never be
// softened into implying free live rewriting.
export const DEMO_SAMPLE_LABEL = 'canned sample · not a live rewrite';

// Look up the canned rewrite for a tone. Pure: same input, same output, no I/O.
// This is the "decision" the demo teaches — the visitor picks a tone and this
// resolves the exact wording they'd send.
export function demoRewriteFor(axis: Axis): string {
  const match = DEMO_REWRITES.find((r) => r.axis === axis);
  if (!match) throw new Error(`unknown demo tone: ${axis}`);
  return match.text;
}

// The confirmation shown once the visitor commits to a tone — the payoff of the
// decision experience, framed as "this is the one you'd send".
export function demoPickConfirmation(axis: Axis): string {
  return `you’d send the ${axis} one`;
}
