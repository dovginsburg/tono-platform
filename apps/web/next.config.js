/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,

  // Deployed at tonoit.com/app/. basePath lets Next.js routes mount under
  // the sub-path without manual rewrites inside app/. The Vercel project
  // also has tonoit.com as a custom domain (Dov wires the apex CNAME).
  basePath: '/app',
  // trailingSlash: false keeps URLs clean (/app/app, not /app/app/)

  // API rewrites so the browser doesn't need to know about the backend,
  // and so Supabase auth + REST look same-origin to the browser —
  // required for cookie-based sessions to stick (Sherlock's runbook #1).
  async rewrites() {
    return [
      // SEO surface at the apex so /sitemap.xml and /robots.txt return 200
      // (basePath is applied to the destination, so /sitemap.xml → /app/sitemap.xml).
      { source: '/sitemap.xml', destination: '/sitemap.xml' },
      { source: '/robots.txt', destination: '/robots.txt' },

      // Tono backend
      { source: '/api/tono/:path*', destination: 'https://api.tonoit.com/v1/:path*' },
      { source: '/api/health', destination: 'https://api.tonoit.com/health' },
      // Stripe checkout (called by ProCheckoutButton on /pricing and /upgrade→/pricing)
      { source: '/api/checkout', destination: 'https://api.tonoit.com/v1/checkout' },
      // Authenticated analyze (uses bearer token + rate limit)
      { source: '/api/analyze', destination: 'https://api.tonoit.com/api/analyze' },

      // Supabase auth (OAuth + magic link + token refresh)
      { source: '/auth/:path*', destination: 'https://bndbgpqbpzukrbhquztj.supabase.co/auth/v1/:path*' },

      // Supabase PostgREST (only used if we read user metadata client-side)
      { source: '/rest/:path*', destination: 'https://bndbgpqbpzukrbhquztj.supabase.co/rest/v1/:path*' },

      // Supabase storage (for any avatar / asset reads in v1.x)
      { source: '/storage/:path*', destination: 'https://bndbgpqbpzukrbhquztj.supabase.co/storage/v1/:path*' },
    ];
  },

  redirects: async () => [
    // /upgrade is deprecated — single source of truth lives at /pricing.
    // Using config-level redirects (rather than a Server Component redirect())
    // so the response carries a proper HTTP Location header for full-page
    // navigations; the App Router redirect() helper emits an RSC-stream
    // redirect that only the client router picks up.
    //
    // basePath: '/app' is applied AFTER the source match, so we declare
    // the source WITHOUT the leading /app. The effective URL is
    // /app/upgrade; the destination becomes /app/pricing.
    {
      source: '/upgrade',
      destination: '/pricing',
      permanent: true,
    },
  ],

  async headers() {
    return [
      {
        source: '/:path*',
        headers: [
          { key: 'X-Content-Type-Options', value: 'nosniff' },
          { key: 'X-Frame-Options', value: 'DENY' },
          { key: 'Referrer-Policy', value: 'strict-origin-when-cross-origin' },
          { key: 'Permissions-Policy', value: 'camera=(), microphone=(), geolocation=()' },
          { key: 'Strict-Transport-Security', value: 'max-age=63072000; includeSubDomains' },
        ],
      },
    ];
  },
};

module.exports = nextConfig;