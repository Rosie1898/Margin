import test from 'node:test';
import assert from 'node:assert/strict';
import os from 'node:os';
import path from 'node:path';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { ChatGPTAuth } from './auth.mjs';
import { atomicJson } from './conversations.mjs';

const registration = { hostId: 'urn:uuid:11111111-1111-1111-1111-111111111111', clientId: 'synthetic-client', subject: 'synthetic-subject' };
const credential = { version: 1, ...registration, refreshToken: 'SYNTHETIC_REFRESH_OLD', scopes: ['openid', 'chatgpt.tokens.use.direct'], email: 'test@example.invalid', label: 'Test' };
const discovery = { issuer: 'https://auth.openai.com', authorization_endpoint: 'https://auth.openai.com/authorize', token_endpoint: 'https://auth.openai.com/token',
  jwks_uri: 'https://auth.openai.com/jwks', revocation_endpoint: 'https://auth.openai.com/revoke', id_token_signing_alg_values_supported: ['RS256'] };
function deferred() { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; }
async function fixture(t, overrides = {}) {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'margin-keychain-auth-test-')); t.after(() => rm(directory, { recursive: true, force: true }));
  await atomicJson(path.join(directory, 'registration.json'), registration);
  const store = { persistent: true, value: structuredClone(credential), saves: 0, deletes: 0,
    async load() { return structuredClone(this.value); },
    async save(v) { this.saves++; if (this.failSave) throw new Error('Synthetic Keychain unavailable'); this.value = structuredClone(v); },
    async delete() { this.deletes++; this.value = null; } };
  const requests = [];
  const fetchImpl = async (url, options) => {
    requests.push({ url, options });
    if (url.endsWith('openid-configuration')) return Response.json(discovery);
    if (url.endsWith('/token')) {
      assert.equal(options.body.get('grant_type'), 'refresh_token'); assert.equal(options.body.has('scope'), false);
      assert.equal(options.body.get('resource'), 'https://api.openai.com/v1');
      if (overrides.token) return overrides.token(options);
      return Response.json({ access_token: 'SYNTHETIC_ACCESS_NEW', refresh_token: 'SYNTHETIC_REFRESH_NEW', expires_in: 3600 });
    }
    if (url.endsWith('/revoke')) return overrides.revoke ? overrides.revoke(options) : new Response(null, { status: 200 });
    if (url.endsWith('/models')) return overrides.models ? overrides.models(options) : Response.json({ models: [{ slug: 'm', visibility: 'list' }] });
    throw new Error('Unexpected synthetic URL');
  };
  const makeAuth = async () => { const auth = new ChatGPTAuth({ dataDir: directory, credentialStore: store, fetchImpl }); await auth.init(); return auth; };
  return { directory, store, requests, makeAuth, auth: await makeAuth() };
}

test('restart restores only protected refresh credential, rotates before use, and serializes refresh', async t => {
  const { auth, store, requests, directory, makeAuth } = await fixture(t);
  await auth.restore();
  assert.equal(auth.status().authenticated, true); assert.equal(store.value.refreshToken, 'SYNTHETIC_REFRESH_NEW');
  assert.equal('accessToken' in store.value, false); assert.equal('idToken' in store.value, false);
  assert.equal((await readFile(path.join(directory, 'registration.json'), 'utf8')).includes('SYNTHETIC_'), false);
  const restored = await makeAuth(); await restored.restore();
  const refreshRequests = requests.filter(r => r.url.endsWith('/token'));
  assert.equal(refreshRequests[1].options.body.get('refresh_token'), 'SYNTHETIC_REFRESH_NEW');
  restored.session.expiresAt = 0;
  const values = await Promise.all([restored.accessToken(), restored.accessToken(), restored.accessToken()]);
  assert.deepEqual(values, Array(3).fill('SYNTHETIC_ACCESS_NEW'));
  assert.equal(requests.filter(r => r.url.endsWith('/token')).length, 3);
  await restored.logout(); assert.equal(store.value, null);
  const afterLogout = await makeAuth(); await afterLogout.restore(); assert.equal(afterLogout.status().authenticated, false);
});

test('rotated credential survives failed secure save in memory and retries save without refreshing the old token', async t => {
  const { auth, store, requests } = await fixture(t); store.failSave = true;
  await auth.restore();
  assert.equal(auth.status().authenticated, false);
  assert.equal(store.value.refreshToken, 'SYNTHETIC_REFRESH_OLD');
  assert.equal(auth.pendingCredential.session.refreshToken, 'SYNTHETIC_REFRESH_NEW');
  store.failSave = false; await auth.restore();
  assert.equal(auth.status().authenticated, true); assert.equal(store.value.refreshToken, 'SYNTHETIC_REFRESH_NEW');
  assert.equal(requests.filter(r => r.url.endsWith('/token')).length, 1);
});

test('revoked refresh removes protected login while network failure retains it', async t => {
  const revoked = await fixture(t, { token: async () => Response.json({ error: 'invalid_grant' }, { status: 400 }) });
  await revoked.auth.restore(); assert.equal(revoked.store.value, null); assert.equal(revoked.auth.status().authenticated, false);
  assert.match(revoked.auth.auth.message, /已失效/);
  const offline = await fixture(t, { token: async () => { throw new Error('Synthetic offline'); } });
  await offline.auth.restore(); assert.equal(offline.store.value.refreshToken, 'SYNTHETIC_REFRESH_OLD');
  assert.equal(offline.auth.auth.status, 'restore_error');
});

test('logout during restore cannot resurrect credentials or late auth state', async t => {
  const gate = deferred(), entered = deferred();
  const { auth, store } = await fixture(t, { token: async () => { entered.resolve(); return gate.promise; } });
  const restoring = auth.restore(); await entered.promise;
  const logout = auth.logout();
  gate.resolve(Response.json({ access_token: 'SYNTHETIC_LATE_ACCESS', refresh_token: 'SYNTHETIC_LATE_REFRESH', expires_in: 3600 }));
  await restoring; await logout;
  assert.equal(store.value, null); assert.equal(auth.session, null); assert.equal(auth.auth.status, 'idle');
});

test('late HTTP 401 from an older account generation cannot clear the new login', async t => {
  const gate = deferred(), entered = deferred();
  const { auth, store } = await fixture(t, { models: async () => { entered.resolve(); return gate.promise; } });
  await auth.restore(); const oldRequest = auth.models(); await entered.promise;
  const oldGeneration = auth.generation;
  auth.generation++; auth.session = { ...auth.session, accessToken: 'SYNTHETIC_NEW_LOGIN_ACCESS' };
  store.value = { ...store.value, refreshToken: 'SYNTHETIC_NEW_LOGIN_REFRESH' };
  gate.resolve(Response.json({}, { status: 401 }));
  await assert.rejects(oldRequest, /状态已经改变/);
  await auth.invalidate('old request', oldGeneration);
  assert.equal(store.value.refreshToken, 'SYNTHETIC_NEW_LOGIN_REFRESH'); assert.equal(auth.session.accessToken, 'SYNTHETIC_NEW_LOGIN_ACCESS');
});

test('logout reports unconfirmed remote revocation while still clearing local protected state', async t => {
  const { auth, store, requests } = await fixture(t, { revoke: async () => new Response(null, { status: 503 }) });
  await auth.restore(); const result = await auth.logout();
  assert.equal(result.loggedOut, true); assert.equal(result.revocationConfirmed, false); assert.match(result.message, /未能确认远端撤销/);
  assert.equal(store.value, null); assert.equal(requests.filter(r => r.url.endsWith('/revoke')).length, 2);
});

test('late invalid_grant from an earlier refresh cannot delete a newer session', async t => {
  const gate = deferred(), entered = deferred(); let count = 0;
  const { auth, store } = await fixture(t, { token: async () => {
    count++; if (count === 1) return Response.json({ access_token: 'initial', refresh_token: 'initial-refresh', expires_in: 3600 });
    entered.resolve(); return gate.promise;
  } });
  await auth.restore(); auth.session.expiresAt = 0;
  const old = auth.accessToken(); await entered.promise;
  auth.generation++; auth.session = { ...auth.session, accessToken: 'new-session-access', expiresAt: Date.now() + 3600000 };
  store.value.refreshToken = 'new-session-refresh';
  gate.resolve(Response.json({ error: 'invalid_grant' }, { status: 400 }));
  await assert.rejects(old, /invalid_grant/);
  assert.equal(auth.session.accessToken, 'new-session-access'); assert.equal(store.value.refreshToken, 'new-session-refresh');
});

test('normal shutdown drains a rotating refresh before clearing memory and does not revoke the saved login', async t => {
  const gate = deferred(), entered = deferred();
  const { auth, store, requests } = await fixture(t, { token: async () => { entered.resolve(); return gate.promise; } });
  const restoring = auth.restore(); await entered.promise;
  let ended = false; const shuttingDown = auth.shutdown().then(() => { ended = true; });
  await new Promise(resolve => setImmediate(resolve)); assert.equal(ended, false);
  gate.resolve(Response.json({ access_token: 'shutdown-access', refresh_token: 'shutdown-refresh', expires_in: 3600 }));
  await restoring; await shuttingDown;
  assert.equal(store.value.refreshToken, 'shutdown-refresh'); assert.equal(auth.session, null);
  assert.equal(requests.filter(r => r.url.endsWith('/revoke')).length, 0);
  await assert.rejects(auth.accessToken(), /安全退出/);
});

test('normal shutdown is cancelled when latest rotated credential still cannot be saved', async t => {
  const { auth, store } = await fixture(t); store.failSave = true;
  await auth.restore(); await assert.rejects(auth.shutdown(), /Keychain unavailable/);
  assert.equal(auth.closing, false); assert.equal(auth.auth.status, 'shutdown_error');
  assert.equal(auth.pendingCredential.session.refreshToken, 'SYNTHETIC_REFRESH_NEW');
  store.failSave = false; await auth.shutdown(); assert.equal(store.value.refreshToken, 'SYNTHETIC_REFRESH_NEW');
});
