import test from 'node:test';
import assert from 'node:assert/strict';
import os from 'node:os';
import path from 'node:path';
import { mkdtemp, readFile, stat, rm } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { ConversationService, validateChat } from './conversations.mjs';

const result = (text = 'A useful answer') => ({ text, output: [
  { id: 'rs_1', type: 'reasoning', encrypted_content: 'opaque-complete-history', summary: [] },
  { id: 'msg_1', type: 'message', role: 'assistant', phase: 'final_answer', status: 'completed', content: [{ type: 'output_text', text }] }
], evidence: { actualModel: 'model-a', actualEffort: 'high', terminalEvent: 'response.completed' } });
const request = extra => ({ threadId: randomUUID(), requestId: randomUUID(), documentId: 'a'.repeat(64),
  context: { filename: 'paper.pdf', quote: 'A private selected passage', page: 3, pageText: 'Only this page is provided.' },
  text: 'Please explain.', model: 'model-a', effort: 'high', ...extra });
async function settle(service, id) {
  for (let i = 0; i < 1000; i++) { if (service.status(id).status !== 'running') return service.status(id); await new Promise(resolve => setTimeout(resolve, 2)); }
  throw new Error('Test job never completed');
}
async function setup(t, execute) {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'leaf-chat-test-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const service = new ConversationService({ dataDir: directory, execute }); await service.init();
  return { directory, service };
}

test('threads isolate document context, preserve complete output across restart, and expose only transcript', async t => {
  const inputs = [];
  const execute = async options => { inputs.push(options.input); options.onDelta('A partial answer'); return result(); };
  const { directory, service } = await setup(t, execute);
  const a = request(), b = request({ context: { filename: 'second.pdf', quote: 'A different passage', page: 1, pageText: 'Second page context' }, documentId: 'b'.repeat(64) });
  assert.equal((await settle(service, await service.start(a))).status, 'completed');
  assert.equal((await settle(service, await service.start(b))).status, 'completed');
  assert.ok(!JSON.stringify(inputs[1]).includes('A private selected passage'));
  const disk = JSON.parse(await readFile(service.filename(a.threadId), 'utf8'));
  assert.equal(disk.input[1].encrypted_content, 'opaque-complete-history'); assert.equal(disk.input[2].phase, 'final_answer');
  assert.equal((await stat(service.filename(a.threadId))).mode & 0o777, 0o600);
  assert.equal(JSON.stringify(await service.thread(a.threadId)).includes('opaque-complete-history'), false);
  assert.equal(JSON.stringify(await service.thread(a.threadId)).includes('Only this page'), false);
  const restored = new ConversationService({ dataDir: directory, execute }); await restored.init();
  assert.equal((await restored.thread(a.threadId)).messages.length, 2);
  const followup = { ...a, requestId: randomUUID(), text: 'How does this follow?' };
  assert.equal((await settle(restored, await restored.start(followup))).status, 'completed');
  assert.equal(inputs[2][1].encrypted_content, 'opaque-complete-history');
  assert.equal(inputs[2].at(-1).content[0].text, followup.text);
  await assert.rejects(restored.start({ ...a, requestId: randomUUID(), documentId: 'c'.repeat(64) }), /不属于当前 PDF/);
  await assert.rejects(restored.start({ ...a, requestId: randomUUID(), context: { ...a.context, quote: 'changed anchor' } }), /划线位置或原文已改变/);
});

test('same request is idempotent, concurrent same-thread submission is rejected, cancel does not pollute history', async t => {
  let calls = 0;
  const { service } = await setup(t, options => new Promise((resolve, reject) => {
    calls++; options.onDelta('Incomplete text');
    options.signal.addEventListener('abort', () => reject(options.signal.reason), { once: true });
  }));
  const a = request(), id = await service.start(a);
  assert.equal(await service.start(a), id); assert.equal(calls, 1);
  await assert.rejects(service.start({ ...a, text: 'different with same ID' }), /不同内容/);
  await assert.rejects(service.start({ ...a, requestId: randomUUID() }), /正在回复/);
  service.cancel(id); const ended = await settle(service, id);
  assert.equal(ended.status, 'failed'); assert.match(ended.error, /已取消/);
  const transcript = await service.thread(a.threadId);
  assert.equal(transcript.messages.length, 1); assert.equal(transcript.messages[0].status, 'failed'); assert.equal(transcript.busy, false);
  assert.deepEqual(JSON.parse(await readFile(service.filename(a.threadId), 'utf8')).input, []);
  service.execute = async () => result('Successful retry');
  await settle(service, await service.start({ ...a, requestId: randomUUID() }));
  const after = JSON.parse(await readFile(service.filename(a.threadId), 'utf8'));
  assert.equal(after.input.filter(x => x.role === 'user').length, 1);
  assert.equal(after.messages.length, 3);
});

test('API failure keeps durable failed user message and restart marks interrupted turns', async t => {
  const { directory, service } = await setup(t, async () => { throw new Error('Synthetic network failure'); });
  const a = request();
  assert.equal((await settle(service, await service.start(a))).status, 'failed');
  assert.match((await service.thread(a.threadId)).messages[0].error, /Synthetic network failure/);
  const persisted = JSON.parse(await readFile(service.filename(a.threadId), 'utf8'));
  persisted.messages[0].status = 'pending';
  const { atomicJson } = await import('./conversations.mjs'); await atomicJson(service.filename(a.threadId), persisted);
  const restored = new ConversationService({ dataDir: directory, execute: async () => result() }); await restored.init();
  assert.match((await restored.thread(a.threadId)).messages[0].error, /上次运行已中断/);
  await assert.rejects(restored.start(a), /已经提交过/);
});

test('context and image bounds reject invalid data before persistence or model use', () => {
  assert.throws(() => validateChat(request({ threadId: '../../escape' })), /标识无效/);
  assert.throws(() => validateChat(request({ context: { filename: 'x.pdf', quote: 'x', page: 0, pageText: '' } })), /页码无效/);
  assert.throws(() => validateChat(request({ context: { filename: 'x.pdf', quote: 'x'.repeat(16001), page: 1, pageText: '' } })), /过长/);
  assert.throws(() => validateChat(request({ imageDataUrl: 'https://example.com/image.png' })), /图片必须/);
  assert.throws(() => validateChat(request({ imageDataUrl: 'data:image/png;base64,SGVsbG8=' })), /内容与格式/);
});

test('concurrent model work is bounded and cancellation releases capacity', async t => {
  const { service } = await setup(t, options => new Promise((resolve, reject) => {
    options.signal.addEventListener('abort', () => reject(options.signal.reason), { once: true });
  }));
  const ids = [];
  for (let i = 0; i < 4; i++) ids.push(await service.start(request()));
  await assert.rejects(service.start(request()), /同时回复的讨论较多/);
  for (const id of ids) service.cancel(id);
  for (const id of ids) await settle(service, id);
  assert.equal(service.running.size, 0);
  service.execute = async () => result();
  assert.equal((await settle(service, await service.start(request()))).status, 'completed');
});

test('bounded caches evict memory without deleting saved threads', async t => {
  const { service } = await setup(t, async () => result());
  const first = request(); await settle(service, await service.start(first));
  for (let i = 0; i < 17; i++) await settle(service, await service.start(request()));
  assert.ok(service.threads.size <= 16); assert.equal(service.threads.has(first.threadId), false);
  assert.equal((await service.thread(first.threadId)).messages.length, 2);
  assert.ok(service.threads.size <= 16);
  for (let i = 0; i < 51; i++) service.jobs.set(`synthetic-cache-${i}`, { id: `synthetic-cache-${i}`, status: 'completed', text: 'x'.repeat(200000) });
  service.pruneJobs();
  const retained = [...service.jobs.values()];
  assert.ok(retained.length <= 50); assert.ok(retained.reduce((n, j) => n + Buffer.byteLength(j.text), 0) <= 8 * 1024 * 1024);
});
