'use client'

// Pre-auth canned demonstration for the landing hero.
//
// This is the ONLY place a signed-out visitor can run the loop before creating
// an account — and it is deliberately NOT a live rewrite. The draft is fixed
// and the four outputs are precomputed constants (see lib/demo-rewrite.ts), so
// running it costs no backend call, exposes no anonymous rewrite path to abuse,
// and never implies a real model ran. Under the no-free-tier contract there is
// no anonymous /api/analyze; this shows the shape of the product honestly.
//
// It teaches the DECISION, not just an animation: the visitor reveals the four
// named/colored options, then picks the one they'd actually send and copies it.
// That pick — and the confirmation it produces — is the product's core moment.
// The rewrites always carry the "canned sample · not a live rewrite" label.

import { useCallback, useState } from 'react'
import {
  type Axis,
  DEMO_REWRITES,
  DEMO_SAMPLE_DRAFT,
  DEMO_SAMPLE_LABEL,
  demoPickConfirmation,
} from '../lib/demo-rewrite'

type Phase = 'idle' | 'rewriting' | 'choosing'

export default function DemoRewrite() {
  const [phase, setPhase] = useState<Phase>('idle')
  const [picked, setPicked] = useState<Axis | null>(null)
  const [copied, setCopied] = useState(false)

  const run = useCallback(() => {
    if (phase === 'rewriting') return
    setPhase('rewriting')
    // A short, honest beat — this is animation, not compute. It reveals the
    // precomputed cards; it does not wait on anything over the network.
    setTimeout(() => setPhase('choosing'), 650)
  }, [phase])

  const pick = useCallback((axis: Axis) => {
    setPicked(axis)
    setCopied(false)
  }, [])

  const copy = useCallback(() => {
    if (!picked) return
    const text = DEMO_REWRITES.find((r) => r.axis === picked)?.text ?? ''
    // Clipboard only — a local browser API, never a server request.
    if (typeof navigator !== 'undefined' && navigator.clipboard?.writeText) {
      navigator.clipboard.writeText(text).catch(() => {})
    }
    setCopied(true)
  }, [picked])

  const reset = useCallback(() => {
    setPhase('idle')
    setPicked(null)
    setCopied(false)
  }, [])

  return (
    <div>
      {/* the fixed sample draft */}
      <div className="px-4 pt-3">
        <p className="text-[10px] font-mono lowercase text-tono-muted mb-1.5">your draft</p>
        <p className="text-[14px] text-tono-text-soft leading-[1.5]">“{DEMO_SAMPLE_DRAFT}”</p>
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
          {/* the decision — pick the one you'd actually send */}
          <p className="px-1 pb-1 text-[10px] font-mono lowercase text-tono-muted">
            pick the one you’d send
          </p>
          <div role="radiogroup" aria-label="pick a tone to send" className="space-y-1.5">
            {DEMO_REWRITES.map((r) => {
              const selected = picked === r.axis
              return (
                <button
                  key={r.axis}
                  type="button"
                  role="radio"
                  aria-checked={selected}
                  onClick={() => pick(r.axis)}
                  className={`w-full text-left bg-tono-bg-elev border rounded-[10px] p-2.5 transition tone-rule-l-${r.axis} ${
                    selected ? 'border-tono-accent' : 'border-tono-border hover:border-tono-border-strong'
                  }`}
                >
                  <div className="flex items-center gap-1.5 mb-1">
                    <span className={`w-1.5 h-1.5 rounded-full tone-dot-sm-${r.axis}`} aria-hidden="true" />
                    <span className={`text-[10px] font-semibold tracking-[0.04em] uppercase tone-text-${r.axis}`}>
                      {r.axis}
                    </span>
                    {selected ? (
                      <span className="ml-auto text-[10px] font-semibold text-tono-accent-light">picked</span>
                    ) : null}
                  </div>
                  <p className="text-[12px] text-tono-text-soft leading-[1.45]">{r.text}</p>
                </button>
              )
            })}
          </div>

          {/* the payoff of the decision — confirmation + copy */}
          {picked ? (
            <div
              aria-live="polite"
              className="flex items-center justify-between gap-2 pt-1.5 mt-1.5 border-t border-tono-border"
            >
              <span className="text-[11px] text-tono-text-soft">{demoPickConfirmation(picked)}</span>
              <button
                type="button"
                onClick={copy}
                className="text-[11px] font-semibold text-tono-accent-light hover:underline min-h-[28px] px-1"
              >
                {copied ? 'copied' : 'copy'}
              </button>
            </div>
          ) : null}

          <div className="flex items-center justify-between pt-1">
            <span className="text-[10px] text-tono-muted">{DEMO_SAMPLE_LABEL}</span>
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
