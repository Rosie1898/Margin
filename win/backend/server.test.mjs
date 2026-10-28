import test from 'node:test';
import assert from 'node:assert/strict';
import os from 'node:os';
import path from 'node:path';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import http from 'node:http';
import { createReaderServer } from './server.mjs';

test('loopback API rejects cross-site reads, invalid Host/CSRF, and unauthenticated inference', async t => {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'leaf-http-test-'));
  let networkRequests = 0;
  const app = await createReaderServer({ dataDir: directory, fetchImpl: async () => { networkRequests++; throw new Error('Network forbidden in local test'); } });
  t.after(async () => { await app.close(); await rm(directory, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 }); });
  assert.deepEqual(JSON.parse(await readFile(path.join(directory, 'runtime.json'), 'utf8')), { baseUrl: app.baseUrl });
  const get = (p, headers = {}) => fetch(app.baseUrl + p, { headers });
  const initial = await (await get('/api/status')).json();
  assert.equal(initial.authenticated, false); assert.equal(initial.account, null); assert.deepEqual(initial.models, []);
  assert.equal((await get('/api/status', { Origin: 'https://hostile.example' })).status, 403);
  assert.equal((await get('/api/status', { 'Sec-Fetch-Site': 'cross-site' })).status, 403);
  // Fetch can replace a supplied Host header, so use the HTTP client to test the
  // bytes the server actually receives rather than the Fetch header policy.
  const badHostStatus = await new Promise((resolve, reject) => {
    const req = http.request(app.baseUrl + '/api/status', { headers: { Host: 'hostile.example' } }, res => {
      res.resume(); res.on('end', () => resolve(res.statusCode));
    }); req.on('error', reject); req.end();
  });
  assert.equal(badHostStatus, 403);
  assert.equal((await fetch(app.baseUrl + '/api/chat/start', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' })).status, 403);
  assert.equal((await fetch(app.baseUrl + '/api/chat/start', { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': initial.csrfToken }, body: '{}' })).status, 401);
  assert.equal((await get('/auth/callback?state=stray&code=not-a-real-code')).status, 400);
  assert.deepEqual(await (await get(`/api/chat/thread?id=${randomUUID()}`)).json(), { messages: [], busy: false, jobId: null });
  assert.equal((await get('/api/chat/thread?id=../../escape')).status, 400);
  assert.equal(networkRequests, 0);
  const registration = JSON.parse(await readFile(path.join(directory, 'registration.json'), 'utf8'));
  assert.deepEqual(Object.keys(registration), ['hostId']);
});
