import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { mkdtemp, readFile, writeFile, readdir, rm, mkdir } from 'node:fs/promises';
import { randomBytes, createCipheriv, createDecipheriv } from 'node:crypto';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { SecureCredentialStore } from '../src/services/secure-credentials.mjs';
import { validateChatRoute, createChatService } from '../src/services/chat-service.mjs';
import { OcrService, validateOcrInput } from '../src/services/ocr-service.mjs';

function fakeSafeStorage() {
  const key = randomBytes(32);
  return {
    isEncryptionAvailable: () => true,
    encryptString(text) {
      const iv = randomBytes(12), cipher = createCipheriv('aes-256-gcm', key, iv);
      const body = Buffer.concat([cipher.update(text, 'utf8'), cipher.final()]);
      return Buffer.concat([iv, cipher.getAuthTag(), body]);
    },
    decryptString(bytes) {
      const cipher = createDecipheriv('aes-256-gcm', key, bytes.subarray(0, 12), { authTagLength: 16 });
      cipher.setAuthTag(bytes.subarray(12, 28));
      return Buffer.concat([cipher.update(bytes.subarray(28)), cipher.final()]).toString('utf8');
    },
  };
}
async function temporary(t) {
  const directory = await mkdtemp(fileURLToPath(new URL('./.margin-services-', import.meta.url)));
  t.after(() => rm(directory, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 }));
  return directory;
}

test('credentials are encrypted, survive replacement and are cleared on logout', async t => {
  const dataDir = await temporary(t), storage = fakeSafeStorage();
  const store = new SecureCredentialStore({ dataDir, safeStorage: storage });
  assert.equal(await store.load(), null);
  await store.save({ refreshToken: 'secret-first' });
  assert.equal((await readFile(store.file)).includes(Buffer.from('secret-first')), false);
  assert.deepEqual(await store.load(), { refreshToken: 'secret-first' });
  await Promise.all([store.save({ refreshToken: 'rotated-token' }), store.save({ refreshToken: 'latest-token' })]);
  assert.deepEqual(await store.load(), { refreshToken: 'latest-token' });
  assert.deepEqual(await readdir(dataDir), ['credentials.dpapi']);
  await store.delete();
  assert.equal(await store.load(), null);
});

test('credential encryption unavailable or corrupt file fails closed and preserves original', async t => {
  const dataDir = await temporary(t);
  const unavailable = new SecureCredentialStore({ dataDir, safeStorage: { isEncryptionAvailable: () => false } });
  await assert.rejects(unavailable.save({ refreshToken: 'must-not-be-written' }));
  assert.deepEqual(await readdir(dataDir), []);
  const store = new SecureCredentialStore({ dataDir, safeStorage: fakeSafeStorage() });
  await writeFile(store.file, 'corrupt-encrypted-record');
  await assert.rejects(store.load(), /无法解密/);
  assert.equal(await readFile(store.file, 'utf8'), 'corrupt-encrypted-record');
});

test('asynchronous Electron storage is supported and re-encrypts a rotated key', async t => {
  const dataDir = await temporary(t), cipher = fakeSafeStorage();
  let encryptions = 0;
  const store = new SecureCredentialStore({ dataDir, safeStorage: {
    isAsyncEncryptionAvailable: async () => true,
    encryptStringAsync: async value => { encryptions++; return cipher.encryptString(value); },
    decryptStringAsync: async value => ({ result: cipher.decryptString(value), shouldReEncrypt: true }),
  } });
  await store.save({ refreshToken: 'rotate-protected-key' });
  assert.deepEqual(await store.load(), { refreshToken: 'rotate-protected-key' });
  assert.equal(encryptions, 2);
});

test('chat route bridge accepts only exact API operations', () => {
  assert.equal(validateChatRoute('/api/status', false), '/api/status');
  assert.equal(validateChatRoute('/api/chat/thread?id=example', false), '/api/chat/thread?id=example');
  for (const value of ['https://evil.test/api/status', '//evil.test/api/status', '/api/../auth/callback', '/api/status?url=https://evil.test', '/api/status#fragment', '/api/chat/thread?id=1&id=2']) assert.throws(() => validateChatRoute(value, false));
  assert.throws(() => validateChatRoute('/api/logout', false));
  assert.throws(() => validateChatRoute('/api/status', true));
});

test('chat bridge starts without network or credentials, exposes no CSRF and closes cleanly', async t => {
  const dataDir = await temporary(t);
  const service = await createChatService({ dataDir, safeStorage: fakeSafeStorage(), openExternal: async () => { throw new Error('unexpected browser'); }, fetchImpl: async () => { throw new Error('unexpected network'); } });
  try {
    const status = await service.request('/api/status');
    assert.equal(status.authenticated, false);
    assert.equal('csrfToken' in status, false);
    await assert.rejects(service.request('/api/chat/start', {}), /登录/);
  } finally { await service.close(); }
  await service.close();
  await assert.rejects(service.request('/api/status'), /关闭/);
});

test('OCR validates document isolation, bytes and dimensions', () => {
  assert.throws(() => validateOcrInput({ documentId: '../oops', page: 0, png: Buffer.alloc(40) }));
  const png = Buffer.alloc(40);
  Buffer.from([137,80,78,71,13,10,26,10]).copy(png);
  png.writeUInt32BE(1400, 16); png.writeUInt32BE(500, 20);
  assert.deepEqual(validateOcrInput({ documentId: 'a'.repeat(64), page: 0, png }), { width: 1400, height: 500 });
  assert.throws(() => validateOcrInput({ documentId: 'a'.repeat(64), page: 0, png, language: '../../bad' }));
  png.writeUInt32BE(20000, 16);
  assert.throws(() => validateOcrInput({ documentId: 'a'.repeat(64), page: 0, png }));
});

test('OCR cache restore rejects foreign identity, wrong version, malformed words and other languages', async t => {
  const dataDir = await temporary(t), documentId = 'c'.repeat(64);
  const service = new OcrService({ dataDir });
  assert.deepEqual(await service.cached(documentId), []);
  const directory = path.join(dataDir, 'OCR', documentId);
  await mkdir(directory, { recursive: true });
  const base = { version: 1, documentId, rasterHash: 'd'.repeat(64), languagePreference: 'auto', page: 0, width: 1400, height: 500, text: 'Cached text', words: [{ text: 'Cached', x: 12, y: 24, width: 70, height: 30, line: 0 }] };
  await writeFile(path.join(directory, 'page-0-auto.json'), JSON.stringify(base));
  await writeFile(path.join(directory, 'page-1-auto.json'), JSON.stringify({ ...base, page: 1, documentId: 'e'.repeat(64) }));
  await writeFile(path.join(directory, 'page-2-auto.json'), JSON.stringify({ ...base, page: 2, version: 999 }));
  await writeFile(path.join(directory, 'page-3-auto.json'), JSON.stringify({ ...base, page: 3, words: [{ ...base.words[0], x: -1 }] }));
  await writeFile(path.join(directory, 'page-4-en-US.json'), JSON.stringify({ ...base, page: 4, languagePreference: 'en-US' }));
  assert.deepEqual((await service.cached(documentId)).map(item => item.page), [0]);
  assert.deepEqual((await service.cached(documentId, 'en-US')).map(item => item.page), [4]);
  assert.equal((await service.cached(documentId))[0].result.cached, true);
  await assert.rejects(service.cached('../other'), /无效/);
});

test('changing documents during the startup probe does not disable OCR', { skip: process.platform !== 'win32', timeout: 15000 }, async t => {
  const service = new OcrService({ dataDir: await temporary(t) });
  t.after(() => service.close());
  const probing = service.status();
  service.cancel();
  const status = await probing;
  assert.equal(status.available, true, JSON.stringify(status));
  assert.ok(status.languages.length > 0);
  assert.equal((await service.status()).available, true);
});

test('real Windows OCR recognizes English and Chinese, returns rectangles and reuses cache', { skip: process.platform !== 'win32', timeout: 120000 }, async t => {
  const dataDir = await temporary(t), image = path.join(dataDir, 'synthetic-scan.png');
  const script = fileURLToPath(new URL('./ocr-smoke.ps1', import.meta.url));
  const powershell = path.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
  await new Promise((resolve, reject) => {
    const child = spawn(powershell, ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', script, '-OutputPath', image], { windowsHide: true, stdio: ['ignore', 'ignore', 'pipe'] });
    let errors = ''; child.stderr.on('data', bytes => { errors += bytes; });
    child.on('error', reject); child.on('close', code => code === 0 ? resolve() : reject(new Error(errors)));
  });
  const service = new OcrService({ dataDir });
  t.after(() => service.close());
  const status = await service.status();
  assert.equal(status.available, true, JSON.stringify(status));
  const language = status.languages.some(item => item.tag === 'zh-Hans-CN') ? 'zh-Hans-CN' : 'en-US';
  const input = { documentId: 'b'.repeat(64), page: 0, png: await readFile(image), language };
  const result = await service.recognize(input);
  assert.match(result.text, /Margin.*local.*OCR.*2026/i);
  // OCR is not guaranteed to be exact; assert the Chinese line is recognized,
  // while the full English phrase supplies the stronger fixed-text check.
  if (language === 'zh-Hans-CN') assert.match(result.text.replace(/\s/g, ''), /本地文字/);
  assert.equal(result.width, 1400); assert.equal(result.height, 500);
  assert.ok(result.words.length > 8);
  assert.ok(result.words.every(word => word.x >= 0 && word.y >= 0 && word.width > 0 && word.height > 0 && word.x + word.width <= result.width && word.y + word.height <= result.height));
  assert.equal(result.cached, false);
  assert.equal((await service.recognize(input)).cached, true);
  const restored = await new OcrService({ dataDir }).cached(input.documentId, language);
  assert.equal(restored.length, 1);
  assert.equal(restored[0].page, 0);
  assert.equal(restored[0].result.text, result.text);
  const files = await readdir(path.join(dataDir, 'OCR', 'b'.repeat(64)));
  assert.deepEqual(files, [`page-0-${language}.json`]);
  const cancelled = service.recognize({ ...input, page: 1 });
  service.cancel();
  await assert.rejects(cancelled, /取消/);
});
