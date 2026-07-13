'use client';

import { useEffect, useState, useCallback, useMemo } from 'react';
import Link from 'next/link';

// Mirrors HistoryEntry in /app/app/editor-client.tsx
type Rewrite = {
  axis: 'warmer' | 'clearer' | 'funnier' | 'safer';
  text: string;
  why?: string;
};

type HistoryEntry = {
  id: string;
  timestamp: number;
  draft: string;
  suggestions: Rewrite[];
  perception: string;
};

const AXIS_LABEL: Record<Rewrite['axis'], string> = {
  warmer: 'warmer',
  clearer: 'clearer',
  funnier: 'funnier',
  safer: 'safer',
};

const AXIS_HEX: Record<Rewrite['axis'], string> = {
  warmer: '#F472B6',
  clearer: '#38BDF8',
  funnier: '#FBBF24',
  safer: '#34D399',
};

const STORAGE_KEY = 'tono:history';

function readHistory(): HistoryEntry[] {
  if (typeof window === 'undefined') return [];
  try {
    const raw = window.localStorage.getItem(STORAGE_KEY);
    if (!raw) return [];
    const list = JSON.parse(raw) as HistoryEntry[];
    return Array.isArray(list) ? list : [];
  } catch {
    return [];
  }
}

function writeHistory(list: HistoryEntry[]) {
  if (typeof window === 'undefined') return;
  try {
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify(list));
  } catch {
    // ignore (private mode / quota)
  }
}

function relativeTime(ts: number): string {
  const diff = Date.now() - ts;
  const min = 60_000;
  const hr = 60 * min;
  const day = 24 * hr;
  if (diff < min) return 'just now';
  if (diff < hr) return `${Math.floor(diff / min)}m ago`;
  if (diff < day) return `${Math.floor(diff / hr)}h ago`;
  if (diff < 7 * day) return `${Math.floor(diff / day)}d ago`;
  return new Date(ts).toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
}

function truncate(s: string, n: number): string {
  const t = s.replace(/\s+/g, ' ').trim();
  return t.length > n ? t.slice(0, n).trimEnd() + '…' : t;
}

export default function HistoryPage() {
  const [items, setItems] = useState<HistoryEntry[]>([]);
  const [query, setQuery] = useState('');
  const [copiedId, setCopiedId] = useState<string | null>(null);
  const [hydrated, setHydrated] = useState(false);

  useEffect(() => {
    setItems(readHistory());
    setHydrated(true);
  }, []);

  const filtered = useMemo(() => {
    if (!query.trim()) return items;
    const q = query.toLowerCase();
    return items.filter(
      (e) =>
        e.draft.toLowerCase().includes(q) ||
        e.perception?.toLowerCase().includes(q) ||
        e.suggestions.some((s) => s.text.toLowerCase().includes(q))
    );
  }, [items, query]);

  const clearAll = useCallback(() => {
    if (!confirm('Clear all rewrite history? This cannot be undone.')) return;
    writeHistory([]);
    setItems([]);
  }, []);

  const removeOne = useCallback((id: string) => {
    setItems((cur) => {
      const next = cur.filter((e) => e.id !== id);
      writeHistory(next);
      return next;
    });
  }, []);

  const copy = useCallback(async (entry: HistoryEntry, axis: Rewrite['axis']) => {
    const r = entry.suggestions.find((s) => s.axis === axis);
    if (!r) return;
    try {
      await navigator.clipboard.writeText(r.text);
    } catch {
      // textarea fallback for clipboard-blocked contexts
      const ta = document.createElement('textarea');
      ta.value = r.text;
      ta.style.position = 'fixed';
      ta.style.opacity = '0';
      document.body.appendChild(ta);
      ta.select();
      try {
        document.execCommand('copy');
      } catch {
        /* noop */
      }
      document.body.removeChild(ta);
    }
    setCopiedId(`${entry.id}:${axis}`);
    setTimeout(() => setCopiedId(null), 1500);
  }, []);

  return (
    <div style={shell}>
      <header style={nav}>
        <div style={navInner}>
          <Link href="/app/app" style={brand} title="back to editor">
            <span style={brandDot} />
            <span style={{ fontSize: 18, fontWeight: 700, letterSpacing: '-0.02em' }}>tono</span>
          </Link>
          <div style={navRight}>
            <Link href="/app/app" style={navLink}>
              ← editor
            </Link>
          </div>
        </div>
      </header>

      <main style={main}>
        <section style={headerRow}>
          <div>
            <h1 style={h1}>history</h1>
            <p style={subtitle}>
              your last {items.length === 0 ? '' : '50 '}
              rewrites, kept on this device. nothing leaves your browser.
            </p>
          </div>
          {hydrated && items.length > 0 && (
            <button onClick={clearAll} style={dangerBtn} title="clear all history">
              clear all
            </button>
          )}
        </section>

        {hydrated && items.length > 0 && (
          <div style={searchRow}>
            <input
              type="search"
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              placeholder="search drafts + rewrites…"
              style={search}
            />
            <span style={count}>
              {filtered.length} of {items.length}
            </span>
          </div>
        )}

        {!hydrated ? (
          <EmptyState label="loading…" />
        ) : items.length === 0 ? (
          <EmptyState
            label="no rewrites yet"
            cta={
              <Link href="/app/app" style={primaryBtn}>
                write your first →
              </Link>
            }
          />
        ) : filtered.length === 0 ? (
          <EmptyState label="no rewrites match that search" />
        ) : (
          <ul style={list}>
            {filtered.map((e) => (
              <li key={e.id} style={card}>
                <div style={cardHeader}>
                  <time style={time} dateTime={new Date(e.timestamp).toISOString()}>
                    {relativeTime(e.timestamp)}
                  </time>
                  <button
                    onClick={() => removeOne(e.id)}
                    style={xBtn}
                    aria-label="delete entry"
                    title="delete"
                  >
                    ×
                  </button>
                </div>

                <p style={draft}>{truncate(e.draft, 320)}</p>

                {e.perception && (
                  <p style={perception}>
                    <span style={perceptionLabel}>read</span> {truncate(e.perception, 240)}
                  </p>
                )}

                <div style={rewritesGrid}>
                  {e.suggestions
                    .slice()
                    .sort(
                      (a, b) =>
                        (['warmer', 'clearer', 'funnier', 'safer'] as const).indexOf(a.axis) -
                        (['warmer', 'clearer', 'funnier', 'safer'] as const).indexOf(b.axis)
                    )
                    .map((s) => {
                      const id = `${e.id}:${s.axis}`;
                      const isCopied = copiedId === id;
                      return (
                        <div key={s.axis} style={rewriteCard(s.axis)}>
                          <div style={rewriteCardHeader(s.axis)}>
                            <span style={dot(s.axis)} />
                            <span style={axisLabel(s.axis)}>{AXIS_LABEL[s.axis]}</span>
                          </div>
                          <p style={rewriteText}>{truncate(s.text, 220)}</p>
                          <button
                            onClick={() => copy(e, s.axis)}
                            style={copyBtn(s.axis, isCopied)}
                          >
                            {isCopied ? 'copied' : 'copy'}
                          </button>
                        </div>
                      );
                    })}
                </div>
              </li>
            ))}
          </ul>
        )}
      </main>

      <footer style={footer}>
        <span style={footerText}>tono — v1 · local-only history</span>
      </footer>
    </div>
  );
}

function EmptyState({ label, cta }: { label: string; cta?: React.ReactNode }) {
  return (
    <div style={empty}>
      <p style={emptyLabel}>{label}</p>
      {cta && <div style={{ marginTop: 20 }}>{cta}</div>}
    </div>
  );
}

// ── styles (mirrors design tokens, kept local to the file) ──────────────
const ACCENT = '#A855F7';
const BORDER = '#1F1F23';
const BORDER_STRONG = '#2A2A30';
const TEXT = '#FFFFFF';
const TEXT_SOFT = '#C9C9D1';
const TEXT_SOFTER = '#9CA3AF';
const MUTED = '#6B7280';
const BG_CARD = '#111113';
const BG_ELEV = '#16161A';
const RADIUS = 18;

const shell: React.CSSProperties = {
  position: 'relative',
  minHeight: '100vh',
  display: 'grid',
  gridTemplateRows: 'auto 1fr auto',
  background: '#000000',
  color: TEXT,
  fontFamily:
    'Inter, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif',
};

const nav: React.CSSProperties = {
  borderBottom: `1px solid ${BORDER}`,
  background: 'rgba(0,0,0,0.6)',
  backdropFilter: 'saturate(180%) blur(14px)',
  WebkitBackdropFilter: 'saturate(180%) blur(14px)',
};

const navInner: React.CSSProperties = {
  maxWidth: 1080,
  margin: '0 auto',
  padding: '14px 24px',
  display: 'flex',
  alignItems: 'center',
  justifyContent: 'space-between',
};

const brand: React.CSSProperties = {
  display: 'inline-flex',
  alignItems: 'center',
  gap: 8,
  fontWeight: 600,
  fontSize: 15,
  letterSpacing: '-0.01em',
  color: TEXT,
};

const brandDot: React.CSSProperties = {
  width: 10,
  height: 10,
  borderRadius: 999,
  background: ACCENT,
  boxShadow: `0 0 16px rgba(168,85,247,0.7)`,
};

const navRight: React.CSSProperties = { display: 'flex', gap: 16, alignItems: 'center' };

const navLink: React.CSSProperties = {
  fontSize: 13,
  color: TEXT_SOFT,
  padding: '6px 10px',
  borderRadius: 8,
  border: `1px solid ${BORDER}`,
  background: BG_ELEV,
};

const main: React.CSSProperties = {
  maxWidth: 1080,
  width: '100%',
  margin: '0 auto',
  padding: '32px 24px 64px',
};

const headerRow: React.CSSProperties = {
  display: 'flex',
  alignItems: 'flex-end',
  justifyContent: 'space-between',
  gap: 16,
  marginBottom: 24,
};

const h1: React.CSSProperties = {
  fontSize: 32,
  fontWeight: 600,
  letterSpacing: '-0.02em',
  margin: 0,
};

const subtitle: React.CSSProperties = {
  margin: '6px 0 0',
  fontSize: 14,
  color: TEXT_SOFTER,
  lineHeight: 1.55,
};

const dangerBtn: React.CSSProperties = {
  fontSize: 12,
  color: '#FCA5A5',
  background: 'transparent',
  border: `1px solid #2a1a1a`,
  padding: '8px 12px',
  borderRadius: 10,
  cursor: 'pointer',
};

const searchRow: React.CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  gap: 12,
  marginBottom: 20,
};

const search: React.CSSProperties = {
  flex: 1,
  background: BG_ELEV,
  border: `1px solid ${BORDER}`,
  color: TEXT,
  fontSize: 14,
  padding: '10px 14px',
  borderRadius: 12,
  outline: 'none',
};

const count: React.CSSProperties = {
  fontSize: 12,
  color: MUTED,
  fontVariantNumeric: 'tabular-nums',
  whiteSpace: 'nowrap',
};

const list: React.CSSProperties = {
  listStyle: 'none',
  margin: 0,
  padding: 0,
  display: 'flex',
  flexDirection: 'column',
  gap: 14,
};

const card: React.CSSProperties = {
  background: BG_CARD,
  border: `1px solid ${BORDER}`,
  borderRadius: RADIUS,
  padding: '18px 20px',
};

const cardHeader: React.CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  justifyContent: 'space-between',
  marginBottom: 10,
};

const time: React.CSSProperties = {
  fontSize: 12,
  color: MUTED,
  fontVariantNumeric: 'tabular-nums',
  textTransform: 'lowercase',
  letterSpacing: '0.02em',
};

const xBtn: React.CSSProperties = {
  background: 'transparent',
  border: 'none',
  color: MUTED,
  fontSize: 18,
  lineHeight: 1,
  cursor: 'pointer',
  padding: '2px 8px',
  borderRadius: 6,
};

const draft: React.CSSProperties = {
  fontSize: 15,
  lineHeight: 1.55,
  color: TEXT,
  margin: '0 0 10px',
  whiteSpace: 'pre-wrap',
  wordBreak: 'break-word',
};

const perception: React.CSSProperties = {
  fontSize: 13,
  lineHeight: 1.55,
  color: TEXT_SOFT,
  background: BG_ELEV,
  border: `1px solid ${BORDER}`,
  borderRadius: 10,
  padding: '8px 12px',
  margin: '0 0 14px',
};

const perceptionLabel: React.CSSProperties = {
  fontSize: 10,
  textTransform: 'uppercase',
  letterSpacing: '0.12em',
  color: MUTED,
  marginRight: 6,
};

const rewritesGrid: React.CSSProperties = {
  display: 'grid',
  gridTemplateColumns: 'repeat(auto-fit, minmax(220px, 1fr))',
  gap: 10,
};

function rewriteCard(axis: Rewrite['axis']): React.CSSProperties {
  return {
    background: BG_ELEV,
    border: `1px solid ${BORDER}`,
    borderLeft: `2px solid ${AXIS_HEX[axis]}`,
    borderRadius: 12,
    padding: '12px 14px',
    display: 'flex',
    flexDirection: 'column',
    gap: 8,
  };
}

function rewriteCardHeader(_axis: Rewrite['axis']): React.CSSProperties {
  return { display: 'flex', alignItems: 'center', gap: 8 };
}

function dot(axis: Rewrite['axis']): React.CSSProperties {
  return {
    width: 8,
    height: 8,
    borderRadius: 999,
    background: AXIS_HEX[axis],
  };
}

function axisLabel(axis: Rewrite['axis']): React.CSSProperties {
  return {
    fontSize: 11,
    textTransform: 'uppercase',
    letterSpacing: '0.12em',
    color: AXIS_HEX[axis],
    fontWeight: 600,
  };
}

const rewriteText: React.CSSProperties = {
  fontSize: 13.5,
  lineHeight: 1.5,
  color: TEXT_SOFT,
  margin: 0,
  whiteSpace: 'pre-wrap',
  wordBreak: 'break-word',
  flex: 1,
};

function copyBtn(axis: Rewrite['axis'], copied: boolean): React.CSSProperties {
  return {
    alignSelf: 'flex-start',
    fontSize: 11,
    textTransform: 'uppercase',
    letterSpacing: '0.1em',
    color: copied ? AXIS_HEX[axis] : TEXT_SOFTER,
    background: 'transparent',
    border: `1px solid ${BORDER_STRONG}`,
    padding: '5px 10px',
    borderRadius: 8,
    cursor: 'pointer',
    fontWeight: 600,
  };
}

const empty: React.CSSProperties = {
  textAlign: 'center',
  padding: '80px 20px',
  color: MUTED,
};

const emptyLabel: React.CSSProperties = {
  fontSize: 15,
  margin: 0,
  color: TEXT_SOFTER,
};

const primaryBtn: React.CSSProperties = {
  display: 'inline-block',
  fontSize: 14,
  fontWeight: 600,
  color: '#fff',
  background: ACCENT,
  padding: '10px 18px',
  borderRadius: 12,
  border: 'none',
  textDecoration: 'none',
};

const footer: React.CSSProperties = {
  borderTop: `1px solid ${BORDER}`,
  padding: '16px 24px',
  textAlign: 'center',
};

const footerText: React.CSSProperties = {
  fontSize: 12,
  color: MUTED,
};
