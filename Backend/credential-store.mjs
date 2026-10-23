import { randomUUID } from 'node:crypto';

export class VolatileCredentialStore {
  persistent = false;
  async load() { return null; }
  async save() {}
  async delete() {}
}

// Only the native parent owns the app-specific Keychain item. Tokens travel on
// inherited anonymous pipes, never on HTTP, argv, environment variables or disk.
export class ParentKeychainStore {
  persistent = true;
  constructor({ input = process.stdin, output = process.stdout, timeoutMs = 60000 } = {}) {
    this.input = input; this.output = output; this.timeoutMs = timeoutMs; this.pending = new Map(); this.buffer = '';
    input.setEncoding('utf8');
    input.on('data', chunk => this.receive(chunk));
    input.on('end', () => this.failAll(new Error('应用已关闭，无法访问钥匙串')));
    input.on('error', () => this.failAll(new Error('钥匙串连接中断')));
    input.resume();
  }
  failAll(error) { for (const p of this.pending.values()) { clearTimeout(p.timer); p.reject(error); } this.pending.clear(); }
  receive(chunk) {
    this.buffer += chunk;
    if (this.buffer.length > 262144) { this.buffer = ''; this.failAll(new Error('钥匙串返回的数据过大')); return; }
    let newline;
    while ((newline = this.buffer.indexOf('\n')) >= 0) {
      const line = this.buffer.slice(0, newline); this.buffer = this.buffer.slice(newline + 1);
      let value; try { value = JSON.parse(line); } catch { continue; }
      if (value.channel !== 'leaf.keychain.v1' || typeof value.id !== 'string') continue;
      const p = this.pending.get(value.id); if (!p) continue;
      this.pending.delete(value.id); clearTimeout(p.timer);
      if (value.ok === true) p.resolve(value.credential ?? null);
      else p.reject(new Error(typeof value.error === 'string' ? value.error.slice(0, 300) : '钥匙串操作未完成'));
    }
  }
  request(action, credential) {
    const id = randomUUID();
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.pending.delete(id); reject(new Error('钥匙串访问超时，请解锁 Mac 后重试')); }, this.timeoutMs);
      this.pending.set(id, { resolve, reject, timer });
      this.output.write(JSON.stringify({ channel: 'leaf.keychain.v1', id, action, ...(credential ? { credential } : {}) }) + '\n', error => {
        if (error && this.pending.has(id)) { clearTimeout(timer); this.pending.delete(id); reject(new Error('无法连接应用钥匙串')); }
      });
    });
  }
  load() { return this.request('load'); }
  save(value) { return this.request('save', value); }
  delete() { return this.request('delete'); }
}
