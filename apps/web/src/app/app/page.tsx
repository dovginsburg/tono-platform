// Rewrite editor — the real workspace surface.
//
// Server-side: gates on Supabase session. Redirects to /app/login
// with `?next=/app/app` if no session. Reads the tono_api_token
// cookie for the quota pill.
//
// Client-side: paste → click rewrite → POST /api/analyze → render
// 4 cards (warmer / clearer / funnier / safer). Click a card to
// "select" it; click copy to put the rewrite in the clipboard.

import { redirect } from 'next/navigation';
import { createServerSupabase } from '@/lib/supabase';
import { cookies } from 'next/headers';
import { RewriteEditor } from './editor-client';
import { APP_ENTRY_PATH, buildLoginRedirect } from '@/lib/auth-redirects';

export default async function RewritePage() {
  const supabase = await createServerSupabase();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    // Use an absolute, validated URL so Next cannot apply basePath twice to the
    // Location header during a direct HTTP navigation.
    redirect(buildLoginRedirect(APP_ENTRY_PATH));
  }

  const cookieStore = await cookies();
  const apiToken = cookieStore.get('tono_api_token')?.value;

  return (
    <RewriteEditor
      email={user.email || ''}
      userId={user.id}
      hasApiToken={!!apiToken}
    />
  );
}