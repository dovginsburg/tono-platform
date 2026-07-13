// robots.txt for tonoit.com. Served at /app/robots.txt (Next.js basePath).
//
// Two sections:
//   1. Allow the public marketing pages + auth surface so search engines
//      can index them and link to them.
//   2. Disallow the editor (/app/app) and per-user history so user-specific
//      routes are not crawled or indexed. /api/* is always disallowed.
//
// Sitemap is declared at the canonical location under /app because of the
// Next.js basePath.

import { NextResponse } from 'next/server';

const BODY = `# tonoit.com — robots
User-agent: *
Allow: /app/
Allow: /app/pricing
Allow: /app/features
Allow: /app/about
Allow: /app/contact
Allow: /app/blog
Allow: /app/privacy
Allow: /app/terms
Allow: /app/login
Disallow: /app/app
Disallow: /app/history
Disallow: /app/api/
Disallow: /app/auth/

Sitemap: https://tonoit.com/app/sitemap.xml
`;

export async function GET() {
  return new NextResponse(BODY, {
    status: 200,
    headers: {
      'Content-Type': 'text/plain; charset=utf-8',
      'Cache-Control': 'public, max-age=3600, s-maxage=3600',
    },
  });
}