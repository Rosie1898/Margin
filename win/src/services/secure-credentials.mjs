import path from 'node:path';
import { mkdir, open, readFile, rename, unlink, stat } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';

/** Electron safeStorage uses the current Windows user's DPAPI key. No plaintext fallback. */
export class SecureCredentialStore {
  persistent = true;
  constructor({ dataDir, safeStorage }) {
    this.file = path.join(dataDir, 'credentials.dpapi');
    this.safeStorage = safeStorage;
    this.asyncStorage = Boolean(safeStorage?.isAsyncEncryptionAvailable && safeStorage?.encryptStringAsync && safeStorage?.decryptStringAsync);
    this.queue = Promise.resolve();
  }
  async assertAvailable() {
    const available = this.asyncStorage ? await this.safeStorage.isAsyncEncryptionAvailable() : this.safeStorage?.isEncryptionAvailable();
    if (!available) throw new Error('Windows 凭据保护暂不可用，请在本机用户登录后重试。');
    if (process.platform === 'linux' && this.safeStorage.getSelectedStorageBackend?.() === 'basic_text') throw new Error('系统未提供安全的凭据存储，已拒绝明文保存。');
  }
  serial(operation) {
    const task = this.queue.catch(() => {}).then(operation);
    this.queue = task.catch(() => {});
    return task;
  }
  load() {
    return this.serial(async () => {
      let data;
      try {
        if ((await stat(this.file)).size > 262144) throw new Error('invalid');
        data = await readFile(this.file);
      } catch (error) {
        if (error.code === 'ENOENT') return null;
        throw new Error('无法读取已保存的 Windows 登录凭据；文件已保留。');
      }
      await this.assertAvailable();
      try {
        const decrypted = this.asyncStorage ? await this.safeStorage.decryptStringAsync(data) : { result: this.safeStorage.decryptString(data) };
        const value = JSON.parse(decrypted.result);
        if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('invalid');
        if (decrypted.shouldReEncrypt) await this.writeEncrypted(JSON.stringify(value));
        return value;
      } catch {
        throw new Error('无法解密已保存的登录凭据；请使用原 Windows 用户，或退出登录后重新授权。');
      }
    });
  }
  save(value) {
    return this.serial(async () => {
      await this.assertAvailable();
      const serialized = JSON.stringify(value);
      if (serialized.length > 131072) throw new Error('登录凭据过大，无法保存。');
      await this.writeEncrypted(serialized);
    });
  }
  async writeEncrypted(serialized) {
      const encrypted = this.asyncStorage ? await this.safeStorage.encryptStringAsync(serialized) : this.safeStorage.encryptString(serialized);
      if (!Buffer.isBuffer(encrypted) || encrypted.length === 0) throw new Error('Windows 凭据加密失败。');
      await mkdir(path.dirname(this.file), { recursive: true });
      const temporary = `${this.file}.${randomUUID()}.tmp`;
      try {
        const handle = await open(temporary, 'wx', 0o600);
        try { await handle.writeFile(encrypted); await handle.sync(); } finally { await handle.close(); }
        await rename(temporary, this.file);
      } catch {
        throw new Error('Windows 登录凭据尚未安全保存，请检查磁盘空间和数据目录权限。');
      } finally { await unlink(temporary).catch(() => {}); }
  }
  delete() { return this.serial(() => unlink(this.file).catch(error => { if (error.code !== 'ENOENT') throw new Error('无法清除 Windows 登录凭据，请重试退出登录。'); })); }
}
