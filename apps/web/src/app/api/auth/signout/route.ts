// POST /api/auth/signout — clears Supabase session cookies + tono tokens,
// then redirects back to /app/login.

import { NextResponse } from 'next/server';
import { createServerSupabase } from '@/lib/supabase';
import { cookies } from 'next/headers';
import { APP_ENTRY_PATH, buildLoginRedirect } from '@/lib/auth-redirects';

export async function POST() {
  try {
    const supabase = await createServerSupabase();
    await supabase.auth.signOut();
  } catch {
    // ignore — even if sign-out fails, we still clear our cookies below
  }

  const cookieStore = await cookies();
  cookieStore.delete('tono_api_token');
  cookieStore.delete('tono_plan');

  return NextResponse.redirect(buildLoginRedirect(APP_ENTRY_PATH));
}