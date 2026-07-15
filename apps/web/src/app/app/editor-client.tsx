'use client';

// The actual Tono workspace surface — left rail (composer), right
// rail (4 rewrite cards), copy/select interactions. Mirrors Mark's
// tono-rewrite-editor.html, wired to /api/analyze.
//
// Brand voice from brand-voice-guide.md:
//   - lowercase CTAs (rewrite / copy / send)
//   - no exclamation marks
//   - the four tones named in copy match the on-screen accent color
//   - "thinking…" / "rewriting…" loading (one word)
//   - empty state IS the demo: "paste any text. four rewrites in two seconds."

import { useCallback, useEffect, useRef, useState } from 'react';
import Link from 'next/link';

type Axis = 'warmer' | 'clearer' | 'funnier' | 'safer';

type Rewrite = {
  axis: Axis;
  text: string;
  rationale?: string;
};

type AnalyzeResponse = {
  risk_level?: string;
  perception?: string;
  subtext?: string;
  suggestions?: Rewrite[];
  flags?: string[];
  // 429 shape
  message?: string;
  used_today?: number;
  daily_limit?: number;
  plan?: string;
};

type Quota = {
  used_today: number;
  daily_limit: number;
  plan: string;
  is_pro?: boolean;
};

const AXES: Axis[] = ['warmer', 'clearer', 'funnier', 'safer'];
const AXIS_COLOR: Record<Axis, string> = {
  warmer: '#F472B6',
  clearer: '#38BDF8',
  funnier: '#FBBF24',
  safer: '#34D399',
};

export function RewriteEditor({
  email,
  userId,
  hasApiToken,
}: {
  email: string;
  userId: string;
  hasApiToken: boolean;
}) {
  const [draft, setDraft] = useState('');
  const [rewrites, setRewrites] = useState<Rewrite[]>([]);
  const [perception, setPerception] = useState<{ risk_level?: string; subtext?: string } | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [limit, setLimit] = useState<{ used: number; max: number } | null>(null);
  const [selected, setSelected] = useState<Axis | null>(null);
  const [copied, setCopied] = useState<Axis | null>(null);
  const textareaRef = useRef<HTMLTextAreaElement>(null);

  const loadQuota = useCallback(async () => {
    try {
      const res = await fetch('/api/me', { cache: 'no-store' });
      if (res.ok) {
        const data: Quota = await res.json();
        setLimit({
          used: data.used_today,
          max: data.daily_limit === -1 ? Infinity : data.daily_limit,
        });
      }
    } catch {
      // Quota is decorative; don't surface errors.
    }
  }, []);

  useEffect(() => {
    loadQuota();
  }, [loadQuota]);

  const rewrite = useCallback(async () => {
    if (!draft.trim() || loading) return;
    setError(null);
    setLoading(true);
    setRewrites([]);
    setPerception(null);
    setSelected(null);
    try {
      const res = await fetch('/api/analyze', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ text: draft }),
      });
      const data: AnalyzeResponse = await res.json();
      if (res.status === 429) {
        setError(data.message || 'request unavailable');
        if (typeof data.used_today === 'number' && typeof data.daily_limit === 'number') {
          setLimit({ used: data.used_today, max: data.daily_limit });
        }
        return;
      }
      if (!res.ok) {
        setError(data?.message || `couldn't reach tono (${res.status})`);
        return;
      }
      // Map suggestions to our axis whitelist, in canonical order.
      const suggestions = (data.suggestions || [])
        .filter((s): s is Rewrite => AXES.includes(s.axis as Axis))
        .sort(
          (a, b) => AXES.indexOf(a.axis as Axis) - AXES.indexOf(b.axis as Axis)
        );
      setRewrites(suggestions);
      setPerception({ risk_level: data.risk_level, subtext: data.subtext });

      // Persist to history (localStorage v1)
      saveToHistory({
        id: crypto.randomUUID(),
        timestamp: Date.now(),
        draft,
        suggestions,
        perception: data.perception || '',
      });

      // Refresh quota after a successful rewrite
      loadQuota();
    } catch (e) {
      setError("couldn't reach tono. check your connection and try again.");
    } finally {
      setLoading(false);
    }
  }, [draft, loading, loadQuota]);

  // ⌘+Enter / Ctrl+Enter to rewrite
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') {
        e.preventDefault();
        rewrite();
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [rewrite]);

  const copy = useCallback(async (axis: Axis) => {
    const r = rewrites.find((x) => x.axis === axis);
    if (!r) return;
    try {
      await navigator.clipboard.writeText(r.text);
      setCopied(axis);
      setSelected(axis);
      setTimeout(() => setCopied(null), 1800);
    } catch {
      // Fallback for clipboard-blocked contexts
      const ta = document.createElement('textarea');
      ta.value = r.text;
      document.body.appendChild(ta);
      ta.select();
      document.execCommand('copy');
      ta.remove();
      setCopied(axis);
      setSelected(axis);
      setTimeout(() => setCopied(null), 1800);
    }
  }, [rewrites]);

  const clearDraft = () => {
    setDraft('');
    setRewrites([]);
    setPerception(null);
    setSelected(null);
    setError(null);
    textareaRef.current?.focus();
  };

  const pasteFromClipboard = async () => {
    try {
      const t = await navigator.clipboard.readText();
      setDraft(t);
    } catch {
      // permission denied — focus textarea, user pastes manually
      textareaRef.current?.focus();
    }
  };

  return (
    <div style={shellStyle}>
      {/* NAV */}
      <header style={navStyle}>
        <div style={navInnerStyle}>
          <Link href="/app/app" style={brandStyle} aria-label="tono home">
            <span aria-hidden style={brandDotStyle} />
            <span style={{ fontSize: 18, fontWeight: 700, letterSpacing: '-0.02em' }}>tono</span>
          </Link>
          <nav aria-label="Breadcrumb" style={crumbStyle}>
            <span>app</span>
            <span style={{ color: 'var(--muted)' }}>/</span>
            <span style={{ color: 'var(--text)' }}>rewrite</span>
            <span style={{ color: 'var(--muted)' }}>/</span>
            <span>{draft ? 'draft' : 'unsaved draft'}</span>
          </nav>
          <div style={navMetaStyle}>
            <Link href="/app/app/history" style={ghostBtn} title="history">
              history
            </Link>
            <span style={quotaStyle} title={limit ? `${limit.used} of ${limit.max} requests used` : ''}>
              <span style={{ width: 6, height: 6, borderRadius: '50%', background: 'var(--accent)' }} />
              <span>
                <strong>{limit ? limit.used : '–'}</strong> / {limit ? (limit.max === Infinity ? '∞' : limit.max) : '–'} requests
              </span>
            </span>
            <span style={avatarStyle} title={email}>
              {(email[0] || '?').toUpperCase()}
            </span>
            <form action="/app/api/auth/signout" method="post" style={{ display: 'inline' }}>
              <button type="submit" style={ghostBtn}>
                sign out
              </button>
            </form>
          </div>
        </div>
      </header>

      {/* WORKSPACE */}
      <main style={workspaceStyle}>
        {/* LEFT — composer */}
        <section aria-label="your draft" style={panelStyle}>
          <header style={panelHeadStyle}>
            <div style={panelTitleStyle}>
              <PencilIcon /> your draft
            </div>
            <div style={{ display: 'flex', gap: 4 }}>
              <button
                type="button"
                className="icon-btn"
                onClick={pasteFromClipboard}
                title="Paste from clipboard"
                aria-label="Paste"
                style={iconBtnStyle}
              >
                <ClipboardIcon />
              </button>
              <button
                type="button"
                className="icon-btn"
                onClick={clearDraft}
                title="Clear"
                aria-label="Clear"
                style={iconBtnStyle}
              >
                <TrashIcon />
              </button>
            </div>
          </header>

          <div style={composerStyle}>
            <textarea
              ref={textareaRef}
              value={draft}
              onChange={(e) => setDraft(e.target.value)}
              placeholder="paste any text. four rewrites in two seconds."
              aria-label="Draft text"
              style={textareaStyle}
            />
            <div style={composerMetaStyle}>
              <span className="count">
                <strong>{draft.length}</strong> chars
              </span>
              <span>saved · just now</span>
            </div>
          </div>

          <div role="group" aria-label="Rewrite tones" style={tonePickerStyle}>
            {AXES.map((axis) => (
              <div key={axis} style={toneChipStyle}>
                <span style={{ ...swatchStyle, background: AXIS_COLOR[axis] }} />
                {axis}
              </div>
            ))}
          </div>

          <div style={runBarStyle}>
            <span style={{ fontSize: 12, color: 'var(--muted)', display: 'flex', alignItems: 'center', gap: 6 }}>
              <Kbd>⌘</Kbd>
              <Kbd>↵</Kbd>
              to rewrite
            </span>
            <button
              type="button"
              onClick={rewrite}
              disabled={loading || !draft.trim()}
              style={{
                ...btnPrimary,
                opacity: !draft.trim() || loading ? 0.55 : 1,
                cursor: !draft.trim() || loading ? 'not-allowed' : 'pointer',
              }}
            >
              {loading ? 'rewriting…' : 'rewrite'}
              <ArrowIcon />
            </button>
          </div>
        </section>

        {/* RIGHT — results */}
        <section aria-label="Rewrite suggestions" style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
          <header style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '4px 2px' }}>
            <div style={{ display: 'flex', alignItems: 'baseline', gap: 12 }}>
              <h1 style={{ fontSize: 20, fontWeight: 600, letterSpacing: '-0.01em', margin: 0 }}>
                {rewrites.length ? 'four ways to say it.' : 'paste. rewrite. send.'}
              </h1>
              <span style={{ color: 'var(--text-softer)', fontSize: 13 }}>
                {rewrites.length ? 'pick one, copy, send.' : ''}
              </span>
            </div>
          </header>

          {error && (
            <div role="alert" style={errorBannerStyle}>
              <span>{error}</span>
            </div>
          )}

          {perception && perception.subtext && rewrites.length > 0 && (
            <div style={perceptionStyle}>
              <span style={{ color: 'var(--text-softer)', fontSize: 12, fontWeight: 600, textTransform: 'uppercase', letterSpacing: '0.06em' }}>
                read
              </span>
              <p style={{ margin: '4px 0 0', color: 'var(--text-soft)', fontSize: 14 }}>{perception.subtext}</p>
            </div>
          )}

          {rewrites.length === 0 && !loading && !error && (
            <EmptyState />
          )}

          {loading && rewrites.length === 0 && (
            <LoadingState />
          )}

          {rewrites.length > 0 && (
            <div style={rewritesGridStyle}>
              {rewrites.map((r) => (
                <RewriteCard
                  key={r.axis}
                  rewrite={r}
                  selected={selected === r.axis}
                  copied={copied === r.axis}
                  onSelect={() => setSelected(r.axis)}
                  onCopy={() => copy(r.axis)}
                />
              ))}
            </div>
          )}

          {copied && (
            <div role="status" aria-live="polite" style={summaryStyle}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 14 }}>
                <div style={summaryMarkStyle} aria-hidden>
                  <CheckIcon />
                </div>
                <div>
                  <h3 style={{ fontSize: 14, fontWeight: 600, margin: 0 }}>
                    “{copied}” copied to clipboard
                  </h3>
                  <p style={{ fontSize: 12, color: 'var(--text-softer)', margin: '2px 0 0' }}>
                    paste it into slack, email, or anywhere. ⌘⇧v pastes without formatting.
                  </p>
                </div>
              </div>
              <button type="button" onClick={rewrite} style={btnGhost}>
                try again
              </button>
            </div>
          )}
        </section>
      </main>

      {/* STATUS */}
      <footer style={statusBarStyle}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 16 }}>
          <span style={{ display: 'inline-flex', alignItems: 'center', gap: 6, color: 'var(--text-softer)' }}>
            <span
              aria-hidden
              style={{
                width: 6,
                height: 6,
                borderRadius: '50%',
                background: 'var(--tone-safer)',
                boxShadow: '0 0 8px var(--tone-safer)',
              }}
            />
            tono is online
          </span>
          <span>draft auto-saved</span>
          {!hasApiToken && (
            <span style={{ color: 'var(--warning, #F59E0B)' }}>
              (anonymous — sign in to sync access)
            </span>
          )}
        </div>
        <div>v0.1 · <span style={{ color: 'var(--text-softer)' }}>user: {userId.slice(0, 8)}…</span></div>
      </footer>
    </div>
  );
}

function RewriteCard({
  rewrite,
  selected,
  copied,
  onSelect,
  onCopy,
}: {
  rewrite: Rewrite;
  selected: boolean;
  copied: boolean;
  onSelect: () => void;
  onCopy: () => void;
}) {
  const color = AXIS_COLOR[rewrite.axis];
  return (
    <article
      tabIndex={0}
      role="button"
      aria-pressed={selected}
      onClick={onSelect}
      onKeyDown={(e) => {
        if (e.key === 'Enter' || e.key === ' ') {
          e.preventDefault();
          onCopy();
        }
      }}
      style={{
        ...cardStyle,
        ...(selected ? cardSelectedStyle : null),
        borderColor: selected ? color : 'var(--border)',
      }}
    >
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 14 }}>
        <span style={{ ...tagStyle, color }}>
          <span style={{ ...dotStyle, background: color }} />
          {rewrite.axis}
        </span>
        <span style={{ fontSize: 11, color: 'var(--text-softer)', fontFamily: 'var(--mono, monospace)' }}>
          {rewrite.rationale || '—'}
        </span>
      </div>
      <p style={bodyStyle}>{rewrite.text}</p>
      <div style={cardFootStyle}>
        <div style={{ fontSize: 12, color: 'var(--text-softer)', display: 'flex', gap: 12 }}>
          <span style={{ display: 'inline-flex', alignItems: 'center', gap: 5 }}>
            <ClockIcon /> {estimateReadTime(rewrite.text)}
          </span>
          <span style={{ display: 'inline-flex', alignItems: 'center', gap: 5 }}>
            <LinesIcon /> {rewrite.text.length} chars
          </span>
        </div>
        <button
          type="button"
          onClick={(e) => {
            e.stopPropagation();
            onCopy();
          }}
          aria-label={`Copy ${rewrite.axis} rewrite`}
          style={{
            ...copyBtnStyle,
            ...(selected ? { background: color, borderColor: color, color: '#000' } : null),
          }}
        >
          <ClipboardIcon />
          {copied ? 'copied' : 'copy'}
        </button>
      </div>
    </article>
  );
}

function EmptyState() {
  return (
    <div style={emptyStyle}>
      <div style={{ fontSize: 48, marginBottom: 12, opacity: 0.4 }}>✎</div>
      <h3 style={{ fontSize: 18, fontWeight: 600, margin: 0 }}>paste. rewrite. send.</h3>
      <p style={{ color: 'var(--text-softer)', fontSize: 14, margin: '6px 0 0', maxWidth: 360, textAlign: 'center' }}>
        type or paste a draft. tono will show you four rewrites — pick one, copy it, ship it.
      </p>
    </div>
  );
}

function LoadingState() {
  return (
    <div style={{ ...emptyStyle, padding: 40 }}>
      <div style={loadingDotsStyle}>
        <span style={dotStyle1} />
        <span style={dotStyle2} />
        <span style={dotStyle3} />
      </div>
      <p style={{ color: 'var(--text-softer)', fontSize: 14, margin: '12px 0 0' }}>rewriting…</p>
    </div>
  );
}

const loadingDotsStyle: React.CSSProperties = {
  display: 'flex',
  gap: 6,
  alignItems: 'center',
};
const dotBase: React.CSSProperties = {
  width: 8,
  height: 8,
  borderRadius: '50%',
  background: 'var(--accent)',
  animation: 'tono-pulse 1.2s ease-in-out infinite',
};
const dotStyle1: React.CSSProperties = { ...dotBase };
const dotStyle2: React.CSSProperties = { ...dotBase, animationDelay: '0.15s' };
const dotStyle3: React.CSSProperties = { ...dotBase, animationDelay: '0.3s' };

function Kbd({ children }: { children: React.ReactNode }) {
  return (
    <kbd
      style={{
        fontFamily: 'var(--mono, monospace)',
        background: 'var(--bg-elev)',
        border: '1px solid var(--border)',
        padding: '2px 6px',
        borderRadius: 4,
        fontSize: 11,
        color: 'var(--text-soft)',
      }}
    >
      {children}
    </kbd>
  );
}

function estimateReadTime(text: string): string {
  const words = text.trim().split(/\s+/).length;
  const seconds = Math.max(1, Math.round((words / 220) * 60));
  return `${seconds}s read`;
}

// ── history (localStorage v1) ──────────────────────────────────────
function saveToHistory(entry: HistoryEntry) {
  if (typeof window === 'undefined') return;
  try {
    const raw = window.localStorage.getItem('tono:history');
    const list: HistoryEntry[] = raw ? JSON.parse(raw) : [];
    list.unshift(entry);
    // cap to last 50 — localStorage quota, etc.
    window.localStorage.setItem('tono:history', JSON.stringify(list.slice(0, 50)));
  } catch {
    // localStorage may be disabled (private mode); ignore.
  }
}

export type HistoryEntry = {
  id: string;
  timestamp: number;
  draft: string;
  suggestions: Rewrite[];
  perception: string;
};

// ── styles ────────────────────────────────────────────────────────
const shellStyle: React.CSSProperties = {
  position: 'relative',
  minHeight: '100vh',
  display: 'grid',
  gridTemplateRows: 'auto 1fr auto',
};

const navStyle: React.CSSProperties = {
  borderBottom: '1px solid var(--border)',
  background: 'rgba(0,0,0,0.6)',
  backdropFilter: 'saturate(180%) blur(14px)',
  WebkitBackdropFilter: 'saturate(180%) blur(14px)',
};
const navInnerStyle: React.CSSProperties = {
  maxWidth: 1280,
  margin: '0 auto',
  padding: '14px 24px',
  display: 'flex',
  alignItems: 'center',
  justifyContent: 'space-between',
  gap: 24,
};
const brandStyle: React.CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  gap: 10,
  fontWeight: 700,
  fontSize: 18,
  letterSpacing: '-0.02em',
  color: 'var(--text)',
};
const brandDotStyle: React.CSSProperties = {
  width: 10,
  height: 10,
  borderRadius: '50%',
  background: 'var(--accent)',
  boxShadow: '0 0 16px var(--accent-glow)',
};
const crumbStyle: React.CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  gap: 8,
  color: 'var(--text-soft)',
  fontSize: 14,
};
const navMetaStyle: React.CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  gap: 12,
};
const quotaStyle: React.CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  gap: 8,
  padding: '6px 12px',
  background: 'var(--bg-card)',
  border: '1px solid var(--border)',
  borderRadius: 999,
  fontSize: 13,
  color: 'var(--text-soft)',
};
const avatarStyle: React.CSSProperties = {
  width: 32,
  height: 32,
  borderRadius: '50%',
  background: 'linear-gradient(135deg, #A855F7, #38BDF8)',
  display: 'grid',
  placeItems: 'center',
  fontSize: 12,
  fontWeight: 600,
  color: '#000',
};
const ghostBtn: React.CSSProperties = {
  background: 'transparent',
  border: '1px solid transparent',
  color: 'var(--text-soft)',
  padding: '8px 12px',
  borderRadius: 'var(--radius-sm)',
  fontSize: 13,
  fontWeight: 500,
  cursor: 'pointer',
};

const workspaceStyle: React.CSSProperties = {
  maxWidth: 1280,
  margin: '0 auto',
  padding: '32px 24px 48px',
  display: 'grid',
  gridTemplateColumns: 'minmax(320px, 420px) 1fr',
  gap: 24,
  alignItems: 'stretch',
};

const panelStyle: React.CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
  background: 'var(--bg-card)',
  border: '1px solid var(--border)',
  borderRadius: 'var(--radius-lg)',
  overflow: 'hidden',
};

const panelHeadStyle: React.CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  justifyContent: 'space-between',
  padding: '16px 18px',
  borderBottom: '1px solid var(--border)',
};

const panelTitleStyle: React.CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  gap: 10,
  fontSize: 13,
  fontWeight: 600,
  color: 'var(--text-soft)',
  letterSpacing: '0.02em',
  textTransform: 'uppercase',
};

const iconBtnStyle: React.CSSProperties = {
  width: 32,
  height: 32,
  display: 'grid',
  placeItems: 'center',
  background: 'transparent',
  border: '1px solid transparent',
  borderRadius: 'var(--radius-sm)',
  color: 'var(--text-softer)',
  cursor: 'pointer',
};

const composerStyle: React.CSSProperties = {
  flex: 1,
  padding: 18,
  display: 'flex',
  flexDirection: 'column',
  gap: 12,
};

const textareaStyle: React.CSSProperties = {
  width: '100%',
  minHeight: 280,
  flex: 1,
  resize: 'none',
  background: 'transparent',
  color: 'var(--text)',
  border: 'none',
  outline: 'none',
  font: '400 15px/1.7 Inter, sans-serif',
  caretColor: 'var(--accent)',
};

const composerMetaStyle: React.CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  justifyContent: 'space-between',
  fontSize: 12,
  color: 'var(--muted)',
};

const tonePickerStyle: React.CSSProperties = {
  display: 'grid',
  gridTemplateColumns: 'repeat(4, 1fr)',
  gap: 8,
  padding: 14,
  borderTop: '1px solid var(--border)',
  background: 'var(--bg-soft)',
};

const toneChipStyle: React.CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  gap: 8,
  padding: '8px 10px',
  borderRadius: 'var(--radius-md)',
  background: 'transparent',
  border: '1px solid var(--border)',
  color: 'var(--text-soft)',
  fontSize: 13,
  fontWeight: 500,
  justifyContent: 'center',
};

const swatchStyle: React.CSSProperties = {
  width: 8,
  height: 8,
  borderRadius: '50%',
};

const runBarStyle: React.CSSProperties = {
  padding: '16px 18px',
  borderTop: '1px solid var(--border)',
  display: 'flex',
  alignItems: 'center',
  justifyContent: 'space-between',
  gap: 12,
};

const btnPrimary: React.CSSProperties = {
  display: 'inline-flex',
  alignItems: 'center',
  gap: 8,
  padding: '10px 18px',
  borderRadius: 'var(--radius-md)',
  fontSize: 14,
  fontWeight: 600,
  border: '1px solid var(--accent)',
  background: 'var(--accent)',
  color: '#fff',
  transition: 'all var(--duration) var(--ease)',
  cursor: 'pointer',
};

const btnGhost: React.CSSProperties = {
  display: 'inline-flex',
  alignItems: 'center',
  gap: 8,
  padding: '10px 18px',
  borderRadius: 'var(--radius-md)',
  fontSize: 14,
  fontWeight: 600,
  background: 'transparent',
  color: 'var(--text-soft)',
  border: '1px solid transparent',
  cursor: 'pointer',
};

const errorBannerStyle: React.CSSProperties = {
  padding: '14px 16px',
  background: 'rgba(239,68,68,0.08)',
  border: '1px solid rgba(239,68,68,0.3)',
  borderRadius: 'var(--radius-md)',
  color: '#FCA5A5',
  fontSize: 14,
};

const perceptionStyle: React.CSSProperties = {
  padding: '12px 16px',
  background: 'var(--bg-soft)',
  border: '1px solid var(--border)',
  borderRadius: 'var(--radius-md)',
};

const rewritesGridStyle: React.CSSProperties = {
  display: 'grid',
  gridTemplateColumns: '1fr 1fr',
  gap: 14,
};

const cardStyle: React.CSSProperties = {
  position: 'relative',
  display: 'flex',
  flexDirection: 'column',
  background: 'var(--bg-card)',
  border: '1px solid var(--border)',
  borderRadius: 'var(--radius-lg)',
  padding: 18,
  transition: 'all var(--duration) var(--ease)',
  cursor: 'pointer',
  minHeight: 220,
};

const cardSelectedStyle: React.CSSProperties = {
  boxShadow: '0 0 0 1px var(--accent), 0 12px 48px rgba(168,85,247,0.18)',
};

const tagStyle: React.CSSProperties = {
  display: 'inline-flex',
  alignItems: 'center',
  gap: 8,
  padding: '4px 10px',
  borderRadius: 999,
  fontSize: 11,
  fontWeight: 600,
  letterSpacing: '0.04em',
  textTransform: 'uppercase',
  background: 'var(--bg-elev)',
  border: '1px solid var(--border)',
};

const dotStyle: React.CSSProperties = {
  width: 7,
  height: 7,
  borderRadius: '50%',
};

const bodyStyle: React.CSSProperties = {
  fontSize: 15,
  lineHeight: 1.65,
  color: 'var(--text)',
  flex: 1,
  margin: '0 0 16px',
  whiteSpace: 'pre-wrap',
};

const cardFootStyle: React.CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  justifyContent: 'space-between',
  gap: 10,
  paddingTop: 12,
  borderTop: '1px dashed var(--border)',
};

const copyBtnStyle: React.CSSProperties = {
  display: 'inline-flex',
  alignItems: 'center',
  gap: 6,
  padding: '6px 12px',
  background: 'var(--bg-elev)',
  border: '1px solid var(--border)',
  color: 'var(--text-soft)',
  borderRadius: 999,
  fontSize: 12,
  fontWeight: 500,
  cursor: 'pointer',
};

const summaryStyle: React.CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  justifyContent: 'space-between',
  padding: '16px 20px',
  background: 'linear-gradient(135deg, rgba(168,85,247,0.08), rgba(168,85,247,0.02))',
  border: '1px solid var(--border)',
  borderRadius: 'var(--radius-lg)',
};

const summaryMarkStyle: React.CSSProperties = {
  width: 36,
  height: 36,
  display: 'grid',
  placeItems: 'center',
  background: 'var(--accent)',
  color: '#fff',
  borderRadius: 'var(--radius-md)',
  boxShadow: '0 4px 16px var(--accent-glow)',
};

const statusBarStyle: React.CSSProperties = {
  borderTop: '1px solid var(--border)',
  padding: '10px 24px',
  background: 'rgba(0,0,0,0.5)',
  backdropFilter: 'blur(8px)',
  display: 'flex',
  alignItems: 'center',
  justifyContent: 'space-between',
  fontSize: 12,
  color: 'var(--muted)',
};

const emptyStyle: React.CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
  alignItems: 'center',
  justifyContent: 'center',
  padding: 80,
  background: 'var(--bg-card)',
  border: '1px dashed var(--border)',
  borderRadius: 'var(--radius-lg)',
  textAlign: 'center',
};

// (loadingDotsStyle defined earlier in the file)

// ── icons (inline SVG to avoid deps) ──────────────────────────────
function PencilIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2.5} strokeLinecap="round" strokeLinejoin="round" aria-hidden>
      <path d="M12 20h9" />
      <path d="M16.5 3.5a2.121 2.121 0 1 1 3 3L7 19l-4 1 1-4Z" />
    </svg>
  );
}
function ClipboardIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" aria-hidden>
      <rect x="8" y="2" width="8" height="4" rx="1" />
      <path d="M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2" />
    </svg>
  );
}
function TrashIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" aria-hidden>
      <path d="M3 6h18" />
      <path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6" />
      <path d="M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2" />
    </svg>
  );
}
function ArrowIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2.5} strokeLinecap="round" strokeLinejoin="round" aria-hidden>
      <path d="M5 12h14" />
      <path d="m12 5 7 7-7 7" />
    </svg>
  );
}
function CheckIcon() {
  return (
    <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2.5} strokeLinecap="round" strokeLinejoin="round" aria-hidden>
      <polyline points="20 6 9 17 4 12" />
    </svg>
  );
}
function ClockIcon() {
  return (
    <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" aria-hidden>
      <circle cx="12" cy="12" r="10" />
      <polyline points="12 6 12 12 16 14" />
    </svg>
  );
}
function LinesIcon() {
  return (
    <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" aria-hidden>
      <path d="M3 7h18" />
      <path d="M3 12h18" />
      <path d="M3 17h18" />
    </svg>
  );
}