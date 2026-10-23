import http from 'node:http';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { randomBytes } from 'node:crypto';
import { mkdir, chmod, unlink } from 'node:fs/promises';
import { equalSecret, runResponse } from './core.mjs';
import { ChatGPTAuth } from './auth.mjs';
import { ParentKeychainStore } from './credential-store.mjs';
import { ConversationService, atomicJson, ClientError } from './conversations.mjs';

const BODY_LIMIT = 5 * 1024 * 1024;
function json(res, status, value) { res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' }); res.end(JSON.stringify(value)); }
function html(res, status, title, text) {
  const escape = s => String(s).replace(/[&<>"']/g, c => ({ '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;' }[c]));
  res.writeHead(status, { 'Content-Type': 'text/html; charset=utf-8' });
  res.end(`<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="referrer" content="no-referrer"><title>${escape(title)}</title><body><h1>${escape(title)}</h1><p>${escape(text)}</p></body></html>`);
}
async function bodyJson(req) {
  if (Number(req.headers['content-length'] || 0) > BODY_LIMIT) throw new ClientError('请求内容过大，请缩小图片区域', 413);
  let bytes = 0; const chunks = [];
  for await (const chunk of req) { bytes += chunk.length; if (bytes > BODY_LIMIT) throw new ClientError('请求内容过大，请缩小图片区域', 413); chunks.push(chunk); }
  let data; try { data = chunks.length ? JSON.parse(Buffer.concat(chunks).toString('utf8')) : {}; } catch { throw new ClientError('请求格式无效'); }
  if (!data || typeof data !== 'object' || Array.isArray(data)) throw new ClientError('请求格式无效');
  return data;
}

export async function createReaderServer({ dataDir, port = 0, fetchImpl = fetch, credentialStore }) {
  if (!dataDir || !path.isAbsolute(dataDir)) throw new Error('LEAF_DATA_DIR 必须指定本应用的绝对数据路径');
  await mkdir(dataDir, { recursive: true, mode: 0o700 }); await chmod(dataDir, 0o700);
  const csrfToken = randomBytes(32).toString('base64url'); let baseUrl;
  const auth = new ChatGPTAuth({ dataDir, fetchImpl, credentialStore, isBusy: () => chats.running.size > 0 });
  const chats = new ConversationService({ dataDir, safeError: e => auth.safeError(e), onError: message => { auth.lastError = message; },
    execute: async options => {
      const generation = auth.generation;
      try {
        const token = await auth.accessToken();
        if (generation !== auth.generation) throw new ClientError('登录状态已经改变，请重试', 401);
        return await runResponse({ ...options, token, fetchImpl });
      } catch (e) { if (e.evidence?.httpStatus === 401 && generation !== undefined) await auth.invalidate('ChatGPT 登录已失效，请重新登录', generation); throw e; }
    } });
  await auth.init(); await chats.init();
  const server = http.createServer(async (req, res) => {
    res.setHeader('Cache-Control', 'no-store'); res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Referrer-Policy', 'no-referrer'); res.setHeader('X-Frame-Options', 'DENY');
    res.setHeader('Content-Security-Policy', "default-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'");
    if (!baseUrl || req.headers.host !== new URL(baseUrl).host) return json(res, 403, { error: '本机地址校验失败' });
    let url; try { url = new URL(req.url, baseUrl); } catch { return json(res, 400, { error: '地址无效' }); }
    try {
      if (url.pathname.startsWith('/api/')) {
        if (req.headers['sec-fetch-site'] === 'cross-site' || (req.headers.origin && req.headers.origin !== baseUrl)) return json(res, 403, { error: '已拒绝其他网站访问阅读器数据' });
        if (req.method === 'POST' && (!equalSecret(req.headers['x-csrf-token'], csrfToken) || !req.headers['content-type']?.startsWith('application/json'))) return json(res, 403, { error: '请求校验失败，请重新打开阅读器' });
      }
      if (req.method === 'GET' && url.pathname === '/api/status') return json(res, 200, { ...auth.status(), csrfToken });
      if (req.method === 'GET' && url.pathname === '/api/models') return json(res, 200, await auth.models());
      if (req.method === 'GET' && url.pathname === '/api/chat/thread') return json(res, 200, await chats.thread(url.searchParams.get('id')));
      if (req.method === 'GET' && url.pathname === '/api/chat/status') return json(res, 200, chats.status(url.searchParams.get('id')));
      if (req.method === 'POST' && url.pathname === '/api/auth/start') { await bodyJson(req); return json(res, 200, await auth.begin(baseUrl)); }
      if (req.method === 'POST' && url.pathname === '/api/logout') { await bodyJson(req); return json(res, 200, await auth.logout()); }
      if (req.method === 'POST' && url.pathname === '/api/chat/start') {
        if (!auth.session?.planEnabled) throw new ClientError('请先登录并授权 ChatGPT 套餐', 401);
        const data = await bodyJson(req); auth.selection(data.model, data.effort || 'auto', Boolean(data.imageDataUrl)); auth.lastError = null;
        return json(res, 202, { jobId: await chats.start(data) });
      }
      if (req.method === 'POST' && url.pathname === '/api/chat/cancel') return json(res, 200, chats.cancel((await bodyJson(req)).jobId));
      if (req.method === 'GET' && url.pathname === '/auth/callback') {
        // Unrelated callbacks never consume a legitimate pending authorization.
        if (!auth.pending || !equalSecret(url.searchParams.get('state'), auth.pending.state)) return html(res, 400, '无效的登录回调', '请从 Margin重新发起登录。');
        try { await auth.callback(url); return html(res, 200, 'ChatGPT 授权已完成', '请返回 Margin。可以关闭这个标签页。'); }
        catch (e) { return html(res, 400, 'ChatGPT 授权未完成', auth.safeError(e)); }
      }
      if (req.method === 'GET' && url.pathname === '/') return html(res, 200, 'Margin', '本机连接服务正在运行。请在 Mac 阅读器窗口中使用。');
      return json(res, 404, { error: '未找到该功能' });
    } catch (e) { const message = auth.safeError(e); auth.lastError = message; return json(res, e.status || 500, { error: message }); }
  });
  server.headersTimeout = 15000; server.requestTimeout = 30000;
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(port, '127.0.0.1', resolve); });
  baseUrl = `http://127.0.0.1:${server.address().port}`;
  await atomicJson(path.join(dataDir, 'runtime.json'), { baseUrl });
  return { baseUrl, server, auth, chats, async close() {
    chats.cancelAll(); await auth.shutdown();
    await new Promise(resolve => {
      server.close(resolve);
      // OAuth refresh/authorization and secure writes have drained above.
      // Remaining local keep-alive sockets must not delay process exit.
      server.closeAllConnections();
    });
    for (let n = 0; n < 50 && chats.running.size; n++) await new Promise(resolve => setTimeout(resolve, 20));
    await unlink(path.join(dataDir, 'runtime.json')).catch(() => {});
  } };
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  try {
    const credentialStore = process.env.LEAF_KEYCHAIN_BRIDGE === '1' ? new ParentKeychainStore() : undefined;
    const app = await createReaderServer({ dataDir: process.env.LEAF_DATA_DIR, port: Number(process.env.PORT || 0), credentialStore });
    process.stdout.write(JSON.stringify({ baseUrl: app.baseUrl }) + '\n');
    let closing = false;
    const shutdown = async () => {
      if (closing) return; closing = true;
      try { await app.close(); process.exit(0); }
      catch {
        closing = false; // Keep the secure bridge alive if saving rotation failed.
        process.stdout.write(JSON.stringify({ channel: 'leaf.lifecycle.v1', event: 'shutdown_error', message: app.auth.lastError || '登录尚未安全保存，请重试退出。' }) + '\n');
      }
    };
    process.on('SIGTERM', shutdown); process.on('SIGINT', shutdown);
    const parentPid = Number(process.env.LEAF_PARENT_PID);
    if (Number.isInteger(parentPid) && parentPid > 1) setInterval(() => {
      try { process.kill(parentPid, 0); } catch (e) { if (e.code === 'ESRCH') void shutdown(); }
    }, 2000).unref();
    if (process.env.LEAF_EXIT_ON_STDIN_EOF === '1') { process.stdin.resume(); process.stdin.on('end', shutdown); }
  } catch (e) { process.stderr.write(`Leaf 本机服务无法启动：${String(e.message).slice(0, 500)}\n`); process.exitCode = 1; }
}
