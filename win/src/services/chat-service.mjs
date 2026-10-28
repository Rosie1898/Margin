import { createReaderServer } from '../../backend/server.mjs';
import { SecureCredentialStore } from './secure-credentials.mjs';

const GET_ROUTES = new Set(['/api/status', '/api/models', '/api/chat/thread', '/api/chat/status']);
const POST_ROUTES = new Set(['/api/auth/start', '/api/logout', '/api/chat/start', '/api/chat/cancel']);
const windowsMessage = text => typeof text === 'string' ? text.replaceAll('钥匙串', 'Windows 凭据存储').replaceAll('解锁 Mac', '登录 Windows') : text;

export function validateChatRoute(route, hasBody) {
  if (typeof route !== 'string' || route.length > 256 || !route.startsWith('/api/')) throw new Error('不支持的本机服务请求。');
  const url = new URL(route, 'http://127.0.0.1');
  if (url.origin !== 'http://127.0.0.1' || url.hash || !(hasBody ? POST_ROUTES : GET_ROUTES).has(url.pathname)) throw new Error('不支持的本机服务请求。');
  if (url.search && !['/api/chat/thread', '/api/chat/status'].includes(url.pathname)) throw new Error('请求参数无效。');
  if (url.search && (Array.from(url.searchParams.keys()).some(key => key !== 'id') || url.searchParams.getAll('id').length !== 1)) throw new Error('请求参数无效。');
  return `${url.pathname}${url.search}`;
}

export async function createChatService({ dataDir, safeStorage, openExternal, fetchImpl }) {
  const credentialStore = new SecureCredentialStore({ dataDir, safeStorage });
  const backend = await createReaderServer({ dataDir, credentialStore, ...(fetchImpl ? { fetchImpl } : {}) });
  let closed = false;
  let closing;
  const csrfToken = (await fetch(`${backend.baseUrl}/api/status`).then(response => response.json())).csrfToken;
  return {
    async request(route, body) {
      if (closed || closing) throw new Error('本机服务正在关闭。');
      const normalized = validateChatRoute(route, body !== undefined);
      const encoded = body === undefined ? undefined : JSON.stringify(body);
      if (encoded && Buffer.byteLength(encoded) > 5 * 1024 * 1024) throw new Error('请求内容过大，请缩小参考范围。');
      const response = await fetch(`${backend.baseUrl}${normalized}`, {
        method: body === undefined ? 'GET' : 'POST',
        headers: body === undefined ? {} : { 'Content-Type': 'application/json', 'X-CSRF-Token': csrfToken },
        body: encoded,
        signal: AbortSignal.timeout(45000),
        redirect: 'error',
      });
      const result = await response.json();
      if (!response.ok) throw new Error(windowsMessage(result.error) || `本机服务错误（HTTP ${response.status}）`);
      if (normalized === '/api/auth/start') {
        const url = new URL(result.url);
        if (url.protocol !== 'https:' || url.hostname !== 'auth.openai.com' || url.username || url.password || url.port) throw new Error('已拒绝无效的 OpenAI 登录地址。');
        await openExternal(url.href);
        return { opened: true };
      }
      // The renderer never needs the local server's request credential.
      if (normalized === '/api/status') {
        const { csrfToken: ignored, ...status } = result;
        if (status.auth?.message) status.auth.message = windowsMessage(status.auth.message);
        if (status.lastError) status.lastError = windowsMessage(status.lastError);
        return status;
      }
      return result;
    },
    async close() {
      if (closed) return;
      if (!closing) closing = backend.close().then(() => { closed = true; }).finally(() => { closing = undefined; });
      await closing;
    },
  };
}
