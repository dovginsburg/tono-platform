'use client'

// Pre-auth canned demonstration for the landing hero.
//
// This is the ONLY place a signed-out visitor can watch the loop run before
// creating an account — and it is deliberately NOT a live rewrite. The input is
// fixed and the four outputs are precomputed constants below, so tapping
// "rewrite" costs no backend call, exposes no anonymous rewrite path to abuse,
// and never implies a real model ran. Under the no-free-tier contract there is
// no anonymous /api/analyze; this shows the shape of the product honestly.
//
// The interaction mirrors the real editor (a "rewrite" action, a one-word
// "rewriting…" beat, four named/colored cards in canonical order) so the demo
// teaches the actual motion — but every card is captioned as a canned sample.

import { useCallback, useState } from 'react'

type Axis = 'warmer' | 'clearer' | 'funnier' | 'safer'

// Fixed sample draft + precomputed rewrites. Constants — no network, no model.
const SAMPLE_DRAFT = 'you still haven’t sent the file — what’s the holdup?'

const SAMPLE_REWRITES: { axis: Axis; text: string }[] = [
  { axis: 'warmer', text: 'hey — any update on that file when you get a moment?' },
  { axis: 'clearer', text: 'can you send the file today? i’m blocked without it.' },
  { axis: 'funnier', text: 'the file and i have never met — can you introduce us?' },
  { axis: 'safer', text: 'i might’ve missed it — did the file already go out?' },
]

type Phase = 'idle' | 'rewriting' | 'done'

export default function DemoRewrite() {
  const [phase, setPhase] = useState<Phase>('idle')

  const run = useCallback(() => {
    if (phase === 'rewriting') return
    setPhase('rewriting')
    // A short, honest beat — this is animation, not compute. It reveals the
    // precomputed cards; it does not wait on anything.
    setTimeout(() => setPhase('done'), 650)
  }, [phase])

  const reset = useCallback(() => setPhase('idle'), [])

  return (
    <div>
      {/* the fixed sample draft */}
      <div className="px-4 pt-3">
        <p className="text-[10px] font-mono lowercase text-tono-muted mb-1.5">your draft</p>
        <p className="text-[14px] text-tono-text-soft leading-[1.5]">“{SAMPLE_DRAFT}”</p>
      </div>

      {phase === 'idle' ? (
        <div className="px-4 pt-3 pb-1">
          <button
            type="button"
            onClick={run}
            className="w-full inline-flex items-center justify-center gap-2 px-4 py-2.5 rounded-[10px] bg-tono-bg-elev border border-tono-border hover:border-tono-accent text-tono-text font-semibold text-[13px] transition min-h-[44px]"
          >
            rewrite
            <span aria-hidden className="text-tono-text-softer font-mono text-[11px]">⌘↵</span>
          </button>
          <p className="text-[10px] text-tono-muted mt-2 text-center">
            try it — this is a canned sample, no account needed
          </p>
        </div>
      ) : phase === 'rewriting' ? (
        <div
          role="status"
          aria-live="polite"
          className="px-4 py-6 flex items-center justify-center gap-2 text-tono-text-softer text-[13px]"
        >
          <span className="w-1.5 h-1.5 rounded-full bg-tono-accent animate-pulse" />
          <span className="w-1.5 h-1.5 rounded-full bg-tono-accent animate-pulse [animation-delay:0.15s]" />
          <span className="w-1.5 h-1.5 rounded-full bg-tono-accent animate-pulse [animation-delay:0.3s]" />
          <span className="ml-2">rewriting…</span>
        </div>
      ) : (
        <div className="px-2.5 py-3 mt-3 space-y-1.5 border-t border-tono-border bg-tono-bg-soft">
          {SAMPLE_REWRITES.map((r) => (
            <div
              key={r.axis}
              className={`bg-tono-bg-elev border border-tono-border rounded-[10px] p-2.5 tone-rule-l-${r.axis}`}
            >
              <div className="flex items-center gap-1.5 mb-1">
                <span className={`w-1.5 h-1.5 rounded-full tone-dot-sm-${r.axis}`} aria-hidden="true" />
                <span className={`text-[10px] font-semibold tracking-[0.04em] uppercase tone-text-${r.axis}`}>
                  {r.axis}
                </span>
              </div>
              <p className="text-[12px] text-tono-text-soft leading-[1.45]">{r.text}</p>
            </div>
          ))}
          <div className="flex items-center justify-between pt-1">
            <span className="text-[10px] text-tono-muted">canned sample · not a live rewrite</span>
            <button
              type="button"
              onClick={reset}
              className="text-[11px] font-semibold text-tono-accent-light hover:underline min-h-[28px]"
            >
              replay
            </button>
          </div>
        </div>
      )}
    </div>
  )
}
