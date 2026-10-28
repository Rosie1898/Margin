/** Real Electron coverage for the 0.5.1 visual/localization/OCR refinements.
 * Only chat IPC is synthetic. OCR calls the installed Windows recognizers.
 */
import { _electron as electron } from 'playwright';
import assert from 'node:assert/strict';
import { mkdir, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { randomUUID, createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { LibraryStore } from '../src/store.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const require = createRequire(import.meta.url), output = path.join(root, 'test-results');
await mkdir(output, { recursive: true });
const dataDir = await mkdtemp(path.join(output, 'refinements-'));
const fixture = path.join(output, 'fixtures/Margin verification.pdf');
const originalHash = createHash('sha256').update(await readFile(fixture)).digest('hex');
const store = new LibraryStore(dataDir); await store.init(); await store.setFolder(path.dirname(fixture));
await store.saveSettings({ language: 'en', ocrLanguage: 'en-US' });
const doc = await store.openDocument(fixture);
const messages = [
  { id: randomUUID(), role: 'user', text: 'How does the argument connect to the evidence?', status: 'completed' },
  { id: randomUUID(), role: 'assistant', text: 'Synthetic preview: compare the assumption with the observed result.\n\n`evidence = observation`\n\nThe formula is \\(x^2\\).', status: 'completed', model: 'Preview model' }
];
await store.saveDocument({ id: doc.id, annotations: [
  { id: randomUUID(), kind: 'question', createdAt: '2026-10-25T00:00:00Z', page: 0, rects: [], quote: 'Keep your thoughts beside the source.', color: 'A8DCC5', contextScope: 'page', messages },
  { id: randomUUID(), kind: 'comment', createdAt: '2026-10-25T01:00:00Z', page: 0, rects: [], quote: 'Every annotation stays linked', color: 'A8DCC5', comment: 'A note for the typography preview.' }
] });
await store.close();
const packaged = process.env.MARGIN_PACKAGED === '1', prefix = packaged ? 'packaged-refinements' : 'refinements';
const checks = [], errors = [], logs = [];
const env = { ...process.env, LEAF_DATA_DIR: dataDir, TEMP: path.join(root, '.cache/tmp'), TMP: path.join(root, '.cache/tmp') };
delete env.ELECTRON_RUN_AS_NODE;
let instance, page;
function pass(name) { checks.push(name); console.log('PASS ' + name); }
async function close() {
  if (!instance) return;
  const child = instance.process(); await page.locator('[data-window="close"]').click();
  await new Promise((resolve, reject) => { if (child.exitCode !== null) return resolve(); const timer = setTimeout(() => reject(new Error('Close did not finish')), 15000); child.once('exit', () => { clearTimeout(timer); resolve(); }); });
  instance = null;
}
async function english(label) {
  const untranslated = await page.evaluate(() => {
    const result = [], walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    while (walker.nextNode()) {
      const node = walker.currentNode, parent = node.parentElement;
      if (!parent || parent.closest('script,style,option,.textLayer,.katex,textarea') || !parent.checkVisibility()) continue;
      if (/\p{Script=Han}/u.test(node.textContent)) result.push(node.textContent.trim());
    }
    for (const el of document.querySelectorAll('[title],[aria-label],[placeholder]')) {
      if (!el.checkVisibility() || el.closest('option,.textLayer')) continue;
      for (const key of ['title', 'aria-label', 'placeholder']) if (/\p{Script=Han}/u.test(el.getAttribute(key) || '')) result.push(el.getAttribute(key));
    }
    return result;
  });
  assert.deepEqual(untranslated, [], label + ' has Chinese UI strings');
}
async function appearance() { await page.locator('#settings').click(); await page.locator('[data-section="appearance"]').click(); }
async function settingsSnapshot() { return (await page.evaluate(() => window.margin.bootstrap())).library.settings; }
async function surfaces() { return page.evaluate(() => Object.fromEntries(['#library', '#reader', '#discussion', '#reading-space', '#settings-dialog', '#settings svg', '.chat-message.user', '.chat-message:not(.user)'].map(selector => { const el = document.querySelector(selector), style = getComputedStyle(el); return [selector, selector.endsWith('svg') ? style.color : style.backgroundColor]; }))); }

try {
  instance = await electron.launch({ executablePath: packaged ? path.join(root, 'dist/win-unpacked/Margin.exe') : require('electron'), args: packaged ? [fixture] : [root, fixture], env, timeout: 30000 });
  instance.process().stderr.on('data', data => logs.push(String(data)));
  page = await instance.firstWindow(); page.setDefaultTimeout(15000);
  page.on('pageerror', error => errors.push(error.message));
  page.on('console', message => { if (message.type() === 'error') logs.push(message.text()); });
  await page.locator('.pdf-page[data-page="0"] .textLayer span').first().waitFor();
  await instance.evaluate(({ ipcMain }, messages) => {
    ipcMain.removeHandler('margin:chat');
    ipcMain.handle('margin:chat', (_event, route) => {
      const pathname = new URL(route, 'http://mock.invalid').pathname;
      const models = [{ id: 'preview-model', name: 'Preview model', efforts: ['low', 'high'], defaultEffort: 'low' }];
      if (pathname === '/api/status') return { authenticated: true, planEnabled: true, auth: { status: 'success' }, models };
      if (pathname === '/api/models') return { models };
      if (pathname === '/api/chat/thread') return { messages, busy: false };
      throw new Error('Unexpected synthetic chat request: ' + route);
    });
  }, messages);
  await page.reload(); await page.locator('.account-models select').first().waitFor();
  await page.locator('.note-card').first().click(); await page.locator('.chat-message').nth(1).waitFor();
  await english('Reading and discussion');
  const model = await page.locator('.account-models select').first().evaluate(el => ({ height: el.getBoundingClientRect().height, background: getComputedStyle(el).backgroundColor }));
  assert.ok(model.height <= 26); assert.equal(model.background, 'rgba(0, 0, 0, 0)');
  assert.equal(await page.locator('svg.brand-image').count(), 1);
  assert.equal(await page.locator('#titlebar .brand,#titlebar .brand-image').count(), 0);
  assert.equal(await page.locator('.annotation-color').count(), 2); // Hidden selection palette + detail control.
  await page.locator('.detail-heading .annotation-color').click(); await english('Annotation color popover');
  await page.locator('.color-popover .primary').click();
  const fonts = await page.locator('.source-quote,.chat-message .message-body,.chat-message code,#question-input').evaluateAll(nodes => nodes.map(node => getComputedStyle(node).fontFamily));
  assert.ok(fonts.length >= 4); assert.ok(fonts.every(font => /Segoe UI/i.test(font) && !/Georgia|Consolas|serif(?!.*sans-serif)/i.test(font.replace('sans-serif', ''))), fonts.join('\n'));
  await page.locator('#context-button').click(); await english('Context popover'); await page.locator('.popover-actions .primary').click();
  pass('English discussion/color/context UI, compact model selectors and sans-serif text');

  await page.locator('#settings').click(); await english('General settings');
  assert.equal(await page.locator('#settings-body #ocr-language').count(), 0);
  const language = page.locator('#settings-body select').first();
  await language.selectOption('zhHans'); await page.waitForFunction(() => document.documentElement.lang === 'zh-CN');
  await page.locator('#settings-body select').first().selectOption('en'); await english('Settings after switching back to English');
  await page.locator('[data-section="appearance"]').click(); await english('Appearance settings');
  const presets = await page.locator('[data-theme-color]').evaluateAll(nodes => nodes.map(node => node.dataset.themeColor));
  assert.deepEqual(presets, ['F5F7F3', 'E5ECF3', 'EBE9ED', 'EEEAEC', 'E9EAEC', '253247', '202124']);
  const snapshots = [];
  for (const hex of presets) {
    await page.locator(`[data-theme-color="${hex}"]`).click();
    await page.waitForFunction(hex => getComputedStyle(document.documentElement).getPropertyValue('--theme').trim().toUpperCase() === '#' + hex, hex);
    snapshots.push(await surfaces());
    assert.equal(await page.locator('.brand-image path').first().evaluate(el => getComputedStyle(el).fill), await page.locator('#settings svg').evaluate(el => getComputedStyle(el).color));
    const saved = await settingsSnapshot(); assert.equal(saved.themeHex, hex);
    assert.notEqual(saved.userBubble, 'EAF1FB'); assert.notEqual(saved.aiBubble, 'E8F3ED');
  }
  // Very pale center colors can coincide after RGB rounding for two muted hues.
  for (const selector of Object.keys(snapshots[0])) {
    assert.ok(new Set(snapshots.map(value => value[selector])).size >= 6, selector + ' did not follow theme changes');
    assert.notEqual(snapshots[0][selector], snapshots[6][selector], selector + ' did not follow dark mode');
  }
  assert.equal(await page.locator('html').getAttribute('data-theme'), 'dark');
  await page.screenshot({ path: path.join(output, prefix + '-black-settings.png') });
  await page.locator('#close-settings').click(); await page.screenshot({ path: path.join(output, prefix + '-black.png') });
  await appearance(); await page.locator('[data-theme-color="253247"]').click();
  await page.locator('#close-settings').click(); await page.screenshot({ path: path.join(output, prefix + '-navy.png') });
  pass('All seven themes update three panes, reading canvas, settings, icons and both chat bubbles');

  await appearance();
  await page.locator('#settings-body input[type="color"]').nth(1).evaluate(el => { el.value = '#ffffff'; el.dispatchEvent(new Event('input', { bubbles: true })); });
  await page.waitForFunction(() => getComputedStyle(document.documentElement).getPropertyValue('--user-bubble').trim() === '#FFFFFF');
  assert.equal(await page.locator('.chat-message.user .message-body').evaluate(el => getComputedStyle(el).color), 'rgb(0, 0, 0)');
  await page.locator('#settings-body input[type="color"]').nth(1).evaluate(el => { el.value = '#808080'; el.dispatchEvent(new Event('input', { bubbles: true })); });
  await page.waitForFunction(() => getComputedStyle(document.documentElement).getPropertyValue('--user-bubble').trim() === '#808080');
  const contrast = await page.locator('.chat-message.user').evaluate(el => {
    const luminance = text => { const rgb = text.match(/[\d.]+/g).slice(0, 3).map(Number).map(n => n / 255).map(n => n <= .04045 ? n / 12.92 : ((n + .055) / 1.055) ** 2.4); return rgb[0] * .2126 + rgb[1] * .7152 + rgb[2] * .0722; };
    const bg = luminance(getComputedStyle(el).backgroundColor);
    return ['.message-body', '.message-meta'].map(selector => { const fg = luminance(getComputedStyle(el.querySelector(selector)).color); return (Math.max(bg, fg) + .05) / (Math.min(bg, fg) + .05); });
  });
  assert.ok(contrast.every(value => value >= 4.5), 'Custom gray bubble body and metadata contrast');
  await page.locator('[data-theme-color="F5F7F3"]').click(); await page.locator('#close-settings').click();
  await page.screenshot({ path: path.join(output, prefix + '-green.png') });
  pass('Custom white and middle-gray chat bubbles retain readable body and metadata in a dark theme');

  await page.locator('#ocr-menu-button').click(); await page.locator('#ocr-language option[value="en-US"]').waitFor({ state: 'attached', timeout: 30000 });
  await english('Toolbar OCR menu');
  const languages = await page.locator('#ocr-language option').evaluateAll(nodes => nodes.map(node => ({ value: node.value, label: node.textContent })));
  assert.ok(languages.some(item => item.value === 'en-US')); assert.ok(languages.some(item => item.value === 'zh-Hans-CN'));
  assert.ok(languages.every(item => !/\p{Script=Han}/u.test(item.label)));
  await page.screenshot({ path: path.join(output, prefix + '-ocr-menu.png') });
  await page.locator('#ocr-menu-button').click();
  await page.locator('#page-number').fill('3'); await page.locator('#page-number').press('Enter');
  await page.locator('.pdf-page[data-page="2"] .ocr-word').first().waitFor({ timeout: 45000 });
  await page.waitForFunction(() => document.querySelector('#reader-status').textContent === '', null, { timeout: 30000 });
  assert.ok((await page.evaluate(id => window.margin.ocrCache(id, 'en-US'), doc.id)).length > 0);
  await page.locator('#ocr-menu-button').click(); await page.locator('#ocr-language').selectOption('zh-Hans-CN');
  await page.waitForFunction(async () => (await window.margin.bootstrap()).library.settings.ocrLanguage === 'zh-Hans-CN');
  await page.locator('#ocr-page').click();
  await page.waitForFunction(async id => (await window.margin.ocrCache(id, 'zh-Hans-CN')).length > 0, doc.id, { timeout: 45000 });
  assert.ok((await page.evaluate(id => window.margin.ocrCache(id, 'en-US'), doc.id)).length > 0);
  assert.ok(await page.locator('.pdf-page[data-page="0"] .textLayer span:not(.ocr-word)').count() > 0);
  pass('Toolbar exposes installed OCR languages, reruns with a new language and retains separate caches');
  await page.locator('#ocr-menu-button').click(); await page.locator('#ocr-language').selectOption('en-US'); await page.locator('#ocr-menu-button').click();
  await page.locator('#settings').click(); await page.locator('[data-section="trash"]').click(); await english('Recently Deleted'); await page.locator('#close-settings').click();
  assert.deepEqual(errors, []); assert.ok(!logs.some(line => /Error occurred in handler|Error invoking remote method|EPERM|EACCES|EBUSY/.test(line)), logs.join('\n'));
  assert.equal(createHash('sha256').update(await readFile(fixture)).digest('hex'), originalHash);
  await close();
  const saved = JSON.parse(await readFile(path.join(dataDir, 'library.json'), 'utf8'));
  assert.equal(saved.settings.ocrLanguage, 'en-US'); assert.equal(saved.settings.language, 'en'); assert.equal(saved.settings.themeHex, 'F5F7F3');
  pass('English trash view, persisted preferences, unchanged PDF and no renderer exceptions');
} catch (error) {
  console.error(error); errors.push(error.stack || error.message); process.exitCode = 1;
  if (page && !page.isClosed()) await page.screenshot({ path: path.join(output, prefix + '-failure.png') }).catch(() => {});
} finally {
  if (instance) await close().catch(() => instance?.process().kill());
  await writeFile(path.join(output, prefix + '-result.json'), JSON.stringify({ passed: !process.exitCode, packaged, dataDir, checks, errors, logs, checkedAt: new Date().toISOString() }, null, 2));
}
