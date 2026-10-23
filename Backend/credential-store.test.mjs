import test from 'node:test';
import assert from 'node:assert/strict';
import { PassThrough } from 'node:stream';
import { ParentKeychainStore } from './credential-store.mjs';

test('credential bridge uses correlated private-pipe messages and never falls back to disk', async () => {
  const input = new PassThrough(), output = new PassThrough(); const sent = [];
  output.setEncoding('utf8'); output.on('data', line => sent.push(JSON.parse(line)));
  const store = new ParentKeychainStore({ input, output, timeoutMs: 1000 });
  const loading = store.load();
  assert.equal(sent[0].action, 'load');
  input.write(JSON.stringify({ channel: 'unrelated', id: sent[0].id, ok: true, credential: { bad: true } }) + '\n');
  const response = JSON.stringify({ channel: 'leaf.keychain.v1', id: sent[0].id, ok: true, credential: { refreshToken: 'synthetic' } }) + '\n';
  input.write(response.slice(0, 13)); input.write(response.slice(13));
  assert.deepEqual(await loading, { refreshToken: 'synthetic' });
  const saving = store.save({ refreshToken: 'synthetic-rotated' });
  input.write(JSON.stringify({ channel: 'leaf.keychain.v1', id: sent[1].id, ok: false, error: 'Synthetic lock' }) + '\n');
  await assert.rejects(saving, /Synthetic lock/);
  const deleting = store.delete(); input.end(); await assert.rejects(deleting, /应用已关闭/);
  output.end();
});
