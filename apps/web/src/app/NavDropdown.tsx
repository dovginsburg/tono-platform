'use client'

// TonoNavDropdown — top-right hamburger → menu, present on EVERY page.
//
// Spec: evidence/design/nav-spec.md (2026-07-08, Mark).
//   - Trigger: 44×44 fixed top-right, dark surface, border #1F1F23
//   - Panel: 280px, anchored top-right, opens down/left, 16px gutter
//   - Items: Home, App, Sign in, Pricing, About, Contact, Privacy, Terms
//   - Home is the first item (Dov's requirement, 2026-07-08)
//   - Keyboard: Enter/Space open, Esc close + return focus, ArrowUp/Down
//     cycle through items (Home/End jump to first/last)
//   - Outside-click closes
//   - Mobile (<768): trigger opens a full-screen slide-in drawer
//   - aria-current="page" set on the matching route (Home excluded — always navigable)
//
// Tokens (no new colors/fonts — pulled from tailwind.config.ts and globals.css):
//   bg-card #111113, border #1F1F23, border-strong #2A2A30
//   text #FFFFFF, text-soft #C9C9D1, accent #A855F7
//   focus ring: 0 0 0 3px rgba(168,85,247,0.35)
//   radius.md 12px, radius.lg 18px
// All visuals live in globals.css (.tono-nav-* classes) so the component
// is small and the styles are shared with the QA probe.

import { useEffect, useRef, useState } from 'react'
import Link from 'next/link'
import { usePathname } from 'next/navigation'

type NavItem = {
  label: string
  href: string
  /** External (mailto:, etc.) — rendered with <a> not <Link>. */
  external?: boolean
}

// All hrefs are relative to Next.js basePath '/app'. At render time
// <Link href="/pricing"> resolves to /app/pricing, <Link href="/login">
// resolves to /app/login, etc. The "App" item points at the editor
// (src/app/app/page.tsx → /app/app). Keep these consistent so the
// dropdown works from every route, including /app/app itself.
const ITEMS: NavItem[] = [
  { label: 'Home', href: '/' },
  { label: 'App', href: '/app' },
  { label: 'Sign in', href: '/login' },
  { label: 'Pricing', href: '/pricing' },
  { label: 'About', href: '/about' },
  { label: 'Features', href: '/features' },
  { label: 'Blog', href: '/blog' },
  { label: 'Contact', href: '/contact' },
  { label: 'Privacy', href: '/privacy' },
  { label: 'Terms', href: '/terms' },
]

function MenuIcon() {
  return (
    <svg
      width="24"
      height="24"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.5"
      strokeLinecap="round"
      aria-hidden="true"
    >
      <line x1="4" y1="7" x2="20" y2="7" />
      <line x1="4" y1="12" x2="20" y2="12" />
      <line x1="4" y1="17" x2="20" y2="17" />
    </svg>
  )
}

function CloseIcon() {
  return (
    <svg
      width="24"
      height="24"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.5"
      strokeLinecap="round"
      aria-hidden="true"
    >
      <line x1="6" y1="6" x2="18" y2="18" />
      <line x1="18" y1="6" x2="6" y2="18" />
    </svg>
  )
}

function ChevronIcon() {
  return (
    <svg
      width="14"
      height="14"
      viewBox="0 0 14 14"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.5"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <polyline points="5,3 9,7 5,11" />
    </svg>
  )
}

export default function TonoNavDropdown() {
  const [open, setOpen] = useState(false)
  const [isMobile, setIsMobile] = useState(false)
  const triggerRef = useRef<HTMLButtonElement | null>(null)
  const panelRef = useRef<HTMLDivElement | null>(null)
  const itemRefs = useRef<(HTMLElement | null)[]>([])
  const pathname = usePathname() || '/'

  // Detect mobile (<768) for drawer vs dropdown
  useEffect(() => {
    const mq = window.matchMedia('(max-width: 767px)')
    const sync = () => setIsMobile(mq.matches)
    sync()
    mq.addEventListener('change', sync)
    return () => mq.removeEventListener('change', sync)
  }, [])

  // Close on route change
  useEffect(() => {
    setOpen(false)
  }, [pathname])

  // Esc closes + returns focus to trigger. Arrow keys cycle items in
  // the dropdown (skipped in drawer — drawer has no focus trap, let
  // the browser tab cycle naturally).
  useEffect(() => {
    if (!open) return
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.preventDefault()
        setOpen(false)
        triggerRef.current?.focus()
        return
      }
      if (isMobile) return
      if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
        e.preventDefault()
        const current = itemRefs.current.findIndex((el) => el === document.activeElement)
        const n = ITEMS.length
        const next =
          e.key === 'ArrowDown' ? (current + 1 + n) % n : (current - 1 + n) % n
        itemRefs.current[next]?.focus()
      } else if (e.key === 'Home') {
        e.preventDefault()
        itemRefs.current[0]?.focus()
      } else if (e.key === 'End') {
        e.preventDefault()
        itemRefs.current[ITEMS.length - 1]?.focus()
      }
    }
    const onClick = (e: MouseEvent) => {
      const target = e.target as Node
      if (
        panelRef.current?.contains(target) ||
        triggerRef.current?.contains(target)
      ) {
        return
      }
      setOpen(false)
    }
    document.addEventListener('keydown', onKey)
    document.addEventListener('mousedown', onClick)
    return () => {
      document.removeEventListener('keydown', onKey)
      document.removeEventListener('mousedown', onClick)
    }
  }, [open, isMobile])

  // Lock body scroll while mobile drawer is open
  useEffect(() => {
    if (!open || !isMobile) return
    const prev = document.body.style.overflow
    document.body.style.overflow = 'hidden'
    return () => {
      document.body.style.overflow = prev
    }
  }, [open, isMobile])

  // For mobile drawer, focus the close button when opened
  useEffect(() => {
    if (open && isMobile) {
      const t = window.setTimeout(() => {
        const closeBtn = panelRef.current?.querySelector<HTMLButtonElement>('[data-tono-drawer-close]')
        closeBtn?.focus()
      }, 60)
      return () => window.clearTimeout(t)
    }
  }, [open, isMobile])

  // Home excluded from aria-current per spec — it's always navigable.
  const isCurrent = (href: string) => {
    if (href === '/') return false
    return pathname === href || pathname?.startsWith(href + '/') || false
  }

  return (
    <>
      {/* Trigger — fixed top-right, present on every page */}
      <button
        ref={triggerRef}
        type="button"
        onClick={() => setOpen((v) => !v)}
        aria-label={open ? 'Close menu' : 'Open menu'}
        aria-expanded={open}
        aria-controls="nav-panel-tono"
        data-testid="tono-nav-trigger"
        data-open={open ? 'true' : 'false'}
        className="tono-nav-trigger tono-nav-menu-toggle tono-nav-hamburger tono-nav-dropdown-toggle"
      >
        {open ? <CloseIcon /> : <MenuIcon />}
      </button>

      {open && !isMobile && (
        <div
          ref={panelRef}
          id="nav-panel-tono"
          className="tono-nav-panel"
          role="menu"
          aria-label="Site navigation"
          data-testid="tono-nav-panel"
        >
          {ITEMS.map((item) => {
            const current = isCurrent(item.href)
            const itemClass = 'tono-nav-item'
            const inner = (
              <>
                <span>{item.label}</span>
                <span className="chevron" aria-hidden="true">
                  <ChevronIcon />
                </span>
              </>
            )
            if (item.external) {
              return (
                <a
                  key={item.label}
                  ref={(el) => {
                    itemRefs.current[ITEMS.indexOf(item)] = el
                  }}
                  role="menuitem"
                  href={item.href}
                  className={itemClass}
                  data-testid={`tono-nav-item-${item.label.toLowerCase()}`}
                >
                  {inner}
                </a>
              )
            }
            return (
              <Link
                key={item.label}
                ref={(el) => {
                  itemRefs.current[ITEMS.indexOf(item)] = el
                }}
                role="menuitem"
                href={item.href}
                aria-current={current ? 'page' : undefined}
                className={itemClass}
                data-testid={`tono-nav-item-${item.label.toLowerCase()}`}
              >
                {inner}
              </Link>
            )
          })}
        </div>
      )}

      {open && isMobile && (
        <div
          ref={panelRef}
          id="nav-panel-tono"
          className="tono-nav-drawer"
          role="dialog"
          aria-modal="true"
          aria-label="Site navigation"
          data-testid="tono-nav-drawer"
        >
          <div className="tono-nav-drawer-head">
            <span
              style={{
                fontSize: 18,
                fontWeight: 700,
                letterSpacing: '-0.02em',
                color: '#FFFFFF',
                display: 'inline-flex',
                alignItems: 'center',
                gap: 8,
              }}
            >
              <span
                aria-hidden="true"
                style={{
                  width: 8,
                  height: 8,
                  borderRadius: 999,
                  background: '#A855F7',
                  boxShadow: '0 0 10px rgba(168,85,247,0.6)',
                }}
              />
              tono
            </span>
            <button
              data-tono-drawer-close
              type="button"
              onClick={() => {
                setOpen(false)
                triggerRef.current?.focus()
              }}
              aria-label="Close menu"
              className="tono-nav-drawer-close"
            >
              <CloseIcon />
            </button>
          </div>
          <nav aria-label="Site navigation" className="tono-nav-drawer-list">
            {ITEMS.map((item) => {
              const current = isCurrent(item.href)
              const inner = (
                <>
                  <span>{item.label}</span>
                  <span className="chevron" aria-hidden="true">
                    <ChevronIcon />
                  </span>
                </>
              )
              if (item.external) {
                return (
                  <a
                    key={item.label}
                    role="menuitem"
                    href={item.href}
                    className="tono-nav-drawer-item"
                    data-testid={`tono-nav-item-${item.label.toLowerCase()}`}
                  >
                    {inner}
                  </a>
                )
              }
              return (
                <Link
                  key={item.label}
                  role="menuitem"
                  href={item.href}
                  aria-current={current ? 'page' : undefined}
                  className="tono-nav-drawer-item"
                  data-testid={`tono-nav-item-${item.label.toLowerCase()}`}
                >
                  {inner}
                </Link>
              )
            })}
          </nav>
        </div>
      )}
    </>
  )
}
