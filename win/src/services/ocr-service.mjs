import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { mkdir, readFile, writeFile, rename, unlink, readdir, stat } from 'node:fs/promises';

const VERSION = 1;
const HASH = /^[a-f0-9]{64}$/i;
const PNG_SIGNATURE = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
const nativeScript = fileURLToPath(new URL('../../native/windows-ocr.ps1', import.meta.url)).replace('app.asar\\', 'app.asar.unpacked\\').replace('app.asar/', 'app.asar.unpacked/');
const LANGUAGE = /^[a-zA-Z]{2,3}(?:-[a-zA-Z0-9]{2,8}){0,3}$/;
const MAX_CACHE_FILE = 12 * 1024 * 1024;
const MAX_CACHE_TOTAL = 64 * 1024 * 1024;

function validateCache(value, documentId, language, expectedPage) {
  if (!value || value.version !== VERSION || value.documentId !== documentId.toLowerCase() || !HASH.test(value.rasterHash || '') || value.languagePreference !== language || value.page !== expectedPage || !Number.isInteger(value.page) || value.page < 0 || value.page > 100000) return false;
  if (typeof value.text !== 'string' || value.text.length > 2_000_000 || !Number.isFinite(value.width) || !Number.isFinite(value.height) || value.width < 1 || value.height < 1 || value.width > 16000 || value.height > 16000 || !Array.isArray(value.words) || value.words.length > 200000) return false;
  return value.words.every(word => word && typeof word.text === 'string' && word.text.length < 16000 && ['x', 'y', 'width', 'height'].every(key => Number.isFinite(word[key])) && word.x >= 0 && word.y >= 0 && word.width > 0 && word.height > 0 && word.x + word.width <= value.width + 1 && word.y + word.height <= value.height + 1 && (word.line === undefined || Number.isInteger(word.line) && word.line >= 0));
}

export function validateOcrInput({ documentId, page, png, language }) {
  if (!HASH.test(documentId || '') || !Number.isInteger(page) || page < 0 || page > 100000) throw new Error('OCR 文档或页码无效。');
  if (!Buffer.isBuffer(png) || png.length < 33 || png.length > 32 * 1024 * 1024 || !png.subarray(0, 8).equals(PNG_SIGNATURE)) throw new Error('OCR 需要有效的 PNG 页面图像（不超过 32 MB）。');
  const width = png.readUInt32BE(16), height = png.readUInt32BE(20);
  if (!width || !height || width > 16000 || height > 16000 || width * height > 64_000_000) throw new Error('OCR 页面图像尺寸过大。');
  if (language && (typeof language !== 'string' || !LANGUAGE.test(language))) throw new Error('OCR 语言代码无效。');
  return { width, height };
}

export class OcrService {
  constructor({ dataDir, scriptPath = nativeScript, timeoutMs = 90000 } = {}) {
    this.dataDir = dataDir;
    this.scriptPath = scriptPath;
    this.timeoutMs = timeoutMs;
    this.generation = 0;
    this.queue = Promise.resolve();
    this.active = new Set();
    this.statusPromise = null;
  }
  runWorker(request) {
    if (process.platform !== 'win32') return Promise.reject(new Error('本地 OCR 需要 Windows 10 或 Windows 11。'));
    const executable = path.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
    return new Promise((resolve, reject) => {
      const child = spawn(executable, ['-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', this.scriptPath], { windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] });
      let markDone;
      const done = new Promise(resolveDone => { markDone = resolveDone; });
      const entry = { child, cancelled: false, action: request.action, done };
      this.active.add(entry);
      let output = '', diagnostic = '', timedOut = false, overflow = false;
      const timer = setTimeout(() => { timedOut = true; child.kill(); }, this.timeoutMs);
      child.stdout.setEncoding('utf8'); child.stderr.setEncoding('utf8');
      child.stdout.on('data', text => { output += text; if (output.length > 12 * 1024 * 1024) { overflow = true; child.kill(); } });
      child.stderr.on('data', text => { if (diagnostic.length < 4000) diagnostic += text; });
      child.stdin.on('error', () => {});
      child.on('error', () => { clearTimeout(timer); this.active.delete(entry); markDone(); reject(new Error('无法启动 Windows 本地 OCR，请确认 Windows PowerShell 可用。')); });
      child.on('close', code => {
        clearTimeout(timer); this.active.delete(entry); markDone();
        if (entry.cancelled) return reject(new Error('OCR 已取消。'));
        if (timedOut) return reject(new Error('本页 OCR 超时，请重试或降低页面分辨率。'));
        if (overflow) return reject(new Error('OCR 返回内容过大。'));
        let result;
        try { result = JSON.parse(output.replace(/^\uFEFF/, '').trim()); } catch { return reject(new Error('Windows OCR 未能启动；请确认 Windows PowerShell 5.1 和系统 OCR 语言包可用。')); }
        if (code !== 0 || result.error) {
          if (result.error?.includes('OCR_LANGUAGE_NOT_INSTALLED')) return reject(new Error('所选 OCR 语言未安装。请在 Windows 设置 → 时间和语言 → 语言和区域中安装相应语言的 OCR 功能。'));
          return reject(new Error(`Windows 本地 OCR 未完成：${String(result.error || diagnostic || code).slice(0, 600)}`));
        }
        resolve(result);
      });
      child.stdin.end(JSON.stringify(request));
    });
  }
  async status({ refresh = false } = {}) {
    if (refresh) this.statusPromise = null;
    if (!this.statusPromise) this.statusPromise = this.runWorker({ action: 'status' }).catch(error => ({ available: false, languages: [], error: error.message, engine: 'Windows.Media.Ocr' }));
    return this.statusPromise;
  }
  /** Restore previously recognized pages without rendering them again. */
  async cached(documentId, language) {
    if (!HASH.test(documentId || '') || language && (typeof language !== 'string' || !LANGUAGE.test(language))) throw new Error('OCR 缓存请求无效。');
    const preference = language || 'auto';
    const directory = path.join(this.dataDir, 'OCR', documentId.toLowerCase());
    let entries;
    try { entries = await readdir(directory, { withFileTypes: true }); }
    catch (error) { if (error.code === 'ENOENT') return []; throw error; }
    const results = [];
    let total = 0;
    for (const entry of entries) {
      if (!entry.isFile() || !entry.name.endsWith(`-${preference}.json`)) continue;
      const match = /^page-(\d+)-/.exec(entry.name);
      if (!match) continue;
      const page = Number(match[1]);
      if (entry.name !== `page-${page}-${preference}.json`) continue;
      const file = path.join(directory, entry.name);
      try {
        const size = (await stat(file)).size;
        if (size > MAX_CACHE_FILE) continue;
        total += size;
        if (total > MAX_CACHE_TOTAL || results.length >= 5000) throw new Error('OCR 缓存过大，无法一次载入全部页面。');
        const value = JSON.parse(await readFile(file, 'utf8'));
        if (validateCache(value, documentId, preference, page)) results.push({ page, result: { ...value, cached: true } });
      } catch (error) {
        if (error.message === 'OCR 缓存过大，无法一次载入全部页面。') throw error;
        // Malformed, stale or concurrently replaced entries are regenerated on visit.
      }
    }
    return results.sort((left, right) => left.page - right.page);
  }
  recognize(input) {
    const png = Buffer.isBuffer(input.png) ? input.png : Buffer.from(input.png || []);
    validateOcrInput({ ...input, png });
    const generation = this.generation;
    const task = this.queue.catch(() => {}).then(async () => {
      if (generation !== this.generation) throw new Error('OCR 已取消。');
      const rasterHash = createHash('sha256').update(png).digest('hex');
      const language = input.language || 'auto';
      const directory = path.join(this.dataDir, 'OCR', input.documentId.toLowerCase());
      const cacheFile = path.join(directory, `page-${input.page}-${language}.json`);
      try {
        if ((await stat(cacheFile)).size > MAX_CACHE_FILE) throw new Error('Oversized cache');
        const cached = JSON.parse(await readFile(cacheFile, 'utf8'));
        if (validateCache(cached, input.documentId, language, input.page) && cached.rasterHash === rasterHash) return { ...cached, cached: true };
      } catch { /* A stale or interrupted cache is safe to regenerate. */ }
      await mkdir(directory, { recursive: true });
      const temporaryImage = path.join(directory, `.ocr-${randomUUID()}.png`);
      const temporaryCache = `${cacheFile}.${randomUUID()}.tmp`;
      try {
        await writeFile(temporaryImage, png, { mode: 0o600, flag: 'wx' });
        if (generation !== this.generation) throw new Error('OCR 已取消。');
        const result = await this.runWorker({ action: 'recognize', path: temporaryImage, language: input.language || null });
        if (generation !== this.generation) throw new Error('OCR 已取消。');
        const value = { ...result, version: VERSION, rasterHash, languagePreference: language, documentId: input.documentId.toLowerCase(), page: input.page, recognizedAt: new Date().toISOString() };
        await writeFile(temporaryCache, JSON.stringify(value), { mode: 0o600, flag: 'wx' });
        if (generation !== this.generation) throw new Error('OCR 已取消。');
        await rename(temporaryCache, cacheFile);
        if (generation !== this.generation) throw new Error('OCR 已取消。');
        return { ...value, cached: false };
      } finally {
        await Promise.all([unlink(temporaryImage).catch(() => {}), unlink(temporaryCache).catch(() => {})]);
      }
    });
    this.queue = task.catch(() => {});
    return task;
  }
  cancel() {
    this.generation++;
    // Changing documents cancels recognition, but the capability probe belongs
    // to the application. Killing it here would cache "OCR unavailable" at startup.
    for (const entry of this.active) if (entry.action === 'recognize') { entry.cancelled = true; entry.child.kill(); }
    return { cancelled: true };
  }
  async close() {
    this.cancel();
    const remaining = [...this.active];
    for (const entry of remaining) { entry.cancelled = true; entry.child.kill(); }
    await Promise.all([this.queue, ...remaining.map(entry => entry.done)]);
  }
}
