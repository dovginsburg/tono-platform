const test = require('node:test');
const assert = require('node:assert/strict');

const {
  exportUsers,
  planReauthentication,
  importUsers,
  rollbackUsers,
} = require('../../../scripts/supabase-auth-migrate.cjs');

function response(status, body) {
  return { ok: status >= 200 && status < 300, status, json: async () => body, text: async () => JSON.stringify(body) };
}

test('exportUsers paginates and never exports password or token fields', async () => {
  const pages = [
    { users: [{ id: 'u1', email: 'one@example.com', app_metadata: { provider: 'email' }, encrypted_password: 'secret' }] },
    { users: [] },
  ];
  const calls = [];
  const users = await exportUsers({
    projectUrl: 'https://aaaaaaaaaaaaaaaaaaaa.supabase.co',
    serviceRoleKey: 'source-key',
    perPage: 1,
    fetchImpl: async (url) => { calls.push(url); return response(200, pages.shift()); },
  });

  assert.equal(calls.length, 2);
  assert.deepEqual(users, [{ source_user_id: 'u1', email: 'one@example.com', provider: 'email' }]);
  assert.equal(JSON.stringify(users).includes('secret'), false);
});

test('planReauthentication rejects a shared source and target project', () => {
  assert.throws(() => planReauthentication({
    sourceProjectRef: 'sharedprojectref0001',
    targetProjectRef: 'sharedprojectref0001',
    users: [],
  }), /must differ/);
});

test('importUsers creates unconfirmed target users and records rollback ids', async () => {
  const bodies = [];
  const result = await importUsers({
    targetProjectUrl: 'https://bbbbbbbbbbbbbbbbbbbb.supabase.co',
    serviceRoleKey: 'target-key',
    plan: [{ source_user_id: 'u1', email: 'one@example.com', provider: 'email' }],
    fetchImpl: async (_url, options) => {
      bodies.push(JSON.parse(options.body));
      return response(201, { id: 'target-u1' });
    },
  });

  assert.deepEqual(bodies, [{ email: 'one@example.com', email_confirm: false, app_metadata: { tono_migration_source_user_id: 'u1', tono_reauthentication_required: true } }]);
  assert.deepEqual(result.created_target_user_ids, ['target-u1']);
});

test('rollbackUsers deletes only ids recorded by the import manifest', async () => {
  const urls = [];
  await rollbackUsers({
    targetProjectUrl: 'https://bbbbbbbbbbbbbbbbbbbb.supabase.co',
    serviceRoleKey: 'target-key',
    createdTargetUserIds: ['target-u1', 'target-u2'],
    fetchImpl: async (url) => { urls.push(url); return response(204, {}); },
  });
  assert.deepEqual(urls.map((url) => url.split('/').pop()), ['target-u1', 'target-u2']);
});
