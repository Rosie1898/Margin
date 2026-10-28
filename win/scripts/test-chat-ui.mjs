/** Real Electron UI integration with an explicitly mocked Chat IPC service.
 * No production mock path, account credentials, sign-in, or model requests.
 */
import { _electron as electron } from 'playwright';
import assert from 'node:assert/strict';
import { mkdir, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { LibraryStore } from '../src/store.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const require = createRequire(import.meta.url), output = path.join(root, 'test-results');
await mkdir(output, { recursive: true });
const dataDir = await mkdtemp(path.join(output, 'chat-ui-'));
const fixtures = path.join(dataDir, 'fixtures'); await mkdir(fixtures);
const source = path.join(output, 'fixtures', 'Margin verification.pdf');
const sourceBytes = await readFile(source), originalHash = createHash('sha256').update(sourceBytes).digest('hex');
const fixtureA = path.join(fixtures, 'A - discussion.pdf'), fixtureB = path.join(fixtures, 'B - another document.pdf');
await writeFile(fixtureA, sourceBytes); await writeFile(fixtureB, Buffer.concat([sourceBytes, Buffer.from('\n% Independent test document B\n')]));
const store = new LibraryStore(dataDir); await store.init(); await store.setFolder(fixtures);
await store.saveSettings({ language: 'en', selectedModel: 'removed-model', selectedEffort: 'xhigh', ocrLanguage: 'en-US' }); await store.close();
const checks = [], errors = [], logs = []; let instance, page;
const installed = process.env.MARGIN_INSTALLED === '1';
const packaged = installed || process.env.MARGIN_PACKAGED === '1';
const executablePath = installed ? path.join((await readFile(path.join(root, '.local-install-path'), 'utf8')).trim(), 'Margin.exe') : packaged ? path.join(root, 'dist/win-unpacked/Margin.exe') : require('electron');
const artifactPrefix = installed ? 'installed-chat-ui' : packaged ? 'packaged-chat-ui' : 'chat-ui';
const env = { ...process.env, LEAF_DATA_DIR: dataDir, TEMP: path.join(root, '.cache/tmp'), TMP: path.join(root, '.cache/tmp') };
delete env.ELECTRON_RUN_AS_NODE;
function pass(name) { checks.push(name); console.log('PASS ' + name); }

async function installMock() {
  await instance.evaluate(({ ipcMain }) => {
    const test = globalThis.__marginChatUITest = {
      models: [{ id: 'mock-a', name: 'Mock Model A', efforts: ['low', 'high'], defaultEffort: 'low' }, { id: 'mock-b', name: 'Mock Model B', efforts: ['auto', 'medium'], defaultEffort: 'auto' }],
      requests: [], threads: new Map(), jobs: new Map(),
      finish(id, status, text) {
        const job = this.jobs.get(id); if (!job) throw new Error('Unknown synthetic job');
        job.status = status; job.text = status === 'completed' ? text : '';
        const thread = this.threads.get(job.threadId), user = thread.messages.find(message => message.id === job.request.requestId);
        user.status = status;
        if (status === 'completed') thread.messages.push({ id: crypto.randomUUID(), role: 'assistant', text, model: job.request.model, effort: job.request.effort, status: 'completed', createdAt: new Date().toISOString() });
        else { job.error = text; user.error = text; }
      }
    };
    ipcMain.removeHandler('margin:chat');
    ipcMain.handle('margin:chat', async (_event, route, body) => {
      const url = new URL(route, 'http://mock.invalid');
      if (url.pathname === '/api/status') return { authenticated: true, planEnabled: true, account: { label: 'Synthetic test account' }, auth: { status: 'success', message: 'Mock account — no real API calls' }, models: structuredClone(test.models), lastError: null };
      if (url.pathname === '/api/models') return { models: structuredClone(test.models), defaultModel: test.models[0]?.id };
      if (url.pathname === '/api/chat/thread') {
        const id = url.searchParams.get('id'), thread = test.threads.get(id), job = [...test.jobs.values()].find(job => job.threadId === id && job.status === 'running');
        return { messages: structuredClone(thread?.messages || []), busy: Boolean(job), jobId: job?.id || null };
      }
      if (url.pathname === '/api/chat/start') {
        test.requests.push(structuredClone(body));
        let thread = test.threads.get(body.threadId); if (!thread) { thread = { messages: [] }; test.threads.set(body.threadId, thread); }
        const job = { id: crypto.randomUUID(), threadId: body.threadId, request: structuredClone(body), status: 'running', text: 'Synthetic partial reply.' };
        thread.messages.push({ id: body.requestId, role: 'user', text: body.text, model: body.model, effort: body.effort, status: 'pending', createdAt: new Date().toISOString(), reference: { scope: body.reference.scope, pages: body.reference.pages.map(value => value.page), totalPages: body.reference.totalPages } });
        test.jobs.set(job.id, job);
        if (body.text === 'simulate failure') test.finish(job.id, 'failed', 'Synthetic service failure');
        return { jobId: job.id };
      }
      if (url.pathname === '/api/chat/status') { const job = test.jobs.get(url.searchParams.get('id')); if (!job) throw new Error('Missing mock job'); return { id: job.id, threadId: job.threadId, status: job.status, text: job.text, error: job.error }; }
      if (url.pathname === '/api/chat/cancel') { test.finish(body.jobId, 'failed', 'Synthetic cancellation requested'); return { cancelled: true }; }
      throw new Error('Unexpected mock route: ' + route);
    });
  });
}
async function requests() { return instance.evaluate(() => structuredClone(globalThis.__marginChatUITest.requests)); }
async function finishLast(text) { await instance.evaluate((_electron, reply) => { const test = globalThis.__marginChatUITest; const job = [...test.jobs.values()].at(-1); test.finish(job.id, 'completed', reply); }, text); }
async function select(phrase) {
  await page.evaluate(phrase => {
    const span = [...document.querySelectorAll('.pdf-page[data-page="0"] .textLayer span')].find(node => node.textContent.includes(phrase));
    if (!span) throw new Error('Missing selection text: ' + phrase);
    const node = span.firstChild, offset = node.textContent.indexOf(phrase), range = document.createRange(); range.setStart(node, offset); range.setEnd(node, offset + phrase.length);
    const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range); span.dispatchEvent(new MouseEvent('mouseup', { bubbles: true }));
  }, phrase);
  await page.locator('#selection-toolbar').waitFor({ state: 'visible' });
}
async function openRow(label) {
  await page.locator('#file-list .file-row').filter({ hasText: label }).click();
  await page.waitForFunction(label => document.querySelector('#document-title').textContent.includes(label), label);
  await page.locator('.pdf-page[data-page="0"] .textLayer span').first().waitFor();
  await page.waitForFunction(() => document.querySelector('#reader-status').textContent !== 'Opening PDF…');
  assert.doesNotMatch(await page.locator('#reader-status').innerText(), /could not open PDF/i);
}
async function send(text) { await page.locator('#question-input').fill(text); await page.locator('#send-question').click(); }
async function editInstructions(value) {
  await page.locator('#settings').click();
  await page.locator('[data-section="personalization"]').click();
  await page.locator('#custom-instructions').fill(value);
  assert.equal(await page.locator('#custom-instructions').inputValue(), value);
}
async function setContext(scope, range) {
  await page.locator('#context-button').click();
  await page.locator(`.control-popover input[name="chat-context"][value="${scope}"]`).check();
  if (range !== undefined) await page.locator('.control-popover .context-pages').fill(range);
  await page.locator('.control-popover').getByRole('button', { name: 'Done', exact: true }).click();
}
async function waitRequests(count) {
  for (let attempt = 0; attempt < 100; attempt++) { if ((await requests()).length === count) return; await page.waitForTimeout(50); }
  throw new Error('Synthetic request count did not reach ' + count);
}
async function close() {
  if (!instance) return;
  const child = instance.process(); await page.locator('[data-window="close"]').click();
  await new Promise((resolve, reject) => { if (child.exitCode !== null) return resolve(); const timer = setTimeout(() => reject(new Error('Close did not flush test records')), 15000); child.once('exit', () => { clearTimeout(timer); resolve(); }); });
  instance = null;
}

try {
  instance = await electron.launch({ executablePath, args: packaged ? [fixtureA] : [root, fixtureA], env, timeout: 30000 });
  instance.process().stderr.on('data', chunk => logs.push(String(chunk)));
  page = await instance.firstWindow(); page.setDefaultTimeout(15000);
  page.on('pageerror', error => errors.push(error.message));
  page.on('console', message => { if (message.type() === 'error') logs.push(message.text()); });
  // Wait until main's initial loadURL has completed before reloading the page.
  await page.locator('.pdf-page[data-page="0"] .textLayer span').first().waitFor();
  await installMock(); await page.reload();
  await page.locator('.pdf-page[data-page="0"] .textLayer span').first().waitFor();
  await page.waitForFunction(() => document.querySelector('.account-models select')?.value === 'mock-a');
  assert.equal(await page.locator('.account-models select').nth(1).inputValue(), 'low');
  await page.locator('.account-models select').first().selectOption('mock-b');
  await page.waitForFunction(() => document.querySelectorAll('.account-models select')[1]?.value === 'auto');
  await page.locator('.account-models select').nth(1).selectOption('medium');
  await instance.evaluate(() => { globalThis.__marginChatUITest.models = [{ id: 'mock-c', name: 'Mock Model C', efforts: ['high'], defaultEffort: 'high' }]; });
  await page.locator('#account button[aria-label="ChatGPT"]').click();
  await page.locator('.control-popover').getByRole('button', { name: 'Refresh Models', exact: true }).click();
  await page.waitForFunction(() => document.querySelector('.account-models select')?.value === 'mock-c');
  const preferences = (await page.evaluate(() => window.margin.bootstrap())).library.settings;
  assert.equal(preferences.selectedModel, 'mock-c'); assert.equal(preferences.selectedEffort, 'high');
  pass('Mock account catalog reconciles removed models and unsupported effort, including saved preferences');

  const initialInstructions = '先解释经济直觉。\nDefine every symbol. 🧭';
  await editInstructions(initialInstructions);
  await page.screenshot({ path: path.join(output, `${artifactPrefix}-personalization.png`) });
  await page.locator('#close-settings').click();
  // A page reload discards renderer state; the saved value must come from disk-backed settings.
  await page.reload();
  await page.locator('.pdf-page[data-page="0"] .textLayer span').first().waitFor();
  await page.waitForFunction(() => document.querySelector('.account-models select')?.value === 'mock-c');
  await page.locator('#settings').click(); await page.locator('[data-section="personalization"]').click();
  assert.equal(await page.locator('#custom-instructions').inputValue(), initialInstructions);
  await page.locator('#close-settings').click();
  pass('Personalization input saves multiline Unicode text and restores it after renderer reload');

  await select('Keep your thoughts beside the source.'); await page.locator('[data-annotation="question"]').click();
  await setContext('custom', '0-2');
  await send('First synthetic question');
  await page.locator('.chat-state.error').waitFor(); assert.equal((await requests()).length, 0);
  assert.match(await page.locator('.chat-state.error').innerText(), /valid page numbers/i);
  await setContext('custom', '3'); await page.locator('#send-question').click();
  await page.waitForFunction(() => document.querySelector('.chat-state.error')?.textContent.includes('no available text'));
  assert.equal((await requests()).length, 0, 'missing OCR text must not silently send incomplete context');
  pass('Invalid custom ranges and pages without OCR are blocked before any mock job starts');
  await setContext('custom', '2,1,2');
  await editInstructions('x'.repeat(16001));
  assert.equal(await page.locator('#instructions-error').isVisible(), true);
  await page.locator('#close-settings').click(); await page.locator('#send-question').click();
  await page.waitForFunction(() => document.querySelector('.chat-state.error')?.textContent.includes('16,000'));
  assert.equal((await requests()).length, 0);
  await editInstructions(initialInstructions);
  assert.equal(await page.locator('#instructions-error').isVisible(), false);
  await page.locator('#close-settings').click(); await page.locator('#send-question').click(); await waitRequests(1);
  const first = (await requests())[0];
  assert.equal(first.customInstructions, initialInstructions);
  pass('Overlong personalization stays editable and blocks inference; the corrected full text reaches the first request');
  assert.deepEqual(first.reference.pages.map(value => value.page), [1, 2]);
  assert.ok(first.reference.pages.every(value => value.text.trim().length > 20));
  assert.equal(first.reference.scope, 'custom'); assert.equal(first.model, 'mock-c'); assert.equal(first.effort, 'high');
  const limited = await page.evaluate(async () => { const { contextPages } = await import('./app.mjs'); try { contextPages('custom', '1-201', 1, 250); return false; } catch { return true; } });
  assert.equal(limited, true); pass('Valid custom context sends complete deduplicated pages and enforces the 200-page limit');

  const reply = '**Mock answer** with \\(x^2+y^2\\).\n\n```js\nconst literal = "$x$";\n```\n\n<script>bad()</script><img src="https://example.invalid/remote.png">';
  await finishLast(reply);
  await page.locator('#chat-messages .katex').first().waitFor(); await page.locator('#send-question').waitFor();
  assert.equal(await page.locator('#chat-messages .katex').count(), 1);
  assert.match(await page.locator('#chat-messages pre code').innerText(), /\$x\$/);
  assert.equal(await page.locator('#chat-messages script,#chat-messages img').count(), 0);
  pass('Completed mock answer renders local KaTeX and Markdown while preserving code and stripping unsafe content');

  const updatedInstructions = 'Answer briefly in English. Explain the intuition first.';
  await editInstructions(updatedInstructions);
  await page.locator('#close-settings').click();
  await setContext('selection'); await send('Follow-up while reopening'); await waitRequests(2);
  const followup = (await requests())[1];
  assert.equal(followup.customInstructions, updatedInstructions);
  assert.equal(followup.threadId, first.threadId); assert.equal(followup.documentId, first.documentId); assert.notEqual(followup.requestId, first.requestId);
  assert.equal(followup.reference.scope, 'selection'); assert.deepEqual(followup.reference.pages, []);
  await openRow('B - another document'); await openRow('A - discussion');
  await select('Every annotation stays linked'); await page.locator('[data-annotation="comment"]').click();
  await page.locator('#comment-input').fill('New comment must survive the older AI job finishing.');
  await finishLast('Synthetic follow-up finished after reopening A.');
  await page.waitForTimeout(1100);
  assert.equal(await page.locator('#comment-input').inputValue(), 'New comment must survive the older AI job finishing.');
  const saved = (await page.evaluate(() => window.margin.bootstrap())).library.documents[originalHash];
  assert.equal(saved.annotations.find(value => value.kind === 'comment').comment, 'New comment must survive the older AI job finishing.');
  assert.equal(saved.annotations.find(value => value.id === first.threadId).messages.length, 4);
  assert.equal(saved.annotations.length, 2);
  pass('Follow-up keeps thread identity and canonical document state protects new notes after PDF switching');

  await page.locator('.detail-heading .text-button').click();
  await page.locator('.note-card').filter({ hasText: 'Keep your thoughts' }).click();
  await editInstructions(''); await page.locator('#close-settings').click();
  await send('Cancel this synthetic question'); await waitRequests(3);
  assert.equal((await requests())[2].customInstructions, '');
  await page.getByRole('button', { name: 'Stop', exact: true }).click();
  await page.waitForFunction(() => document.querySelector('.chat-state.error')?.textContent.includes('Synthetic cancellation'));
  await page.locator('#send-question').waitFor();
  await send('simulate failure'); await waitRequests(4);
  assert.equal((await requests())[3].customInstructions, '');
  await page.waitForFunction(() => document.querySelector('.chat-state.error')?.textContent.includes('Synthetic service failure'));
  await page.locator('#send-question').waitFor();
  assert.ok(await page.locator('.chat-message.failed').count() >= 2);
  await page.screenshot({ path: path.join(output, `${artifactPrefix}.png`) });
  pass('Mock cancellation and service failures retain failed turns and allow subsequent questions');
  pass('Existing conversations use edited preferences on follow-up; clearing disables them on later sends and retries');

  // Inject only test timing, not production data: make an earlier open slower.
  await instance.evaluate(() => {
    const fs = process.getBuiltinModule('fs');
    const original = fs.promises.readFile;
    fs.promises.readFile = async function(file, ...args) {
      if (String(file).includes('B - another document')) await new Promise(resolve => setTimeout(resolve, 120));
      return original.call(this, file, ...args);
    };
    process.getBuiltinModule('module').syncBuiltinESMExports();
  });
  const selectedPath = await page.evaluate(async ({ a, b }) => {
    await Promise.all([window.margin.openDocument(b), window.margin.openDocument(a)]);
    return (await window.margin.bootstrap()).library.selectedPath;
  }, { a: fixtureA, b: fixtureB });
  assert.equal(selectedPath, fixtureA);
  pass('Rapid document opens preserve the most recent selection despite delayed earlier reads');

  await close();
  const persisted = JSON.parse(await readFile(path.join(dataDir, 'library.json'), 'utf8'));
  assert.equal(persisted.documents[originalHash].annotations.length, 2);
  assert.equal(persisted.documents[originalHash].annotations.find(value => value.id === first.threadId).messages.length, 6);
  assert.equal(createHash('sha256').update(await readFile(source)).digest('hex'), originalHash);
  assert.deepEqual(errors, []);
  assert.equal(logs.some(value => /TypeError:|ReferenceError:|SyntaxError:/.test(value)), false, 'caught renderer exceptions must not be hidden by successful UI checks');
  pass('Close drains chat and annotation persistence without changing the fixture or raising renderer errors');
} catch (error) {
  console.error(error); errors.push(error.stack || error.message); process.exitCode = 1;
  if (page && !page.isClosed()) await page.screenshot({ path: path.join(output, `${artifactPrefix}-failure.png`) }).catch(() => {});
} finally {
  if (instance) await close().catch(() => instance?.process().kill());
  await writeFile(path.join(output, `${artifactPrefix}-result.json`), JSON.stringify({ passed: !process.exitCode, packaged, mockChatService: true, realAccountLoginTested: false, realModelCalls: 0, dataDir, checks, errors, logs, checkedAt: new Date().toISOString() }, null, 2));
}
