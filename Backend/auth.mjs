import path from 'node:path';
import { readFile } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { makePkce, equalSecret, verifyIdentity, normalizeModels, RESOURCE, SCOPES } from './core.mjs';
import { atomicJson, ClientError } from './conversations.mjs';
import { VolatileCredentialStore } from './credential-store.mjs';

const DISCOVERY_URL = 'https://auth.openai.com/.well-known/openid-configuration';
export class ChatGPTAuth {
  constructor({ dataDir, fetchImpl = fetch, isBusy = () => false, credentialStore = new VolatileCredentialStore() }) {
    this.registrationPath = path.join(dataDir, 'registration.json'); this.fetch = fetchImpl; this.isBusy = isBusy;
    this.catalog = []; this.auth = { status: 'idle', message: '请登录 ChatGPT 以开始讨论' }; this.lastError = null;
    this.credentialStore = credentialStore; this.generation = 0; this.storageQueue = Promise.resolve(); this.retryAt = 0;
  }
  async init() {
    try { this.registration = JSON.parse(await readFile(this.registrationPath, 'utf8')); }
    catch (e) { if (e.code !== 'ENOENT') throw new Error('无法读取本应用的登录注册信息'); this.registration = { hostId: `urn:uuid:${randomUUID()}` }; }
    if (!/^urn:uuid:[0-9a-f-]{36}$/i.test(this.registration.hostId)) throw new Error('本应用的注册标识无效');
    // Public registration stays on disk; refresh credentials are kept only in
    // the native app's Keychain item. Access and ID tokens remain in memory.
    this.registration = { hostId: this.registration.hostId, ...(this.registration.clientId ? { clientId: this.registration.clientId } : {}),
      ...(this.registration.subject ? { subject: this.registration.subject } : {}) };
    await atomicJson(this.registrationPath, this.registration);
  }
  safeError(e) {
    let message = String(e?.message || e).slice(0, 1600);
    for (const secret of [this.session?.accessToken, this.session?.refreshToken, this.session?.idToken, this.savedCredential?.refreshToken,
      this.pendingCredential?.session?.refreshToken, this.pendingCredential?.session?.accessToken, this.pendingCredential?.session?.idToken,
      this.pending?.verifier, this.pending?.state, this.pending?.nonce]) {
      if (secret) message = message.split(secret).join('[已隐藏凭据]');
    }
    return message.replace(/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/g, '[已隐藏令牌]');
  }
  async publicJson(url) {
    const r = await this.fetch(url, { signal: AbortSignal.timeout(20000), redirect: 'error' });
    if (!r.ok) throw new Error(`读取 OpenAI 登录信息失败（HTTP ${r.status}）`);
    return r.json();
  }
  async metadata() {
    if (!this.discovery) {
      const d = await this.publicJson(DISCOVERY_URL);
      if (d.issuer !== 'https://auth.openai.com' || !d.id_token_signing_alg_values_supported?.includes('RS256')) throw new Error('OpenAI 登录配置不受支持');
      for (const key of ['authorization_endpoint', 'token_endpoint', 'jwks_uri', 'revocation_endpoint']) if (d[key]) {
        const u = new URL(d[key]);
        if (u.protocol !== 'https:' || u.hostname !== 'auth.openai.com' || u.username || u.password) throw new Error('OpenAI 登录端点验证失败');
      }
      this.discovery = d;
    }
    return this.discovery;
  }
  async tokenRequest(params) {
    const d = await this.metadata();
    const r = await this.fetch(d.token_endpoint, { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams(params), signal: AbortSignal.timeout(30000), redirect: 'error' });
    const data = await r.json().catch(() => ({}));
    if (!r.ok) {
      const code = typeof data.error === 'string' ? data.error : 'token_error';
      const error = new Error(`登录令牌交换失败（HTTP ${r.status}，${code}）`);
      error.oauthCode = code; error.httpStatus = r.status; throw error;
    }
    if (typeof data.access_token !== 'string' || !data.access_token || !Number.isFinite(data.expires_in)) throw new Error('OpenAI 返回的登录令牌不完整');
    return data;
  }
  status() {
    this.maybeRestore();
    return { authenticated: Boolean(this.session?.accessToken), planEnabled: Boolean(this.session?.accessToken && this.session?.planEnabled),
      account: this.session?.accessToken ? { email: this.session.email, label: this.session.label } : null,
      auth: this.auth, models: this.catalog, lastError: this.lastError };
  }
  storageOperation(operation) {
    const work = this.storageQueue.catch(() => {}).then(operation);
    this.storageQueue = work.catch(() => {}); return work;
  }
  credential(current) {
    return { version: 1, hostId: this.registration.hostId, clientId: current.clientId, subject: this.registration.subject,
      refreshToken: current.refreshToken, scopes: current.scopes, email: current.email, label: current.label };
  }
  async persist(current, generation) {
    if (!this.credentialStore.persistent) return;
    if (!current.refreshToken) throw new Error('登录未返回可保存的续期凭据，请重新授权');
    const value = this.credential(current);
    await this.storageOperation(async () => {
      if (generation !== this.generation) throw new ClientError('登录状态已经改变，请重试', 401);
      await this.credentialStore.save(value);
      // A concurrent logout queues deletion after this save. It cannot leave a
      // just-rotated token behind or delete a newer login's credential.
      if (generation !== this.generation) throw new ClientError('登录状态已经改变，请重试', 401);
      this.savedCredential = value;
    });
  }
  validateSaved(value) {
    return value && value.version === 1 && value.hostId === this.registration.hostId && value.clientId === this.registration.clientId &&
      value.subject === this.registration.subject && typeof value.refreshToken === 'string' && value.refreshToken.length > 0 && value.refreshToken.length < 65536 &&
      Array.isArray(value.scopes) && value.scopes.every(s => typeof s === 'string') && typeof value.email === 'string' && typeof value.label === 'string';
  }
  maybeRestore() {
    if (this.closing || !this.credentialStore.persistent || this.restoreComplete || this.restoring || this.logoutInProgress || this.pending || Date.now() < this.retryAt) return;
    void this.restore().catch(() => {}); // restore records its own user-visible status.
  }
  async restore() {
    if (this.restoring) return this.restoring;
    if (!this.credentialStore.persistent || this.restoreComplete || this.logoutInProgress || this.pending) return;
    const generation = this.generation;
    this.auth = { status: 'restoring', message: '正在恢复已保存的 ChatGPT 登录…' };
    const work = (async () => {
      try {
        if (this.pendingCredential?.generation === generation) {
          await this.refreshSession();
          if (generation !== this.generation) return;
          this.restoreComplete = true; this.auth = { status: 'success', message: '已恢复 ChatGPT 登录' }; this.lastError = null; return;
        }
        const value = await this.storageOperation(() => this.credentialStore.load());
        if (generation !== this.generation) return;
        if (!value) { this.restoreComplete = true; this.auth = { status: 'idle', message: '请登录 ChatGPT 以开始讨论' }; return; }
        if (!this.validateSaved(value)) {
          await this.invalidate('保存的登录与本机注册不匹配，请重新登录', generation); return;
        }
        this.savedCredential = value;
        this.session = { ...value, planEnabled: value.scopes.includes('chatgpt.tokens.use.direct'), expiresAt: 0 };
        await this.refreshSession();
        if (generation !== this.generation) return;
        this.restoreComplete = true; this.auth = { status: 'success', message: '已恢复 ChatGPT 登录' }; this.lastError = null;
      } catch (e) {
        if (generation !== this.generation) return;
        this.lastError = this.safeError(e);
        if (e.oauthCode === 'invalid_grant' || e.oauthCode === 'invalid_token' || e.oauthCode === 'login_required') {
          await this.invalidate('保存的登录已失效，请重新登录 ChatGPT', generation);
        } else {
          this.retryAt = Date.now() + 30000;
          this.auth = { status: 'restore_error', message: `暂时无法恢复登录，已保留钥匙串中的凭据。${this.lastError}` };
        }
      }
    })().finally(() => { if (this.restoring === work) this.restoring = null; });
    this.restoring = work; return work;
  }
  async invalidate(message, expectedGeneration = this.generation) {
    if (expectedGeneration !== this.generation) return;
    this.generation++; this.session = null; this.pending = null; this.pendingCredential = null; this.catalog = []; this.restoreComplete = true;
    this.auth = { status: 'error', message }; this.lastError = message;
    try { await this.storageOperation(() => this.credentialStore.delete()); this.savedCredential = null; }
    catch { this.lastError = `${message}；钥匙串清除失败，请再次退出登录。`; this.auth = { status: 'error', message: this.lastError }; }
  }
  async accessToken() {
    if (this.closing) throw new ClientError('应用正在安全退出，请稍候', 409);
    if (this.restoring) await this.restoring;
    if (!this.session?.planEnabled) throw new ClientError('请先登录并授权使用 ChatGPT 套餐', 401);
    if (this.session.expiresAt > Date.now() + 60000) return this.session.accessToken;
    if (!this.session.refreshToken) throw new ClientError('登录已到期，请重新登录', 401);
    const generation = this.generation;
    try { return await this.refreshSession(); }
    catch (e) {
      if (['invalid_grant', 'invalid_token', 'login_required'].includes(e.oauthCode)) await this.invalidate('保存的登录已失效，请重新登录 ChatGPT', generation);
      throw e;
    }
  }
  async refreshSession() {
    const generation = this.generation;
    if (this.refreshing?.generation === generation) return this.refreshing.promise;
    const entry = { generation };
    entry.promise = (async () => {
      if (this.pendingCredential?.generation === generation) {
        const held = this.pendingCredential.session;
        await this.persist(held, generation);
        if (generation !== this.generation) throw new ClientError('登录状态已经改变，请重试', 401);
        this.session = held; this.pendingCredential = null;
        if (held.expiresAt > Date.now() + 60000) return held.accessToken;
      }
      const current = this.session;
      if (!current?.refreshToken) throw new ClientError('登录已到期，请重新登录', 401);
      const data = await this.tokenRequest({ grant_type: 'refresh_token', client_id: current.clientId, refresh_token: current.refreshToken, resource: RESOURCE });
      if (generation !== this.generation || this.session !== current) {
        await this.revoke(data.refresh_token || current.refreshToken, current.clientId);
        throw new ClientError('登录状态已经改变，请重试', 401);
      }
      const granted = data.scope === undefined ? current.scopes : data.scope.split(/\s+/);
      const next = { ...current, accessToken: data.access_token, refreshToken: data.refresh_token || current.refreshToken,
        idToken: data.id_token || current.idToken, scopes: granted, planEnabled: granted.includes('chatgpt.tokens.use.direct'), expiresAt: Date.now() + data.expires_in * 1000 };
      // The latest rotated token must be durable before any new access token is
      // used. Failed Keychain writes fail closed; there is no plaintext fallback.
      this.pendingCredential = { generation, session: next };
      await this.persist(next, generation);
      if (generation !== this.generation) throw new ClientError('登录状态已经改变，请重试', 401);
      this.session = next; this.pendingCredential = null;
      if (!this.session.planEnabled) throw new ClientError('续期后 ChatGPT 套餐授权不可用，请重新登录', 401);
      return this.session.accessToken;
    })().finally(() => { if (this.refreshing === entry) this.refreshing = null; });
    this.refreshing = entry; return entry.promise;
  }
  async models() {
    const generation = this.generation;
    const token = await this.accessToken();
    if (generation !== this.generation) throw new ClientError('登录状态已经改变，请重试', 401);
    const r = await this.fetch(`${RESOURCE}/models`, { headers: { Authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(30000), redirect: 'error' });
    if (generation !== this.generation) throw new ClientError('登录状态已经改变，请重试', 401);
    if (!r.ok) {
      if (r.status === 401) await this.invalidate('ChatGPT 登录已失效，请重新登录', generation);
      throw new ClientError(`读取账号模型列表失败（HTTP ${r.status}），请稍后重试`, r.status === 401 ? 401 : 502);
    }
    this.catalog = normalizeModels(await r.json());
    if (!this.catalog.length) throw new ClientError('该账号暂未返回可使用的模型', 403);
    return { models: this.catalog, defaultModel: this.catalog[0].id };
  }
  selection(model, effort = 'auto', hasImage = false) {
    const item = this.catalog.find(m => m.id === model);
    if (!item) throw new ClientError('请选择当前账号返回的模型');
    if (!item.efforts.includes(effort)) throw new ClientError('该模型不支持所选推理强度');
    if (hasImage && item.imageSupport === false) throw new ClientError('所选模型不支持图片，请选择其他模型');
    return item;
  }
  async begin(baseUrl) {
    if (this.closing) throw new ClientError('应用正在安全退出，请稍候', 409);
    if (this.isBusy()) throw new ClientError('正在回复问题，请等待或取消后再登录', 409);
    if (this.logoutInProgress) throw new ClientError('正在清除上次登录，请稍候', 409);
    const generation = ++this.generation; this.restoreComplete = true; this.pendingCredential = null;
    const d = await this.metadata(), pkce = makePkce(), isNew = !this.registration.clientId;
    if (generation !== this.generation) throw new ClientError('登录状态已经改变，请重试', 401);
    this.pending = { ...pkce, clientId: this.registration.clientId || 'dynamic_agent_client', isNew,
      redirectUri: `${baseUrl}/auth/callback`, startedAt: Date.now(), generation };
    const params = { client_id: this.pending.clientId, ext_agent_host_id: this.registration.hostId,
      response_type: 'code', redirect_uri: this.pending.redirectUri, scope: SCOPES, resource: RESOURCE,
      state: pkce.state, nonce: pkce.nonce, code_challenge_method: 'S256', code_challenge: pkce.challenge };
    if (isNew) params.agent_name_hint = 'Margin';
    if (this.session && !this.session.planEnabled) params.prompt = 'consent';
    const url = new URL(d.authorization_endpoint);
    for (const [k, v] of Object.entries(params)) url.searchParams.set(k, v);
    this.auth = { status: 'pending', message: '请在 OpenAI 页面完成登录和套餐授权' }; this.lastError = null;
    return { url: url.href };
  }
  async callback(url) {
    if (this.closing) throw new ClientError('应用正在安全退出，请稍候', 409);
    if (this.authorizing) throw new ClientError('登录授权正在完成，请稍候', 409);
    const work = this.completeCallback(url).finally(() => { if (this.authorizing === work) this.authorizing = null; });
    this.authorizing = work; return work;
  }
  async completeCallback(url) {
    const p = this.pending;
    if (!p || Date.now() - p.startedAt > 600000 || !equalSecret(url.searchParams.get('state'), p.state)) throw new ClientError('登录回调已失效，请在阅读器中重新登录');
    this.pending = null;
    try {
      if (url.searchParams.has('error')) throw new Error(`OpenAI 授权未完成（${url.searchParams.get('error').slice(0,80)}）`);
      if (url.searchParams.has('iss') && url.searchParams.get('iss') !== this.discovery.issuer) throw new Error('登录签发方验证失败');
      const code = url.searchParams.get('code'), returnedClient = url.searchParams.get('client_id');
      if (!code || code.length > 16384) throw new Error('登录回调缺少有效授权码');
      if (p.isNew && !returnedClient) throw new Error('首次注册未返回应用标识');
      if (!p.isNew && returnedClient && returnedClient !== p.clientId) throw new Error('返回的应用标识与原注册不一致');
      const clientId = p.isNew ? returnedClient : p.clientId;
      if (clientId === 'dynamic_agent_client' || !/^[A-Za-z0-9_-]{4,200}$/.test(clientId)) throw new Error('应用注册标识无效');
      if (p.isNew) { this.registration.clientId = clientId; await atomicJson(this.registrationPath, this.registration); }
      const data = await this.tokenRequest({ grant_type: 'authorization_code', client_id: clientId, code, code_verifier: p.verifier, redirect_uri: p.redirectUri, resource: RESOURCE });
      const jwks = await this.publicJson(this.discovery.jwks_uri);
      const identity = verifyIdentity(data.id_token, jwks.keys, { issuer: this.discovery.issuer, audience: clientId, nonce: p.nonce, subject: this.registration.subject });
      if (p.generation !== this.generation) { await this.revoke(data.refresh_token, clientId); throw new ClientError('登录状态已经改变，请重试', 401); }
      const granted = typeof data.scope === 'string' ? data.scope.split(/\s+/) : [];
      const next = { clientId, accessToken: data.access_token, refreshToken: data.refresh_token, idToken: data.id_token,
        scopes: granted, planEnabled: granted.includes('chatgpt.tokens.use.direct'), expiresAt: Date.now() + data.expires_in * 1000,
        email: identity.email || '', label: identity.name || 'ChatGPT 账号' };
      this.registration.subject = identity.sub; await atomicJson(this.registrationPath, this.registration); this.catalog = [];
      if (p.generation !== this.generation) throw new ClientError('登录状态已经改变，请重试', 401);
      this.pendingCredential = { generation: p.generation, session: next };
      await this.persist(next, p.generation);
      if (p.generation !== this.generation) throw new ClientError('登录状态已经改变，请重试', 401);
      this.session = next; this.pendingCredential = null; this.restoreComplete = true;
      this.auth = { status: 'success', message: this.session.planEnabled ? (this.credentialStore.persistent ? 'ChatGPT 已连接，登录已安全保存' : 'ChatGPT 已连接') : '已登录，但尚未授予套餐使用权限' }; this.lastError = null;
    } catch (e) {
      if (p.generation === this.generation) {
        this.lastError = this.safeError(e); this.auth = { status: 'error', message: this.lastError };
        if (this.pendingCredential) { this.restoreComplete = false; this.retryAt = Date.now() + 30000; }
      }
      throw e;
    }
  }
  async revoke(token, clientId) {
    if (!token) return true;
    try {
      const d = await this.metadata();
      if (!d.revocation_endpoint) return false;
      for (let attempt = 0; attempt < 2; attempt++) {
        try {
          const r = await this.fetch(d.revocation_endpoint, { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body: new URLSearchParams({ client_id: clientId, token, token_type_hint: 'refresh_token' }), signal: AbortSignal.timeout(8000), redirect: 'error' });
          if (r.ok) return true;
          if (r.status < 500 && r.status !== 429) return false;
        } catch { /* Retry a transient network failure once, with backoff. */ }
        if (attempt === 0) await new Promise(resolve => setTimeout(resolve, 300));
      }
    } catch { /* Local logout still clears its Keychain item. */ }
    return false;
  }
  async logout() {
    if (this.isBusy()) throw new ClientError('正在回复问题，请等待或取消后再退出登录', 409);
    if (this.logoutInProgress) return this.logoutInProgress;
    let current = this.pendingCredential?.session || this.session || this.savedCredential;
    const activeRefresh = this.refreshing?.promise;
    ++this.generation; this.restoreComplete = true;
    this.session = null; this.pending = null; this.pendingCredential = null; this.catalog = []; this.lastError = null;
    const work = (async () => {
      try {
        let unknownRemoteCredential = false;
        await this.storageOperation(async () => {
          if (!current && this.credentialStore.persistent) {
            try {
              const saved = await this.credentialStore.load();
              if (this.validateSaved(saved)) current = saved;
              else if (saved) unknownRemoteCredential = true;
            } catch { unknownRemoteCredential = true; }
          }
          await this.credentialStore.delete();
        });
        this.savedCredential = null;
        const revocationConfirmed = !unknownRemoteCredential && await this.revoke(current?.refreshToken, current?.clientId);
        // Finish any old refresh (including revoking its late rotated token)
        // before allowing another sign-in to begin.
        if (activeRefresh) await activeRefresh.catch(() => {});
        const message = revocationConfirmed ? '已退出登录，并清除钥匙串中的登录凭据' : '已清除本机登录；未能确认远端撤销，可在 ChatGPT 设置中移除此应用授权。';
        this.auth = { status: 'idle', message }; return { loggedOut: true, revocationConfirmed, message };
      } catch (e) {
        this.lastError = `本次登录已断开，但无法清除钥匙串中的登录，请重试退出：${this.safeError(e)}`;
        this.auth = { status: 'error', message: this.lastError }; throw new Error(this.lastError);
      }
    })().finally(() => { if (this.logoutInProgress === work) this.logoutInProgress = null; });
    this.logoutInProgress = work; return work;
  }
  async shutdown() {
    this.closing = true;
    try {
      if (this.restoring) await this.restoring.catch(() => {});
      if (this.refreshing) await this.refreshing.promise.catch(() => {});
      if (this.logoutInProgress) await this.logoutInProgress;
      if (this.authorizing) await this.authorizing.catch(() => {});
      if (this.pendingCredential?.generation === this.generation) {
        await this.persist(this.pendingCredential.session, this.generation);
        this.pendingCredential = null;
      }
      await this.storageQueue;
      this.session = null; this.pending = null;
    } catch (e) {
      this.closing = false;
      this.lastError = `登录尚未安全保存，已取消退出。请解锁钥匙串后重试。${this.safeError(e)}`;
      this.auth = { status: 'shutdown_error', message: this.lastError }; throw e;
    }
  }
}
