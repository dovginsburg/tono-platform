import Link from 'next/link'
import TonoBrand from './TonoBrand'

// ── Newsletter strip — replaced the no-op NewsletterSignup form
// (which only set local "subscribed" state) with a single email link.
// A real signup form is a backend project, not a marketer-lane fix. ──
function NewsletterStrip() {
  return (
    <div className="mt-10 pt-8 border-t border-tono-border">
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3">
        <p className="text-[14px] font-semibold text-tono-text">
          Get the next rewrite.
        </p>
        <a
          href="mailto:hello@tonoit.com?subject=tono%20newsletter"
          className="inline-flex items-center justify-center gap-2 px-4 py-2.5 rounded-[10px] bg-tono-accent hover:bg-tono-accent-hover text-white font-semibold transition min-h-[44px] text-[13px]"
        >
          Subscribe by email
        </a>
      </div>
      <p className="text-[11px] text-tono-muted mt-3">
        One short email a month. No tracking pixels, no marketing automation — open your mail client and hit send.
      </p>
    </div>
  )
}

// ──────────────────────────────────────────────────────────────────────
// TonoFooter — site-wide footer + trust rail
// ──────────────────────────────────────────────────────────────────────
//
// Lives in the root layout so it ships on every page (not just /).
// Layout: 5 columns (Brand / Product / Company / Legal / Social) on
// desktop, stacked on mobile (<768px). The first clickable element on
// mobile is a prominent "Home" link above the column stack — Dov
// requirement, "back to home from any page."
//
// Newsletter signup is wired to a no-op endpoint for now; backend
// integration is a TODO and the form is a stub that shows a success
// state locally.
//
// Crisis / support line is intentionally absent — Tono is not a
// clinical product. (ParentScript's footer is the one that needs
// the 988 line.)

export default function TonoFooter() {
  const year = new Date().getFullYear()

  return (
    <footer className="border-t border-tono-border bg-tono-bg-soft">
      {/* ── Mobile-first "Home" link — the FIRST clickable element
              in the footer on mobile. Above the column stack. Hidden
              on md+ where the brand wordmark fills the role. ──────── */}
      <div className="md:hidden border-b border-tono-border">
        <div className="max-w-[1180px] mx-auto px-6 py-4">
          <Link
            href="/"
            aria-label="tono — back to home"
            className="flex items-center gap-2 text-[15px] font-semibold text-tono-text hover:text-tono-accent-light transition min-h-[44px]"
          >
            <span aria-hidden="true">←</span>
            <span>Home</span>
          </Link>
        </div>
      </div>

      <div className="max-w-[1180px] mx-auto px-6 md:px-10 py-10 md:py-12">
        {/* ── 5-column grid: Brand | Product | Company | Legal | Social
                On desktop: 5 col. On mobile: single column stack. ── */}
        <div className="grid grid-cols-1 sm:grid-cols-2 md:grid-cols-5 gap-8">
          {/* Brand */}
          <div className="sm:col-span-2 md:col-span-1">
            <TonoBrand lockup compact />
            <p className="text-[13px] text-tono-text-soft leading-[1.6] mt-3 max-w-xs">
              Before you send it, see how it can land.
            </p>
          </div>

          {/* Product */}
          <div>
            <p className="text-[11px] uppercase tracking-wider font-semibold text-tono-text-softer mb-3">
              Product
            </p>
            <ul className="space-y-2 text-[13px]">
              <li>
                <Link href="/#how" className="text-tono-text-soft hover:text-tono-text transition">
                  How it works
                </Link>
              </li>
              <li>
                <Link href="/#pricing" className="text-tono-text-soft hover:text-tono-text transition">
                  Pricing
                </Link>
              </li>
              <li>
                <Link href="/login" className="inline-flex items-center min-h-[44px] min-w-[44px] text-tono-text-soft hover:text-tono-text transition">
                  Sign in
                </Link>
              </li>
              <li>
                <Link href="/account" className="inline-flex items-center min-h-[44px] min-w-[44px] text-tono-text-soft hover:text-tono-text transition">
                  Account
                </Link>
              </li>
              <li>
                <a
                  href="mailto:hi@tonoit.com?subject=tono%20feedback"
                  className="text-tono-text-soft hover:text-tono-text transition"
                >
                  Feedback
                </a>
              </li>
              <li>
                <Link href="/blog" className="text-tono-text-soft hover:text-tono-text transition">
                  Changelog
                </Link>
              </li>
            </ul>
          </div>

          {/* Company */}
          <div>
            <p className="text-[11px] uppercase tracking-wider font-semibold text-tono-text-softer mb-3">
              Company
            </p>
            <ul className="space-y-2 text-[13px]">
              <li>
                <Link href="/about" className="text-tono-text-soft hover:text-tono-text transition">
                  About
                </Link>
              </li>
              <li>
                <Link
                  href="/contact"
                  className="text-tono-text-soft hover:text-tono-text transition"
                >
                  Contact
                </Link>
              </li>
              <li>
                <a
                  href="mailto:press@tonoit.com"
                  className="text-tono-text-soft hover:text-tono-text transition"
                >
                  Press
                </a>
              </li>
              <li>
                <a
                  href="mailto:hello@tonoit.com"
                  className="text-tono-text-soft hover:text-tono-text transition"
                >
                  Partnerships
                </a>
              </li>
            </ul>
          </div>

          {/* Legal */}
          <div>
            <p className="text-[11px] uppercase tracking-wider font-semibold text-tono-text-softer mb-3">
              Legal
            </p>
            <ul className="space-y-2 text-[13px]">
              <li>
                <Link
                  href="/privacy"
                  className="text-tono-text-soft hover:text-tono-text transition"
                >
                  Privacy
                </Link>
              </li>
              <li>
                <Link href="/terms" className="text-tono-text-soft hover:text-tono-text transition">
                  Terms
                </Link>
              </li>
              <li>
                <a
                  href="mailto:hi@tonoit.com?subject=tono%20data%20deletion"
                  className="text-tono-text-soft hover:text-tono-text transition"
                >
                  Data deletion
                </a>
              </li>
            </ul>
          </div>

          {/* Social */}
          <div className="sm:col-span-2 md:col-span-1">
            <p className="text-[11px] uppercase tracking-wider font-semibold text-tono-text-softer mb-3">
              Social
            </p>
            <ul className="space-y-2 text-[13px]">
              <li>
                <a
                  href="https://github.com/dovginsburg/tono-platform"
                  target="_blank"
                  rel="noopener noreferrer"
                  className="text-tono-text-soft hover:text-tono-text transition"
                >
                  GitHub
                </a>
              </li>

              <li>
                <a
                  href="mailto:hi@tonoit.com?subject=tono%20product%20updates"
                  className="text-tono-text-soft hover:text-tono-text transition"
                >
                  Product updates
                </a>
              </li>
            </ul>
          </div>
        </div>

        {/* ── Newsletter strip — replaced the no-op form with a mailto.
                Real signup backend is out of scope for this audit. ── */}
        <NewsletterStrip />

        <p className="mt-8 text-[12px] text-tono-text-softer leading-relaxed">
          One lifetime 14-day trial per customer, then $3.99/month or $39.99/year. Paid plans include unlimited rewrites. No free tier. Subscriptions auto-renew unless cancelled.
        </p>

        {/* Bottom rail */}
        <div className="mt-10 pt-6 border-t border-tono-border flex flex-col sm:flex-row items-start sm:items-center justify-between gap-2">
          <p className="text-[11px] text-tono-muted">
            © {year} tono. all rights reserved.
          </p>
          <p className="text-[11px] text-tono-muted">
            drafts are sent only when you choose rewrite. tono never sends on your behalf.
          </p>
        </div>
      </div>
    </footer>
  )
}
