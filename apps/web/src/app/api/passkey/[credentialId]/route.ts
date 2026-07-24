// DELETE /api/passkey/:credentialId — revoke a passkey from the signed-in
// account (management UI). The backend enforces account ownership before
// deleting, and a revoked credential can never authenticate again.

import { NextResponse } from 'next/server';
import { backendFetch, sessionBearer } from '@/lib/passkey-backend';

export async function DELETE(
  _request: Request,
  { params }: { params: Promise<{ credentialId: string }> }
) {
  const bearer = await sessionBearer();
  if (!bearer) {
    return NextResponse.json({ error: 'auth-required' }, { status: 401 });
  }
  const { credentialId } = await params;
  // credentialId is base64url; encode so '/'+'=' survive the path segment.
  const res = await backendFetch(
    `/v1/auth/passkey/${encodeURIComponent(credentialId)}`,
    { method: 'DELETE', bearer }
  );
  if (res.status === 204) {
    return new NextResponse(null, { status: 204 });
  }
  const text = await res.text();
  return new NextResponse(text, {
    status: res.status,
    headers: { 'Content-Type': 'application/json' },
  });
}
