import test from 'node:test';
import assert from 'node:assert/strict';
import os from 'node:os';
import path from 'node:path';
import { mkdtemp, readFile, readdir, rm } from 'node:fs/promises';
import { generateKeyPairSync, sign } from 'node:crypto';
import { ChatGPTAuth } from './auth.mjs';

const { privateKey, publicKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
const jwk = { ...publicKey.export({ format: 'jwk' }), kid: 'unit-test-key', alg: 'RS256', use: 'sig' };
function jwt(claims) {
  const data = [{ alg: 'RS256', kid: jwk.kid }, claims].map(x => Buffer.from(JSON.stringify(x)).toString('base64url')).join('.');
  return `${data}.${sign('RSA-SHA256', Buffer.from(data), privateKey).toString('base64url')}`;
}
const discovery = { issuer: 'https://auth.openai.com', authorization_endpoint: 'https://auth.openai.com/authorize',
  token_endpoint: 'https://auth.openai.com/token', jwks_uri: 'https://auth.openai.com/jwks',
  revocation_endpoint: 'https://auth.openai.com/revoke', id_token_signing_alg_values_supported: ['RS256'] };
async function fixture(t) {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'leaf-auth-test-')); t.after(() => rm(directory, { recursive: true, force: true }));
  let nonce, subject = 'unit-test-subject'; const requests = [];
  const auth = new ChatGPTAuth({ dataDir: directory, fetchImpl: async (url, options) => {
    requests.push({ url, options });
    if (url.endsWith('openid-configuration')) return Response.json(discovery);
    if (url.endsWith('/jwks')) return Response.json({ keys: [jwk] });
    if (url.endsWith('/token')) {
      const now = Math.floor(Date.now() / 1000);
      return Response.json({ access_token: 'SYNTHETIC_ACCESS_SECRET', refresh_token: 'SYNTHETIC_REFRESH_SECRET', expires_in: 3600,
        scope: 'openid email chatgpt.tokens.use.direct', id_token: jwt({ iss: discovery.issuer, aud: 'test-issued-client', nonce,
          sub: subject, iat: now, exp: now + 3600, email: 'test@example.invalid', name: 'Unit Test' }) });
    }
    if (url.endsWith('/models')) return Response.json({ models: [{ visibility: 'list', slug: 'test-model', supported_reasoning_levels: [{ effort: 'high' }], input_modalities: ['text'] }] });
    if (url.endsWith('/revoke')) return new Response(null, { status: 200 });
    throw new Error('Unexpected network request in test');
  } }); await auth.init();
  return { directory, auth, requests, setSubject: s => { subject = s; }, begin: async () => {
    const url = new URL((await auth.begin('http://127.0.0.1:12345')).url); nonce = url.searchParams.get('nonce'); return url;
  } };
}

test('OAuth completes with signature/nonce checks; credentials remain in memory while public client registration persists', async t => {
  const { directory, auth, requests, begin } = await fixture(t);
  const url = await begin(); assert.equal(url.searchParams.get('client_id'), 'dynamic_agent_client');
  assert.equal(url.searchParams.get('code_challenge_method'), 'S256');
  await auth.callback(new URL(`http://127.0.0.1:12345/auth/callback?state=${url.searchParams.get('state')}&code=SYNTHETIC_CODE&client_id=test-issued-client`));
  assert.equal(auth.status().authenticated, true); assert.equal(auth.status().planEnabled, true);
  assert.equal(auth.status().account.label, 'Unit Test');
  assert.deepEqual((await auth.models()).models[0].efforts, ['auto', 'high']);
  assert.throws(() => auth.selection('test-model', 'low'), /不支持所选/);
  assert.throws(() => auth.selection('test-model', 'high', true), /不支持图片/);
  const registration = JSON.parse(await readFile(path.join(directory, 'registration.json'), 'utf8'));
  assert.equal(registration.clientId, 'test-issued-client'); assert.equal(registration.subject, 'unit-test-subject');
  assert.equal((await readdir(directory)).length, 1);
  const disk = JSON.stringify(registration); assert.equal(disk.includes('SYNTHETIC_'), false);
  assert.equal(JSON.stringify(auth.status()).includes('SYNTHETIC_'), false);
  assert.equal(auth.safeError(new Error('SYNTHETIC_ACCESS_SECRET')), '[已隐藏凭据]');
  await auth.logout(); assert.equal(auth.status().authenticated, false);
  assert.ok(requests.some(r => r.url === discovery.revocation_endpoint));
  const returning = await begin(); assert.equal(returning.searchParams.get('client_id'), 'test-issued-client');
});

test('wrong state never consumes pending authorization; wrong returning subject does not replace account', async t => {
  const { auth, begin, setSubject } = await fixture(t);
  let url = await begin();
  await assert.rejects(auth.callback(new URL('http://127.0.0.1:12345/auth/callback?state=wrong&code=fake')), /回调已失效/);
  assert.ok(auth.pending);
  await auth.callback(new URL(`http://127.0.0.1:12345/auth/callback?state=${url.searchParams.get('state')}&code=SYNTHETIC_CODE&client_id=test-issued-client`));
  await auth.logout(); setSubject('a-different-account'); url = await begin();
  await assert.rejects(auth.callback(new URL(`http://127.0.0.1:12345/auth/callback?state=${url.searchParams.get('state')}&code=SYNTHETIC_CODE`)), /identity mismatch/);
  assert.equal(auth.status().authenticated, false);
});
