// TonoDemo — the working paste → rewrite demo on the landing page.
//
// Replaces the static phone-frame screenshot with a real, client-side
// rewrite tool. Hits POST /api/analyze (which proxies through the
// Supabase edge to api.tonoit.com → FastAPI). Anonymous calls are
// permitted; the API returns 4 tones (warmer/clearer/funnier/safer)
// and a risk assessment.
//
// Brand voice (lowercase, dry, no exclamation):
//   - empty:  "paste any text. four rewrites in two seconds."
//   - loading:"thinking…"
//   - error:  "couldn't reach tono. check your connection and try again."
//
// All colors come through tone-* utility classes from globals.css —
// no hex literals in JSX.

'use client'

import { useCallback, useEffect, useRef, useState } from 'react'

type Axis = 'warmer' | 'clearer' | 'funnier' | 'safer'

type Suggestion = {
  axis: Axis
  text: string
}

type AnalyzeResponse = {
  perception?: string
  suggestions?: Suggestion[]
  error?: string
}

const EXAMPLE_PLACEHOLDER =
  'paste any text. four rewrites in two seconds.'

const TONE_ORDER: Axis[] = ['warmer', 'clearer', 'funnier', 'safer']

export default function TonoDemo() {
  const [draft, setDraft] = useState('')
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [result, setResult] = useState<AnalyzeResponse | null>(null)
  const [copied, setCopied] = useState<Axis | null>(null)
  const taRef = useRef<HTMLTextAreaElement | null>(null)
  // Track the latest in-flight request id so stale responses don't
  // overwrite a newer result if a user fires multiple pastes quickly.
  const reqIdRef = useRef(0)

  // Auto-grow textarea up to a sensible max height so the demo
  // doesn't introduce a scroll bar on small screens.
  useEffect(() => {
    const el = taRef.current
    if (!el) return
    el.style.height = 'auto'
    el.style.height = Math.min(el.scrollHeight, 220) + 'px'
  }, [draft])

  const submit = useCallback(async () => {
    const text = draft.trim()
    if (!text || loading) return
    setLoading(true)
    setError(null)
    setResult(null)
    const myId = ++reqIdRef.current
    try {
      const res = await fetch('/api/analyze', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ text }),
      })
      if (myId !== reqIdRef.current) return // a newer request superseded this one
      if (!res.ok) {
        const j = await res.json().catch(() => ({}))
        throw new Error(j.error || `request failed (${res.status})`)
      }
      const data = (await res.json()) as AnalyzeResponse
      if (myId !== reqIdRef.current) return
      setResult(data)
    } catch (e) {
      if (myId !== reqIdRef.current) return
      setError(
        e instanceof Error
          ? "couldn't reach tono. check your connection and try again."
          : "couldn't reach tono. check your connection and try again."
      )
    } finally {
      if (myId === reqIdRef.current) setLoading(false)
    }
  }, [draft, loading])

  const copy = useCallback(async (axis: Axis, text: string) => {
    try {
      await navigator.clipboard.writeText(text)
      setCopied(axis)
      setTimeout(() => setCopied((c) => (c === axis ? null : c)), 1600)
    } catch {
      // Clipboard denied — fall back to selecting the text so the
      // user can still manual-copy. Keep UX quiet; no error spam.
      const range = document.createRange()
      const el = document.querySelector<HTMLElement>(
        `[data-tone-result="${axis}"]`
      )
      if (el) {
        range.selectNodeContents(el)
        const sel = window.getSelection()
        sel?.removeAllRanges()
        sel?.addRange(range)
      }
    }
  }, [])

  return (
    <aside
      aria-label="try tono — paste a draft and get four rewrites"
      className="relative"
    >
      {/* soft glow behind the demo card */}
      <div
        aria-hidden="true"
        className="absolute -inset-6 rounded-[44px] bg-tono-accent/10 blur-2xl pointer-events-none"
      />
      <div className="relative rounded-[20px] bg-tono-bg-card border border-tono-border overflow-hidden">
        {/* header bar — mirrors the iOS "tono · draft" frame */}
        <div className="flex items-center justify-between px-4 pt-3 pb-2 border-b border-tono-border">
          <div className="flex items-center gap-2">
            <span className="w-1.5 h-1.5 rounded-full bg-tono-accent shadow-[0_0_8px_var(--accent-glow)]" />
            <span className="text-[10px] font-semibold tracking-[0.06em] text-tono-text uppercase">
              tono · try it
            </span>
          </div>
          <span className="text-[10px] font-mono lowercase text-tono-muted">
            free · no signup
          </span>
        </div>

        {/* composer */}
        <div className="px-4 pt-3">
          <label htmlFor="tono-draft" className="sr-only">
            paste a draft to rewrite
          </label>
          <textarea
            id="tono-draft"
            ref={taRef}
            value={draft}
            onChange={(e) => setDraft(e.target.value)}
            onKeyDown={(e) => {
              // Cmd/Ctrl+Enter triggers a rewrite from the keyboard.
              if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') {
                e.preventDefault()
                submit()
              }
            }}
            placeholder={EXAMPLE_PLACEHOLDER}
            rows={3}
            spellCheck={false}
            className="w-full resize-none bg-transparent text-[14px] text-tono-text-soft italic leading-[1.5] placeholder:text-tono-muted placeholder:not-italic placeholder:font-normal focus:outline-none"
          />
        </div>

        {/* action row */}
        <div className="flex items-center justify-between gap-3 px-4 py-3 border-t border-tono-border">
          <span className="text-[10px] font-mono lowercase text-tono-muted">
            {loading
              ? 'thinking…'
              : result
              ? 'pick one — copy, send'
              : 'enter text → rewrite'}
          </span>
          <button
            type="button"
            onClick={submit}
            disabled={!draft.trim() || loading}
            className="inline-flex items-center justify-center gap-2 px-4 py-2 rounded-[10px] bg-tono-accent hover:bg-tono-accent-hover disabled:bg-tono-bg-elev disabled:text-tono-muted text-white font-semibold text-[13px] transition min-h-[40px]"
          >
            {loading ? 'rewriting…' : 'rewrite'}
            {!loading && (
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
                <path d="M5 12h14M13 5l7 7-7 7" />
              </svg>
            )}
          </button>
        </div>

        {/* results */}
        {(result?.suggestions?.length || error || loading) && (
          <div className="px-2.5 py-2 space-y-1.5 border-t border-tono-border bg-tono-bg-soft">
            {loading && !result && (
              <div className="px-2 py-3 text-[12px] text-tono-text-softer italic">
                rewarming the model…
              </div>
            )}
            {error && (
              <div
                role="alert"
                className="px-3 py-3 rounded-[10px] border border-tono-danger/40 bg-tono-danger/10 text-[12px] text-tono-text-soft"
              >
                {error}
              </div>
            )}
            {result?.suggestions?.length
              ? TONE_ORDER.map((axis) => {
                  const s = result.suggestions!.find((x) => x.axis === axis)
                  if (!s) return null
                  const copiedFlag = copied === axis
                  return (
                    <div
                      key={axis}
                      className={`bg-tono-bg-elev border border-tono-border rounded-[10px] p-2.5 transition tone-rule-l-${axis}`}
                    >
                      <div className="flex items-center justify-between gap-2 mb-1">
                        <div className="flex items-center gap-1.5">
                          <span
                            className={`w-1.5 h-1.5 rounded-full tone-dot-sm-${axis}`}
                            aria-hidden="true"
                          />
                          <span
                            className={`text-[10px] font-semibold tracking-[0.04em] uppercase tone-text-${axis}`}
                          >
                            {axis}
                          </span>
                        </div>
                        <button
                          type="button"
                          onClick={() => copy(axis, s.text)}
                          aria-label={`copy ${axis} rewrite`}
                          className="text-[10px] font-mono lowercase text-tono-text-softer hover:text-tono-text-soft transition px-2 py-1 rounded-md hover:bg-tono-bg-card"
                        >
                          {copiedFlag ? 'copied' : 'copy'}
                        </button>
                      </div>
                      <p
                        data-tone-result={axis}
                        className="text-[12px] text-tono-text-soft leading-[1.45]"
                      >
                        {s.text}
                      </p>
                    </div>
                  )
                })
              : null}
          </div>
        )}

        {/* keyboard hint footer */}
        <div className="flex items-center justify-between px-4 py-2.5 bg-tono-bg border-t border-tono-border">
          <span className="text-[10px] font-mono lowercase text-tono-muted">
            ⌘/ctrl + enter to rewrite
          </span>
          <span className="text-[10px] font-mono lowercase text-tono-accent-light">
            drafts stay in your browser
          </span>
        </div>
      </div>
    </aside>
  )
}
