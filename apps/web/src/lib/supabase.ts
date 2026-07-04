// Supabase client wiring for the same project as Tono iOS + ParentScript.
// Users have ONE account across all three surfaces.
//
// Auth strategy: Supabase auth.js cookies via @supabase/ssr.
// Identity providers (Apple / Google) configured in Supabase dashboard;
// signInWithOAuth redirects to provider, then back to /auth/callback.
//
// Lint cleanups pending — TS noise from supabase-js/dist/module/lib/types
// import path which is fine at runtime. Cast as any for now to ship tonight.

import { createBrowserClient } from '@supabase/ssr';
import { createServerClient } from '@supabase/ssr';
import { cookies } from 'next/headers';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL || '';
const SUPABASE_ANON_KEY = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY || '';

export function createClient(): any {
  return createBrowserClient(SUPABASE_URL, SUPABASE_ANON_KEY);
}

export async function createServerSupabase(): Promise<any> {
  const cookieStore = cookies();
  return createServerClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    cookies: {
      getAll() {
        return cookieStore.getAll();
      },
      setAll(cookiesToSet: any) {
        try {
          cookiesToSet.forEach(({ name, value, options }: any) =>
            cookieStore.set(name, value, options)
          );
        } catch {
          // setAll called from a Server Component — middleware refreshes
          // the session, so this is fine.
        }
      },
    },
  });
}