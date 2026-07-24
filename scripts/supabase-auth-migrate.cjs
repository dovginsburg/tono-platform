'use strict';

function adminHeaders(serviceRoleKey) {
  if (!serviceRoleKey) throw new Error('service role key is required');
  return {
    apikey: serviceRoleKey,
    Authorization: `Bearer ${serviceRoleKey}`,
    'Content-Type': 'application/json',
  };
}

function normalizeProjectUrl(projectUrl) {
  const url = new URL(projectUrl);
  if (url.protocol !== 'https:' || !/^[a-z0-9]{20}\.supabase\.co$/.test(url.hostname) || url.pathname !== '/') {
    throw new Error('project URL must be a canonical Supabase project URL');
  }
  return url.origin;
}

async function checkedJson(response, action) {
  if (!response.ok) {
    const detail = await response.text();
    throw new Error(`${action} failed (${response.status}): ${detail}`);
  }
  if (response.status === 204) return {};
  return response.json();
}

async function exportUsers({ projectUrl, serviceRoleKey, fetchImpl = fetch, perPage = 1000 }) {
  const origin = normalizeProjectUrl(projectUrl);
  const users = [];
  for (let page = 1; ; page += 1) {
    const url = `${origin}/auth/v1/admin/users?page=${page}&per_page=${perPage}`;
    const payload = await checkedJson(await fetchImpl(url, { headers: adminHeaders(serviceRoleKey) }), 'auth export');
    const batch = Array.isArray(payload) ? payload : payload.users || [];
    for (const user of batch) {
      if (!user.email) {
        throw new Error(`source user ${user.id} has no email; manual provider re-link is required`);
      }
      users.push({
        source_user_id: user.id,
        email: user.email,
        provider: user.app_metadata?.provider || 'email',
      });
    }
    if (batch.length < perPage) break;
  }
  return users;
}

function planReauthentication({ sourceProjectRef, targetProjectRef, users }) {
  if (!sourceProjectRef || !targetProjectRef) throw new Error('source and target project refs are required');
  if (sourceProjectRef === targetProjectRef) throw new Error('source and target project refs must differ');
  return users.map(({ source_user_id, email, provider }) => ({
    source_user_id,
    email,
    provider,
    action: 'create_unconfirmed_then_reauthenticate',
  }));
}

async function importUsers({ targetProjectUrl, serviceRoleKey, plan, fetchImpl = fetch }) {
  const origin = normalizeProjectUrl(targetProjectUrl);
  const createdTargetUserIds = [];
  for (const user of plan) {
    const body = {
      email: user.email,
      email_confirm: false,
      app_metadata: {
        tono_migration_source_user_id: user.source_user_id,
        tono_reauthentication_required: true,
      },
    };
    const payload = await checkedJson(await fetchImpl(`${origin}/auth/v1/admin/users`, {
      method: 'POST',
      headers: adminHeaders(serviceRoleKey),
      body: JSON.stringify(body),
    }), `create target user for ${user.source_user_id}`);
    createdTargetUserIds.push(payload.id);
  }
  return { created_target_user_ids: createdTargetUserIds };
}

async function rollbackUsers({ targetProjectUrl, serviceRoleKey, createdTargetUserIds, fetchImpl = fetch }) {
  const origin = normalizeProjectUrl(targetProjectUrl);
  for (const id of createdTargetUserIds) {
    await checkedJson(await fetchImpl(`${origin}/auth/v1/admin/users/${encodeURIComponent(id)}`, {
      method: 'DELETE',
      headers: adminHeaders(serviceRoleKey),
    }), `rollback target user ${id}`);
  }
}

module.exports = {
  exportUsers,
  importUsers,
  normalizeProjectUrl,
  planReauthentication,
  rollbackUsers,
};
