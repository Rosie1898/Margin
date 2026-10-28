import { app, safeStorage } from 'electron';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';
import { mkdir, readFile, writeFile, access } from 'node:fs/promises';
import { mkdirSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import assert from 'node:assert/strict';
import { SecureCredentialStore } from '../src/services/secure-credentials.mjs';
import { OcrService } from '../src/services/ocr-service.mjs';

const directory = process.env.MARGIN_NATIVE_TEST_DIR;
const reportPath = process.env.MARGIN_NATIVE_TEST_REPORT;
if (!directory || !reportPath || !path.isAbsolute(directory) || !path.isAbsolute(reportPath)) throw new Error('Explicit isolated native test paths are required.');
const runDirectory = path.join(directory, randomUUID());
mkdirSync(runDirectory, { recursive: true });
app.setPath('userData', path.join(runDirectory, 'electron-user-data'));
app.setName('Margin native integration test');
app.disableHardwareAcceleration();
const evidence = { passed: false, testId: process.env.MARGIN_NATIVE_TEST_ID, testedAt: new Date().toISOString(), platform: process.platform, electronVersion: process.versions.electron, nodeVersion: process.versions.node, dataDirectory: runDirectory, checks: {} };
let ocr;
const deadline = setTimeout(() => { app.exit(124); }, 80000);
async function run() {
try {
  await app.whenReady();
  assert.equal(process.platform, 'win32');
  assert.equal(typeof safeStorage.isAsyncEncryptionAvailable, 'function');
  assert.equal(await safeStorage.isAsyncEncryptionAvailable(), true);
  evidence.checks.asyncEncryptionAvailable = true;
  const credentialDir = path.join(runDirectory, 'credentials');
  const store = new SecureCredentialStore({ dataDir: credentialDir, safeStorage });
  const syntheticCredential = { version: 1, refreshToken: `SYNTHETIC-TEST-ONLY-${randomUUID()}`, scopes: [], label: 'native smoke test' };
  await store.save(syntheticCredential);
  const encryptedBytes = await readFile(store.file);
  assert.ok(encryptedBytes.length > 0);
  assert.equal(encryptedBytes.includes(Buffer.from(syntheticCredential.refreshToken)), false);
  assert.deepEqual(await store.load(), syntheticCredential);
  evidence.checks.actualDpapiDiskRoundtrip = true;
  evidence.checks.credentialsNotPlaintext = true;
  evidence.encryptedCredentialBytes = encryptedBytes.length;
  const reopenedStore = new SecureCredentialStore({ dataDir: credentialDir, safeStorage });
  assert.deepEqual(await reopenedStore.load(), syntheticCredential);
  evidence.checks.reinstantiatedCredentialStore = true;
  await reopenedStore.delete();
  assert.equal(await reopenedStore.load(), null);
  await assert.rejects(access(reopenedStore.file));
  evidence.checks.logoutDeletesCredentialFile = true;

  const imagePath = path.join(runDirectory, 'synthetic-scan.png');
  const fixtureScript = fileURLToPath(new URL('./ocr-smoke.ps1', import.meta.url));
  const executable = path.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
  await new Promise((resolve, reject) => {
    const child = spawn(executable, ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', fixtureScript, '-OutputPath', imagePath], { windowsHide: true, stdio: ['ignore', 'ignore', 'pipe'] });
    let diagnostic = '';
    child.stderr.on('data', bytes => { if (diagnostic.length < 4000) diagnostic += bytes; });
    child.on('error', reject);
    child.on('close', code => code === 0 ? resolve() : reject(new Error(diagnostic || `Fixture process exited ${code}`)));
  });
  ocr = new OcrService({ dataDir: runDirectory, timeoutMs: 45000 });
  const status = await ocr.status();
  assert.equal(status.available, true, JSON.stringify(status));
  const language = status.languages.some(item => item.tag === 'zh-Hans-CN') ? 'zh-Hans-CN' : status.languages[0].tag;
  const input = { documentId: 'e'.repeat(64), page: 0, png: await readFile(imagePath), language };
  const recognized = await ocr.recognize(input);
  assert.match(recognized.text, /Margin.*local.*OCR.*2026/i);
  assert.ok(recognized.words.length > 8);
  assert.ok(recognized.words.every(word => word.x >= 0 && word.y >= 0 && word.width > 0 && word.height > 0 && word.x + word.width <= recognized.width && word.y + word.height <= recognized.height));
  const cached = await ocr.recognize(input);
  assert.equal(cached.cached, true);
  assert.equal(cached.text, recognized.text);
  const restoredPages = await new OcrService({ dataDir: runDirectory }).cached(input.documentId, language);
  assert.equal(restoredPages.length, 1);
  assert.equal(restoredPages[0].result.text, recognized.text);
  evidence.checks.actualWindowsOcr = true;
  evidence.checks.ocrWordBounds = true;
  evidence.checks.ocrPersistentCache = true;
  evidence.checks.ocrReopenCacheWithoutRaster = true;
  evidence.ocr = { engine: recognized.engine, language, availableLanguages: status.languages, maxDimension: status.maxDimension, width: recognized.width, height: recognized.height, wordCount: recognized.words.length, syntheticRecognizedText: recognized.text };
  evidence.passed = true;
} catch (error) {
  evidence.error = String(error.stack || error.message || error).slice(0, 4000);
} finally {
  if (ocr) await ocr.close().catch(() => {});
  clearTimeout(deadline);
  await mkdir(path.dirname(reportPath), { recursive: true });
  await writeFile(reportPath, `${JSON.stringify(evidence, null, 2)}\n`);
  process.stdout.write(`${JSON.stringify({ passed: evidence.passed, checks: evidence.checks })}\n`);
  app.exit(evidence.passed ? 0 : 1);
}
}
// Do not await app.whenReady() at module top-level: Electron waits for its main
// ES module to finish evaluation before emitting ready.
void run();
