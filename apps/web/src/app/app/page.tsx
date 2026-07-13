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

export default async function RewritePage() {
  const supabase = await createServerSupabase();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect('/app/login?next=/app/app');
  }

  const apiToken = cookies().get('tono_api_token')?.value;

  return (
    <RewriteEditor
      email={user.email || ''}
      userId={user.id}
      hasApiToken={!!apiToken}
    />
  );
}