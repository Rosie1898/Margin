import test from 'node:test';
import assert from 'node:assert/strict';
import os from 'node:os';
import path from 'node:path';
import { mkdtemp, readFile, stat, rm } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { ConversationService, validateChat } from './conversations.mjs';
import { READER_INSTRUCTIONS, runResponse } from './core.mjs';

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
  t.after(() => rm(directory, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 }));
  const service = new ConversationService({ dataDir: directory, execute }); await service.init();
  return { directory, service };
}

test('personalization reaches every outbound response and updates across follow-ups and restart', async t => {
  const bodies = [];
  const execute = options => runResponse({ ...options, token: 'synthetic', fetchImpl: async (url, init) => {
    assert.equal(url, 'https://api.openai.com/v1/responses');
    bodies.push(JSON.parse(init.body));
    return new Response(`data: ${JSON.stringify({ type: 'response.completed', response: {
      id: `resp_${bodies.length}`, status: 'completed', model: 'model-a', output: result().output,
    } })}\n\n`, { headers: { 'Content-Type': 'text/event-stream' } });
  } });
  const { directory, service } = await setup(t, execute);
  const first = request({ customInstructions: '先解释经济直觉。\nDefine every symbol. 🧭',
    reference: { scope: 'selection', pages: [], totalPages: 4 } });
  const submit = async (target, data) => assert.equal((await settle(target, await target.start(data))).status, 'completed');
  await submit(service, first);
  await submit(service, { ...first, requestId: randomUUID(), text: 'Explain the next step.' });
  const changed = 'Answer briefly in English.';
  await submit(service, { ...first, requestId: randomUUID(), customInstructions: changed, model: 'model-b' });
  await submit(service, request({ customInstructions: changed }));
  const restored = new ConversationService({ dataDir: directory, execute }); await restored.init();
  await submit(restored, { ...first, requestId: randomUUID(), customInstructions: changed });
  await submit(restored, { ...first, requestId: randomUUID(), customInstructions: '' });
  await submit(restored, { ...first, requestId: randomUUID(), customInstructions: ' \n\t ' });
  await submit(restored, request());
  for (const body of bodies.slice(0, 2)) assert.ok(body.instructions.endsWith(first.customInstructions));
  for (const body of bodies.slice(2, 5)) {
    assert.ok(body.instructions.endsWith(changed));
    assert.ok(!body.instructions.includes(first.customInstructions));
  }
  for (const body of bodies.slice(5)) assert.equal(body.instructions, READER_INSTRUCTIONS);
  for (const body of bodies) {
    assert.match(body.instructions, /untrusted document content/);
    assert.ok(!JSON.stringify(body.input).includes('Define every symbol'));
    assert.ok(!JSON.stringify(body.input).includes(changed));
  }
  assert.ok(!JSON.stringify(await restored.thread(first.threadId)).includes('Define every symbol'));
});

test('personalization validates length and participates in request identity', async t => {
  for (const value of [null, 42, {}, [], 'x'.repeat(16001), '🧭'.repeat(8001)]) {
    assert.throws(() => validateChat(request({ customInstructions: value })), /个性化指令/);
  }
  assert.equal(validateChat(request({ customInstructions: '🧭'.repeat(8000) })).customInstructions.length, 16000);
  assert.equal(validateChat(request()).customInstructions, '');
  const { service } = await setup(t, async () => result());
  const first = request({ customInstructions: 'Use Chinese.' });
  const job = await service.start(first); await settle(service, job);
  assert.equal(await service.start(first), job);
  await assert.rejects(service.start({ ...first, customInstructions: 'Use English.' }), /同一请求标识/);
  await assert.rejects(service.start({ ...first, customInstructions: '' }), /同一请求标识/);
});

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
  // Windows reports compatibility mode bits rather than its effective ACLs.
  // Encrypted Windows credential storage is exercised separately in services.test.mjs.
  if (process.platform !== 'win32') assert.equal((await stat(service.filename(a.threadId))).mode & 0o777, 0o600);
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

function reference(scope, pageNumbers = [], totalPages = 5) {
  return { scope, pages: pageNumbers.map(page => ({ page, text: `Complete reference text for page ${page}.` })), totalPages };
}
function suppliedContext(message) {
  return JSON.parse(message.content[0].text.match(/<document_context>\n([\s\S]+)\n<\/document_context>/)[1]);
}

test('selection-only questions send the anchor without leaking legacy page text', async t => {
  const inputs = [];
  const { service } = await setup(t, async options => { inputs.push(options.input); return result(); });
  const a = request({ reference: reference('selection') });
  await settle(service, await service.start(a));
  assert.deepEqual(suppliedContext(inputs[0][0]), {
    filename: a.context.filename, quote: a.context.quote, page: 3, reference: reference('selection')
  });
  assert.ok(!JSON.stringify(inputs[0]).includes(a.context.pageText));
  assert.equal(inputs[0][0].content[0].text.endsWith(a.text), true);
  const transcript = await service.thread(a.threadId);
  assert.deepEqual(transcript.messages[0].reference, { scope: 'selection', pages: [], totalPages: 5 });
  assert.equal(transcript.messages[1].reference, undefined);
});

test('reference ranges can change on every turn across restart while preserving anchors and full conversation history', async t => {
  const inputs = [];
  const execute = async options => { inputs.push(structuredClone(options.input)); return result(); };
  const { directory, service } = await setup(t, execute);
  const a = request({ reference: reference('page', [3]) });
  await settle(service, await service.start(a));
  const restored = new ConversationService({ dataDir: directory, execute }); await restored.init();
  const b = { ...a, requestId: randomUUID(), text: 'Compare with the surrounding pages.',
    context: { ...a.context, pageText: 'New OCR page text which should not be implicitly included.' },
    reference: reference('nearby', [2, 3, 4]) };
  await settle(restored, await restored.start(b));
  const c = { ...b, requestId: randomUUID(), text: 'Now only explain the selection.', reference: reference('selection') };
  await settle(restored, await restored.start(c));
  assert.deepEqual(inputs[1].slice(0, 3), [...inputs[0], ...result().output]);
  assert.deepEqual(inputs[2].slice(0, 6), [...inputs[1], ...result().output]);
  assert.deepEqual(suppliedContext(inputs[1].at(-1)).reference, b.reference);
  assert.deepEqual(suppliedContext(inputs[2].at(-1)).reference, c.reference);
  assert.match(inputs[2].at(-1).content[0].text, /本轮参考范围/);
  assert.ok(!JSON.stringify(inputs[2]).includes(b.context.pageText));
  assert.ok(!inputs[2].at(-1).content[0].text.includes('Complete reference text'));
  const transcript = await restored.thread(a.threadId);
  assert.deepEqual(transcript.messages.filter(m => m.role === 'user').map(m => m.reference), [
    { scope: 'page', pages: [3], totalPages: 5 },
    { scope: 'nearby', pages: [2, 3, 4], totalPages: 5 },
    { scope: 'selection', pages: [], totalPages: 5 }
  ]);
  assert.ok(!JSON.stringify(transcript).includes('Complete reference text'));
  const disk = JSON.parse(await readFile(restored.filename(a.threadId), 'utf8'));
  assert.deepEqual(disk.context, a.context);
  for (const changed of [{ filename: 'different.pdf' }, { quote: 'Different quote' }, { page: 4 }]) {
    await assert.rejects(restored.start({ ...c, requestId: randomUUID(), context: { ...c.context, ...changed } }), /划线位置或原文已改变/);
  }
});

test('legacy saved threads accept an explicit reference range and keep their original context', async t => {
  const inputs = [];
  const execute = async options => { inputs.push(options.input); return result(); };
  const { directory, service } = await setup(t, execute);
  const a = request(); await settle(service, await service.start(a));
  const restored = new ConversationService({ dataDir: directory, execute }); await restored.init();
  await settle(restored, await restored.start({ ...a, requestId: randomUUID(), reference: reference('custom', [1, 5]) }));
  assert.deepEqual(suppliedContext(inputs[1].at(-1)).reference, reference('custom', [1, 5]));
  assert.equal(suppliedContext(inputs[1].at(-1)).pageText, undefined);
  assert.equal(suppliedContext(inputs[1][0]).pageText, a.context.pageText);
  assert.equal((await restored.thread(a.threadId)).messages[0].reference, undefined);
});

test('request identity includes reference range and page contents', async t => {
  const { service } = await setup(t, async () => result());
  const a = request({ reference: reference('page', [3]) });
  const id = await service.start(a); await settle(service, id);
  assert.equal(await service.start(a), id);
  await assert.rejects(service.start({ ...a, reference: reference('selection') }), /不同内容/);
  await assert.rejects(service.start({ ...a, reference: { ...a.reference, pages: [{ page: 3, text: 'Changed page text' }] } }), /不同内容/);
});

test('reference schemas enforce complete, ordered ranges and explicit text limits', () => {
  const valid = [reference('selection'), reference('page', [3]), reference('nearby', [2, 3, 4]),
    reference('custom', [1, 5]), reference('document', [1, 2, 3, 4, 5])];
  for (const item of valid) assert.deepEqual(validateChat(request({ reference: item })).reference, item);
  const edge = request({ context: { filename: 'one.pdf', quote: 'one', page: 1, pageText: '' }, reference: reference('nearby', [1], 1) });
  assert.deepEqual(validateChat(edge).reference, edge.reference);
  const invalid = [null, [], {}, reference('unknown'), reference('selection', [3]), reference('page', []),
    reference('page', [2]), reference('page', [2, 3]), reference('nearby', [2, 3]), reference('custom', []),
    reference('custom', [3, 3]), reference('custom', [4, 2]), reference('custom', [0]), reference('custom', [6]),
    reference('document', [1, 2, 3, 4]), reference('selection', [], 2), reference('selection', [], 1.5),
    reference('selection', [], 100001), { ...reference('custom', [3]), pages: [{ page: 3, text: '   ' }] },
    { ...reference('custom', [3]), pages: [{ page: 3.5, text: 'text' }] },
    { ...reference('custom', [3]), pages: [{ page: 3, text: 'x'.repeat(100001) }] },
    { ...reference('custom', [1, 2]), pages: [{ page: 1, text: 'x'.repeat(50001) }, { page: 2, text: 'y'.repeat(50000) }] },
    reference('document', Array.from({ length: 201 }, (_, i) => i + 1), 201)];
  for (const item of invalid) assert.throws(() => validateChat(request({ reference: item })), { status: 400 });
  const exactLimit = { scope: 'custom', pages: [{ page: 3, text: 'x'.repeat(100000) }], totalPages: 5 };
  assert.equal(validateChat(request({ reference: exactLimit })).reference.pages[0].text.length, 100000);
  const maximumPages = reference('document', Array.from({ length: 200 }, (_, i) => i + 1), 200);
  assert.equal(validateChat(request({ reference: maximumPages })).reference.pages.length, 200);
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
