// Edge-runtime middleware client. Used to:
//   1. Refresh Supabase JWT on every request (Sherlock's runbook #5)
//   2. Read auth cookies for server-side route protection
//
// Lives in /lib so middleware.ts can import from edge-safe path.
// This file MUST stay edge-safe — no Node-only APIs.

import { createServerClient } from '@supabase/ssr';
import type { NextRequest } from 'next/server';
import { NextResponse } from 'next/server';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL || '';
const SUPABASE_ANON_KEY = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY || '';

export async function updateSession(request: NextRequest) {
  let response = NextResponse.next({
    request: {
      headers: request.headers,
    },
  });

  const supabase = createServerClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    cookies: {
      getAll() {
        return request.cookies.getAll();
      },
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      setAll(cookiesToSet: { name: string; value: string; options?: Record<string, unknown> }[]) {
        cookiesToSet.forEach(({ name, value }) =>
          request.cookies.set(name, value)
        );
        response = NextResponse.next({
          request: {
            headers: request.headers,
          },
        });
        cookiesToSet.forEach(({ name, value, options }) =>
          response.cookies.set(name, value, options)
        );
      },
    },
  });

  // IMPORTANT: triggers the refresh token flow if the access JWT is expired
  // (Sherlock's runbook #5 — default Supabase JWT TTL = 3600s).
  // Must be awaited inside the middleware handler.
  await supabase.auth.getUser();

  return response;
}