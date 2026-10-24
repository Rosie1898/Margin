import test from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, sign, createHash } from 'node:crypto';
import { makePkce, verifyIdentity, normalizeModels, responseBody, userMessage, runResponse, sseEvents, numericMarker, markerLine } from './core.mjs';

test('PKCE uses S256 and unpredictable independent values', () => {
  const a = makePkce(), b = makePkce();
  assert.equal(a.challenge, createHash('sha256').update(a.verifier).digest('base64url'));
  assert.notEqual(a.state, b.state); assert.notEqual(a.nonce, a.state);
});
test('answer evidence requires complete unambiguous marker lines', () => {
  assert.equal(numericMarker('explanation\nIMAGE_RESULT=79\n', 'IMAGE_RESULT'), 79);
  assert.notEqual(numericMarker('IMAGE_RESULT=79.5', 'IMAGE_RESULT'), 79);
  assert.ok(Number.isNaN(numericMarker('IMAGE_RESULT=79e2', 'IMAGE_RESULT')));
  assert.ok(Number.isNaN(numericMarker('IMAGE_RESULT=79\nIMAGE_RESULT=12', 'IMAGE_RESULT')));
  assert.equal(markerLine('CASE=MAPLE-ABC\n', 'CASE'), 'MAPLE-ABC');
});

const { privateKey, publicKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
const jwk = { ...publicKey.export({ format: 'jwk' }), kid: 'test-key', alg: 'RS256', use: 'sig' };
const claims = { iss: 'https://auth.openai.com', sub: 'test-subject', aud: 'test-client', nonce: 'test-nonce', exp: 2000, iat: 1000 };
const expected = { issuer: claims.iss, audience: claims.aud, nonce: claims.nonce, now: 1500 };
function jwt(c = claims, h = { alg: 'RS256', kid: 'test-key' }) {
  const data = [h, c].map(x => Buffer.from(JSON.stringify(x)).toString('base64url')).join('.');
  return data + '.' + sign('RSA-SHA256', Buffer.from(data), privateKey).toString('base64url');
}
test('ID token verifies a real RSA signature and all identity claims', () => {
  assert.equal(verifyIdentity(jwt(), [jwk], expected).sub, claims.sub);
  for (const change of [{ aud: 'wrong' }, { iss: 'https://other.example' }, { nonce: 'wrong' }, { exp: 1400 }, { iat: 2000 }, { sub: '' }]) {
    assert.throws(() => verifyIdentity(jwt({ ...claims, ...change }), [jwk], expected));
  }
  assert.throws(() => verifyIdentity(jwt(), [jwk], { ...expected, subject: 'other-account' }));
  assert.throws(() => verifyIdentity(jwt(claims, { alg: 'none', kid: 'test-key' }), [jwk], expected));
  const parts = jwt().split('.'); parts[1] = Buffer.from(JSON.stringify({ ...claims, sub: 'tampered' })).toString('base64url');
  assert.throws(() => verifyIdentity(parts.join('.'), [jwk], expected), /signature/);
});
test('catalog preserves display order and does not masquerade API-key catalogs as plan access', () => {
  const models = normalizeModels({ models: [
    { slug: 'hidden', visibility: 'hide' },
    { slug: 'a', display_name: 'A', visibility: 'list', supported_reasoning_levels: [{ effort: 'low' }, { effort: 'high' }] },
    { slug: 'b', visibility: 'list' }
  ] });
  assert.deepEqual(models.map(x => x.id), ['a', 'b']);
  assert.equal(models[0].effortsSource, 'catalog'); assert.equal(models[1].effortsSource, 'unspecified');
  assert.deepEqual(models[1].efforts, ['auto']);
  assert.throws(() => normalizeModels({ data: [{ id: 'a' }] }));
});
test('stateless request includes complete opaque history and explicit effort without forbidden fields', () => {
  const reasoning = { id: 'rs_test', type: 'reasoning', encrypted_content: 'opaque', summary: [] };
  const message = { id: 'msg_test', type: 'message', role: 'assistant', phase: 'final_answer', status: 'completed', content: [{ type: 'output_text', text: 'old' }] };
  const input = [userMessage('first'), reasoning, message, userMessage('follow up')];
  const body = responseBody({ model: 'test-model', effort: 'high', input });
  assert.equal(body.store, false); assert.equal(body.stream, true); assert.equal(body.input[1], reasoning); assert.equal(body.input[2].phase, 'final_answer');
  assert.deepEqual(body.reasoning, { effort: 'high' });
  assert.deepEqual(body.include, ['reasoning.encrypted_content']);
  for (const field of ['previous_response_id', 'conversation', 'max_output_tokens', 'temperature']) assert.equal(field in body, false);
  assert.equal('reasoning' in responseBody({ model: 'test-model', effort: 'auto', input }), false);
  assert.equal(userMessage('read image', 'data:image/png;base64,test').content[1].type, 'input_image');
});

test('completed stream items survive an empty terminal output and preserve opaque history', async () => {
  const reasoning = { id: 'rs_1', type: 'reasoning', encrypted_content: 'opaque-final', summary: [] };
  const preamble = { id: 'msg_1', type: 'message', role: 'assistant', phase: 'commentary', status: 'completed', content: [{ type: 'output_text', text: 'Checking.' }] };
  const final = { id: 'msg_2', type: 'message', role: 'assistant', phase: 'final_answer', status: 'completed', content: [{ type: 'output_text', text: 'ANSWER=79' }] };
  const output = [reasoning, preamble, final];
  const done = output.map((item, output_index) => ({ type: 'response.output_item.done', output_index, item }));
  const run = events => runResponse({ token: 'fake-test', model: 'm', effort: 'high', input: [userMessage('test')], fetchImpl: async () => new Response(stream(events)) });
  const prefix = [{ type: 'response.created', response: { id: 'resp_1', model: 'm', reasoning: { effort: 'high' } } },
    { type: 'response.output_item.added', output_index: 0, item: { ...reasoning, encrypted_content: 'unfinished' } }, ...done];
  const result = await run([...prefix, { type: 'response.completed', response: { id: 'resp_1', status: 'completed', output: [] } }]);
  assert.deepEqual(result.output, output);
  assert.equal(result.text, 'Checking.\nANSWER=79');
  assert.equal(result.evidence.actualModel, 'm'); assert.equal(result.evidence.actualEffort, 'high');
  assert.equal(result.evidence.terminalOutputCount, 0);
  assert.ok(!JSON.stringify(result.evidence).includes('opaque-final'));
  const repeated = await run([...prefix, { type: 'response.completed', response: { id: 'resp_1', status: 'completed', output } }]);
  assert.deepEqual(repeated.output, output);
  const incompleteOpaque = await run([
    { type: 'response.output_item.added', output_index: 0, item: { ...reasoning, encrypted_content: 'unfinished', status: 'in_progress' } },
    { type: 'response.output_item.done', output_index: 0, item: { id: reasoning.id, type: 'reasoning', summary: [] } },
    { type: 'response.output_item.done', output_index: 1, item: final },
    { type: 'response.completed', response: { status: 'completed', output: [reasoning, final] } }
  ]);
  assert.equal(incompleteOpaque.output[0].encrypted_content, 'opaque-final');
  assert.equal(incompleteOpaque.output[0].status, undefined);
  await assert.rejects(run(prefix), /without response.completed/);
  await assert.rejects(run([...prefix, { type: 'response.failed', response: { error: { code: 'limit' } } }]), /response.failed/);
});

test('completed event cannot hide missing, incomplete, or conflicting output items', async () => {
  const item = { id: 'msg_1', type: 'message', role: 'assistant', status: 'completed', content: [{ type: 'output_text', text: '79' }] };
  const run = events => runResponse({ token: 'fake-test', model: 'm', effort: 'low', input: [userMessage('test')], fetchImpl: async () => new Response(stream(events)) });
  const completed = { type: 'response.completed', response: { status: 'completed', output: [] } };
  await assert.rejects(run([{ type: 'response.output_item.added', output_index: 0, item }, completed]), /unfinished or missing/);
  await assert.rejects(run([{ type: 'response.output_item.done', output_index: 1, item }, completed]), /unfinished or missing/);
  await assert.rejects(run([{ type: 'response.output_item.done', output_index: 0, item: { ...item, status: 'in_progress' } }, completed]), /unfinished output item/);
  await assert.rejects(run([{ type: 'response.output_item.done', output_index: 0, item }, { type: 'response.completed', response: { status: 'completed', output: [{ ...item, content: [{ type: 'output_text', text: 'wrong' }] }] } }]), /conflicts/);
  await assert.rejects(run([{ type: 'response.output_item.done', output_index: 0, item }, { type: 'response.completed', response: { status: 'completed', output: [{ ...item, status: 'incomplete' }] } }]), /status conflicts/);
  await assert.rejects(run([{ type: 'response.output_text.delta', delta: '79' }, completed]), /no assistant text/);
});

function stream(events, eof = '') {
  const source = events.map(x => `event: ${x.type}\r\ndata: ${JSON.stringify(x)}\r\n\r\n`).join('') + eof;
  const bytes = Buffer.from(source);
  return new ReadableStream({ start(c) { for (let i = 0; i < bytes.length; i += 7) c.enqueue(bytes.subarray(i, i + 7)); c.close(); } });
}
test('SSE handles chunk boundaries, CRLF and split UTF-8', async () => {
  const events = []; for await (const e of sseEvents(stream([{ type: 'response.output_text.delta', delta: '中文公式' }]))) events.push(e);
  assert.equal(events[0].delta, '中文公式');
});
test('200 plus deltas is NOT successful inference; failed and incomplete are distinguished', async () => {
  const delta = { type: 'response.output_text.delta', delta: 'partial' };
  const run = events => runResponse({ token: 'fake-for-unit-test', model: 'm', effort: 'low', input: [userMessage('test')], fetchImpl: async () => new Response(stream(events), { headers: { 'x-request-id': 'req_test' } }) });
  await assert.rejects(run([delta]), /without response.completed/);
  await assert.rejects(run([delta, { type: 'response.failed', response: { error: { code: 'usage_limit', message: 'limit' } } }]), /response.failed/);
  await assert.rejects(run([{ type: 'response.incomplete', response: { incomplete_details: { reason: 'test' } } }]), /response.incomplete/);
  const done = { type: 'response.completed', response: { status: 'completed', id: 'resp_test', model: 'resolved-m', reasoning: { effort: 'low' },
    output: [{ type: 'message', role: 'assistant', content: [{ type: 'output_text', text: 'complete' }] }] } };
  const result = await run([delta, done]);
  assert.equal(result.evidence.terminalEvent, 'response.completed'); assert.equal(result.evidence.actualModel, 'resolved-m');
  assert.equal(result.evidence.actualEffort, 'low'); assert.equal(result.text, 'complete');
});

test('reader requests accept cancellation and distinguish document data from user instructions', async () => {
  const controller = new AbortController();
  const promise = runResponse({ token: 'synthetic', model: 'm', effort: 'auto', input: [userMessage('question')], signal: controller.signal,
    fetchImpl: async (_url, options) => new Promise((resolve, reject) => {
      const body = JSON.parse(options.body);
      assert.match(body.instructions, /untrusted document content/);
      assert.match(body.instructions, /complete document/);
      assert.match(body.instructions, /latest supplied range/);
      assert.match(body.instructions, /do not claim to have read unsupplied pages/);
      assert.ok(body.instructions.includes(String.raw`\[ ... \]`));
      assert.ok(body.instructions.includes(String.raw`\( ... \)`));
      options.signal.addEventListener('abort', () => reject(options.signal.reason), { once: true });
    }) });
  controller.abort(new Error('test user cancelled'));
  await assert.rejects(promise, /test user cancelled/);
});
