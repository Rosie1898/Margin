import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { mkdtemp, mkdir, readFile, writeFile, rename, copyFile, readdir, rm, symlink } from 'node:fs/promises';
import { createHash, randomUUID } from 'node:crypto';
import { spawn } from 'node:child_process';
import { LibraryStore, normalizeSettings, defaults, atomicWrite, scanPDFs } from '../src/store.mjs';
import { atomicJson } from '../backend/conversations.mjs';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const fixturePDF = label => Buffer.from(`%PDF-1.4\n1 0 obj\n<< /Type /Catalog >>\nendobj\n% ${label}\n%%EOF\n`);
const annotation = () => ({
  id: randomUUID(), kind: 'question', page: 0, quote: 'Original passage',
  rects: [{ page: 0, x: .1, y: .2, width: .4, height: .03 }],
  comment: 'Preserve this note', color: 'A8DCC5', createdAt: '2026-10-25T12:00:00.000Z',
  messages: [{ id: randomUUID(), role: 'user', text: 'What does this mean?' }, { id: randomUUID(), role: 'assistant', text: 'An explanation.' }],
  contextPreference: { scope: 'nearby', pageRange: '' }, collapsed: true,
});

async function temporary(t) {
  const directory = await mkdtemp(path.join(testDirectory, '.store-test-'));
  t.after(async () => {
    // Never recursively delete a computed path outside this test's own workspace.
    const resolved = path.resolve(directory);
    assert.ok(resolved.startsWith(path.resolve(testDirectory) + path.sep));
    assert.ok(path.basename(resolved).startsWith('.store-test-'));
    await rm(resolved, { recursive: true, force: true, maxRetries: 3, retryDelay: 25 });
  });
  return directory;
}

async function setup(t) {
  const directory = await temporary(t);
  const store = new LibraryStore(path.join(directory, 'data'));
  await store.init();
  const file = path.join(directory, 'Original.pdf');
  const bytes = fixturePDF('original content');
  await writeFile(file, bytes);
  return { directory, store, file, bytes };
}

test('personalization survives edits and restart without truncating multiline or overlong drafts', async t => {
  const { directory, store } = await setup(t);
  assert.equal(store.snapshot().settings.customInstructions, '');
  const preferences = '先解释经济直觉。\nDefine every symbol. 🧭';
  await Promise.all([store.saveSettings({ customInstructions: 'Earlier draft' }), store.saveSettings({ customInstructions: preferences }), store.saveSettings({ textSize: 15 })]);
  await store.close();
  const restored = new LibraryStore(path.join(directory, 'data')); await restored.init();
  assert.equal(restored.snapshot().settings.customInstructions, preferences);
  assert.equal(restored.snapshot().settings.textSize, 15);
  const longDraft = preferences + 'x'.repeat(16001);
  await restored.saveSettings({ customInstructions: longDraft }); await restored.close();
  const reopened = new LibraryStore(path.join(directory, 'data')); await reopened.init();
  assert.equal(reopened.snapshot().settings.customInstructions, longDraft);
  await reopened.saveSettings({ customInstructions: '' }); await reopened.close();
  assert.equal(JSON.parse(await readFile(reopened.file, 'utf8')).settings.customInstructions, '');
});

test('PDF identity survives rename and copy, while changed content gets independent records', async t => {
  const { directory, store, file, bytes } = await setup(t);
  const opened = await store.openDocument(file);
  assert.equal(opened.id, createHash('sha256').update(bytes).digest('hex'));
  const note = annotation();
  await store.saveDocument({ id: opened.id, page: 4, annotations: [note] });
  const renamed = path.join(directory, 'Renamed.PDF');
  await rename(file, renamed);
  const reopened = await store.openDocument(renamed);
  assert.equal(reopened.id, opened.id);
  assert.equal(reopened.page, 4);
  assert.deepEqual(reopened.annotations, [note]);
  const copied = path.join(directory, 'Copied.pdf');
  await copyFile(renamed, copied);
  assert.equal((await store.openDocument(copied)).id, opened.id);
  assert.deepEqual(await readFile(renamed), bytes, 'annotations never modify original PDF bytes');
  await writeFile(copied, fixturePDF('new content'));
  const changed = await store.openDocument(copied);
  assert.notEqual(changed.id, opened.id);
  assert.deepEqual(changed.annotations, []);
  assert.deepEqual(store.snapshot().documents[opened.id].annotations, [note]);
  await store.close();
});

test('queued saves persist complete state, reopen identically, and keep a valid previous backup', async t => {
  const { store, file } = await setup(t);
  const opened = await store.openDocument(file);
  const note = annotation();
  await Promise.all([
    store.saveDocument({ id: opened.id, page: 2, annotations: [note] }),
    store.saveSettings({ textSize: 17, themeHex: '#112233' }),
    store.saveDocument({ id: opened.id, page: 9 }),
  ]);
  await store.close();
  const saved = JSON.parse(await readFile(store.file, 'utf8'));
  assert.equal(saved.documents[opened.id].page, 9);
  assert.deepEqual(saved.documents[opened.id].annotations, [note]);
  assert.equal(saved.settings.textSize, 17);
  assert.equal(saved.settings.themeHex, '112233');
  const backup = JSON.parse(await readFile(`${store.file}.bak`, 'utf8'));
  assert.equal(backup.documents[opened.id].page, 2);
  assert.deepEqual(backup.documents[opened.id].annotations, [note]);
  assert.equal(backup.settings.textSize, 17);
  assert.deepEqual((await readdir(store.dataDir)).sort(), ['library.json', 'library.json.bak']);
  const restored = new LibraryStore(store.dataDir);
  assert.deepEqual(await restored.init(), saved);
  const detached = restored.snapshot();
  detached.documents[opened.id].annotations[0].quote = 'mutated caller copy';
  assert.equal(restored.snapshot().documents[opened.id].annotations[0].quote, note.quote);
  await restored.close();
});

test('atomic replacement failure cleans the temporary file and leaves the existing destination intact', async t => {
  const directory = await temporary(t);
  const destination = path.join(directory, 'existing-directory');
  await mkdir(destination);
  await writeFile(path.join(destination, 'keep.txt'), 'must remain');
  await assert.rejects(atomicWrite(destination, 'replacement'));
  assert.equal(await readFile(path.join(destination, 'keep.txt'), 'utf8'), 'must remain');
  assert.deepEqual(await readdir(directory), ['existing-directory']);
});

for (const [label, write, expected] of [['library', atomicWrite, 'replacement'], ['conversation', atomicJson, '"replacement"\n']])
test(`${label} atomic save survives a real temporary Windows exclusive file lock`, { skip: process.platform !== 'win32', timeout: 15000 }, async t => {
  const directory = await temporary(t), destination = path.join(directory, 'locked.json');
  await writeFile(destination, 'original');
  const script = '$stream=[IO.File]::Open($env:MARGIN_TEST_LOCK_PATH,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None); try { [Console]::Out.WriteLine("LOCKED"); [Console]::Out.Flush(); Start-Sleep -Milliseconds 350 } finally { $stream.Dispose() }';
  const child = spawn('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', script], { windowsHide: true, env: { ...process.env, MARGIN_TEST_LOCK_PATH: destination } });
  let output = '', errors = '';
  child.stderr.on('data', chunk => { errors += chunk; });
  const exited = new Promise((resolve, reject) => { child.once('error', reject); child.once('exit', code => code === 0 ? resolve() : reject(new Error(errors || `Lock process exited ${code}`))); });
  const timeout = setTimeout(() => child.kill(), 10000);
  try {
    await new Promise((resolve, reject) => { child.stdout.on('data', chunk => { output += chunk; if (output.includes('LOCKED')) resolve(); }); child.once('error', reject); child.once('exit', () => { if (!output.includes('LOCKED')) reject(new Error(errors || 'File lock was not acquired')); }); });
    await write(destination, 'replacement');
    await exited;
    assert.equal(await readFile(destination, 'utf8'), expected);
    assert.deepEqual(await readdir(directory), ['locked.json']);
  } finally { clearTimeout(timeout); if(child.exitCode===null)child.kill(); await exited.catch(()=>{}); }
});

test('malformed, unsupported, and invalid annotation data fail closed without overwriting records', async t => {
  const hash = 'a'.repeat(64);
  const base = { version: 1, platform: 'windows', settings: {}, documents: {} };
  const invalidNote = annotation();
  invalidNote.rects[0].width = 3;
  const fixtures = [
    '{ truncated JSON',
    JSON.stringify({ ...base, version: 2 }),
    JSON.stringify({ ...base, version: 3, platform: 'macOS' }),
    JSON.stringify({ ...base, documents: [] }),
    JSON.stringify({ ...base, documents: { [hash]: { id: hash, page: 0, annotations: [invalidNote] } } }),
  ];
  for (const [index, original] of fixtures.entries()) {
    await t.test(`invalid record ${index + 1}`, async inner => {
      const directory = await temporary(inner);
      const file = path.join(directory, 'library.json');
      await writeFile(file, original);
      const store = new LibraryStore(directory);
      await assert.rejects(store.init(), /停止写入/);
      await assert.rejects(store.saveSettings({ textSize: 20 }), /暂停/);
      await assert.rejects(store.persist(), /暂停/);
      assert.equal(await readFile(file, 'utf8'), original);
      assert.deepEqual(await readdir(directory), ['library.json']);
    });
  }
});

test('settings enforce numeric, color, language and layout bounds without sharing defaults', () => {
  const input = { language: 'unsupported', textSize: 100, centerOpacity: -4, sidesOpacity: 8,
    themeHex: '#a1B2c3', highlightColorHex: 'broken', paneProportions: [1, 3, 1],
    backgroundImage: 'file:///private/path', contextScope: 'arbitrary' };
  const normalized = normalizeSettings(input);
  assert.equal(normalized.language, 'system');
  assert.equal(normalized.textSize, 20);
  assert.equal(normalized.centerOpacity, 0);
  assert.equal(normalized.sidesOpacity, 1);
  assert.equal(normalized.themeHex, 'A1B2C3');
  assert.equal(normalized.highlightColorHex, defaults.highlightColorHex);
  assert.deepEqual(normalized.paneProportions, [.2, .6, .2]);
  assert.equal(normalized.backgroundImage, null);
  assert.equal(normalized.contextScope, 'page');
  assert.equal(normalizeSettings({ textSize: -100 }).textSize, 11);
  assert.equal(normalizeSettings({ textSize: Infinity }).textSize, 13);
  assert.equal(normalizeSettings({ centerOpacity: NaN }).centerOpacity, .94);
  assert.deepEqual(normalizeSettings({ paneProportions: [1, 0, 1] }).paneProportions, [.2, .6, .2]);
  assert.deepEqual(normalizeSettings({ paneProportions: [Number.MAX_VALUE, Number.MAX_VALUE, 1] }).paneProportions, [.2, .6, .2]);
  normalized.paneProportions[0] = 999;
  assert.deepEqual(normalizeSettings().paneProportions, [.2, .6, .2]);
  assert.deepEqual(input.paneProportions, [1, 3, 1]);
});

test('corrupt message and document metadata fail closed before renderer use', async t => {
  const hash = 'c'.repeat(64);
  const valid = () => ({ version: 1, platform: 'windows', settings: {}, folderPath: null, selectedPath: null,
    documents: { [hash]: { id: hash, path: path.join(testDirectory, 'paper.pdf'), name: 'paper.pdf', page: 0, annotations: [annotation()] } } });
  const changes = [
    ['message collection', value => { value.documents[hash].annotations[0].messages = 'not an array'; }],
    ['message body', value => { value.documents[hash].annotations[0].messages[0].text = { text: 'bad' }; }],
    ['message role', value => { value.documents[hash].annotations[0].messages[0].role = 'system'; }],
    ['message identifier', value => { value.documents[hash].annotations[0].messages[0].id = '-'.repeat(36); }],
    ['annotation identifier', value => { value.documents[hash].annotations[0].id = '-'.repeat(36); }],
    ['duplicate case-insensitive identifiers', value => { const a = value.documents[hash].annotations[0]; value.documents[hash].annotations.push({ ...a, id: a.id.toUpperCase() }); }],
    ['invalid timestamp', value => { value.documents[hash].annotations[0].deletedAt = {}; }],
    ['invalid reference range', value => { value.documents[hash].annotations[0].messages[0].reference = { scope: 'custom', totalPages: 10, pages: [2, 1] }; }],
    ['oversized model metadata', value => { value.documents[hash].annotations[0].messages[0].model = 'm'.repeat(1001); }],
    ['non-string path', value => { value.documents[hash].path = {}; }],
    ['missing filename', value => { delete value.documents[hash].name; }],
    ['invalid selected path', value => { value.selectedPath = ['paper.pdf']; }],
  ];
  for (const [label, change] of changes) {
    await t.test(label, async inner => {
      const directory = await temporary(inner), value = valid();
      change(value);
      const source = JSON.stringify(value), file = path.join(directory, 'library.json');
      await writeFile(file, source);
      const store = new LibraryStore(directory);
      await assert.rejects(store.init(), /停止写入/);
      await assert.rejects(store.persist(), /暂停/);
      assert.equal(await readFile(file, 'utf8'), source);
      assert.deepEqual(await readdir(directory), ['library.json']);
    });
  }
});

test('optional message fields and empty conversation arrays remain compatible', async t => {
  const { store, file } = await setup(t);
  const opened = await store.openDocument(file), note = annotation();
  note.messages = [];
  note.deletedAt = null;
  note.customColorHex = null;
  await store.saveDocument({ id: opened.id, annotations: [note] });
  const assistant = { id: randomUUID(), role: 'assistant', text: 'A reply.', model: null, effort: null,
    createdAt: '2026-10-25T12:00:00.000Z', status: 'completed', failed: false, hasImage: false,
    reference: { scope: 'selection', totalPages: 3, pages: [] }, evidence: { actualModel: 'synthetic' } };
  note.messages.push(assistant);
  await store.saveDocument({ id: opened.id, annotations: [note] });
  await store.close();
  const reopened = new LibraryStore(store.dataDir);
  assert.deepEqual((await reopened.init()).documents[opened.id].annotations[0], note);
  await reopened.close();
});

test('soft deletion retains complete notes across restart with no expiry and restoration recovers all content', async t => {
  const { store, file } = await setup(t);
  const opened = await store.openDocument(file);
  const note = annotation();
  const deleted = { ...note, deletedAt: '2000-01-01T00:00:00.000Z' };
  await store.saveDocument({ id: opened.id, annotations: [deleted] });
  await store.close();
  const restored = new LibraryStore(store.dataDir);
  const snapshot = await restored.init();
  assert.deepEqual(snapshot.documents[opened.id].annotations, [deleted], 'old deleted notes are not expired or removed');
  const recovered = { ...snapshot.documents[opened.id].annotations[0] };
  delete recovered.deletedAt;
  await restored.saveDocument({ id: opened.id, annotations: [recovered] });
  await restored.close();
  const reopened = new LibraryStore(store.dataDir);
  assert.deepEqual((await reopened.init()).documents[opened.id].annotations, [note]);
  await reopened.close();
});

test('invalid updates leave persisted annotations intact', async t => {
  const { store, file } = await setup(t);
  const opened = await store.openDocument(file), note = annotation();
  await store.saveDocument({ id: opened.id, annotations: [note] });
  const original = await readFile(store.file, 'utf8');
  await assert.rejects(store.saveDocument({ id: opened.id, page: -1 }));
  await assert.rejects(store.saveDocument({ id: opened.id, annotations: [note, note] }));
  await assert.rejects(store.saveDocument({ id: opened.id, annotations: [{ ...note, kind: 'unknown' }] }));
  await assert.rejects(store.saveDocument({ id: opened.id, annotations: [{ ...note, rects: [{ page: 0, x: 0, y: 0, width: NaN, height: 1 }] }] }));
  assert.equal(await readFile(store.file, 'utf8'), original);
  assert.deepEqual(store.snapshot().documents[opened.id].annotations, [note]);
  await store.close();
});

test('folder scanning preserves nested paths, accepts case variants, and does not traverse linked directories', async t => {
  const directory = await temporary(t);
  await mkdir(path.join(directory, 'Nested', '深层'), { recursive: true });
  for (const relative of ['paper10.pdf', 'paper2.PDF', 'Nested/Article.PdF', 'Nested/深层/中文.pdf', 'ignore.pdf.txt']) {
    await writeFile(path.join(directory, relative), fixturePDF(relative));
  }
  try {
    await symlink(path.join(directory, 'Nested'), path.join(directory, 'linked'), process.platform === 'win32' ? 'junction' : 'dir');
  } catch (error) {
    if (!['EPERM', 'EACCES', 'ENOSYS'].includes(error.code)) throw error;
    t.diagnostic('This environment cannot create a link; nested/case scanning remains covered.');
  }
  const result = await scanPDFs(directory);
  assert.deepEqual(new Set(result.map(item => item.relativePath)), new Set(['paper10.pdf', 'paper2.PDF', 'Nested/Article.PdF', 'Nested/深层/中文.pdf']));
  assert.ok(result.every(item => path.isAbsolute(item.path)));
  assert.ok(result.findIndex(item => item.name === 'paper2.PDF') < result.findIndex(item => item.name === 'paper10.pdf'));
  assert.deepEqual(await scanPDFs(null), []);
});
