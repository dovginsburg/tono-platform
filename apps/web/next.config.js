const { loadSupabaseDeployment } = require('./src/lib/supabase-deployment.cjs');

const supabaseDeployment = loadSupabaseDeployment(process.env, { allowUnconfigured: true });

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
  //
  // Returning an ARRAY puts every entry in Next's `afterFiles` phase, which is
  // consulted only AFTER filesystem routes. So a rewrite whose source collides
  // with a handler under src/app/api is dead config that never fires — and,
  // worse, it reads as the live definition of that path. `/api/checkout` and
  // `/api/analyze` used to be declared here as direct backend proxies while the
  // real requests were served by the route handlers, which additionally enforce
  // the same-origin CSRF guard and swap the httpOnly cookie for a bearer.
  // Moving those entries to `beforeFiles` would have silently dropped both.
  // Only paths with NO handler behind them belong here; the collision is
  // guarded by src/lib/next-rewrites.test.ts.
  //
  // Apex SEO (/sitemap.xml, /robots.txt) is served by vercel.json's rewrite to
  // /app/sitemap.xml — declaring it here produced `/app/sitemap.xml ->
  // /app/sitemap.xml`, since basePath applies to source AND destination.
  async rewrites() {
    return [
      // Tono backend — no route handler exists for either of these.
      { source: '/api/tono/:path*', destination: 'https://api.tonoit.com/v1/:path*' },
      { source: '/api/health', destination: 'https://api.tonoit.com/health' },

      // Dedicated Tono Supabase project. The environment contract above fails
      // closed when staging/production refs are shared or mismatched.
      //
      // `/auth/:path*` deliberately spans `/auth/callback`, which is OURS —
      // src/app/auth/callback/route.ts exchanges the OAuth code and mints the
      // backend bearer. It wins because these are afterFiles rewrites. Do NOT
      // promote this block to `beforeFiles`: that would proxy the callback to
      // Supabase and break sign-in. Recorded in
      // src/lib/next-rewrites.test.ts::ACKNOWLEDGED_OVERLAPS.
      ...(supabaseDeployment ? [
        { source: '/auth/:path*', destination: `${supabaseDeployment.url}/auth/v1/:path*` },
        { source: '/rest/:path*', destination: `${supabaseDeployment.url}/rest/v1/:path*` },
        { source: '/storage/:path*', destination: `${supabaseDeployment.url}/storage/v1/:path*` },
      ] : []),
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