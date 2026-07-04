// POST /api/auth/signout — clears Supabase session cookies + tono tokens,
// then redirects back to /app/login.

import { NextResponse } from 'next/server';
import { createServerSupabase } from '@/lib/supabase';
import { cookies } from 'next/headers';

export async function POST(request: Request) {
  try {
    const supabase = await createServerSupabase();
    await supabase.auth.signOut();
  } catch {
    // ignore — even if sign-out fails, we still clear our cookies below
  }

  cookies().delete('tono_api_token');
  cookies().delete('tono_plan');

  const url = new URL(request.url);
  return NextResponse.redirect(`${url.protocol}//${url.host}/app/login`);
}