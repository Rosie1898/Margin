import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { t, resolveLanguage, fontSample, setSystemLocales } from '../src/renderer/i18n.mjs';

const han = /\p{Script=Han}/u;
const decode = text => text.replace(/\\([nrt'"\\])/g, (_, value) => ({ n: '\n', r: '\r', t: '\t' }[value] ?? value));
function literals(source) {
  return [...source.matchAll(/(['"])((?:\\.|(?!\1)[^\\\r\n])*)\1/g)].map(match => decode(match[2])).filter(text => han.test(text));
}
test('English covers renderer text keys and HTML translation attributes', async () => {
  const source = await readFile(new URL('../src/renderer/app.mjs', import.meta.url), 'utf8');
  const html = await readFile(new URL('../src/renderer/index.html', import.meta.url), 'utf8');
  const keys = new Set(literals(source));
  for (const match of html.matchAll(/data-(?:i18n|placeholder|tip|aria)="([^"]+)"/g)) keys.add(match[1]);
  const missing = [...keys].filter(key => han.test(t(key, 'en')));
  assert.deepEqual(missing, [], `Missing English UI translations:\n${missing.join('\n')}`);
});
test('English covers static Windows native dialogs and service errors', async () => {
  const paths = ['../src/main.mjs', '../src/store.mjs', '../src/services/ocr-service.mjs', '../src/services/secure-credentials.mjs'];
  const keys = new Set();
  for (const file of paths) for (const key of literals(await readFile(new URL(file, import.meta.url), 'utf8'))) keys.add(key);
  const missing = [...keys].filter(key => han.test(t(key, 'en')));
  assert.deepEqual(missing, [], `Missing English native translations:\n${missing.join('\n')}`);
});
test('English covers account and conversation error messages without changing the backend protocol', async () => {
  const files = ['../backend/auth.mjs', '../backend/conversations.mjs', '../backend/core.mjs', '../src/services/chat-service.mjs'];
  const keys = new Set();
  for (const file of files) {
    const source = await readFile(new URL(file, import.meta.url), 'utf8');
    for (const match of source.matchAll(/(?:new (?:Error|ClientError)\(|message:\s*)(['"])((?:\\.|(?!\1)[^\\\r\n])*)\1/g)) {
      const key = decode(match[2]); if (han.test(key)) keys.add(key);
    }
  }
  const missing = [...keys].filter(key => han.test(t(key, 'en')));
  assert.deepEqual(missing, [], `Missing English account translations:\n${missing.join('\n')}`);
});
test('English escaped HTML newlines and numeric labels are translated', () => {
  assert.equal(han.test(t('选择左侧的 PDF，拖选文字后\\n就可以高亮、评论，或开始一段 AI 讨论。', 'en')), false);
  assert.equal(t('第 12 页', 'en'), 'Page 12');
  assert.equal(han.test(t('25 份 PDF · 本地保存', 'en')), false);
});
test('language resolution honors provided system locales and preserves unknown content', () => {
  assert.equal(resolveLanguage('system', ['en-US']), 'en');
  assert.equal(resolveLanguage('system', ['zh-TW']), 'zhHant');
  assert.equal(resolveLanguage('system', ['ja-JP']), 'ja');
  assert.equal(t('用户自己的中文笔记', 'en'), '用户自己的中文笔记');
  assert.equal(t('原文中的一个 字', 'en'), '原文中的一个 字');
  assert.match(fontSample('en').text, /To be/);
  setSystemLocales(['en-US']);
  assert.equal(resolveLanguage('system'), 'en');
  setSystemLocales(['zh-Hans-CN']);
  assert.equal(resolveLanguage('system'), 'zhHans');
  setSystemLocales([]);
});
test('dynamic failures translate without modifying diagnostic paths or user content', () => {
  assert.equal(han.test(t('读取账号模型列表失败（HTTP 429），请稍后重试', 'en')), false);
  assert.equal(han.test(t('上次运行已中断，请重新提交问题', 'en')), false);
  assert.equal(han.test(t('已取消回复；已提交的问题保留在本机，可重新提问。', 'en')), false);
  assert.equal(t('回复未完成：登录已到期，请重新登录', 'en'), 'The reply did not complete: Your sign-in has expired. Sign in again.');
  assert.equal(han.test(t('已退出登录，并清除Windows 凭据存储中的登录凭据', 'en')), false);
  assert.equal(han.test(t('已退出登录，并清除Windows 凭据存储中的登录凭据', 'fr')), false);
  assert.equal(han.test(t('已退出登录，并清除Windows 凭据存储中的登录凭据', 'zhHans')), true);
  assert.equal(han.test(t('暂时无法恢复登录，已保留Windows 凭据存储中的凭据。登录已到期，请重新登录', 'en')), false);
  assert.equal(t('文件夹暂时无法读取：{0}', 'en', ['D:\\论文\\原文.pdf']), 'The folder is temporarily unavailable: D:\\论文\\原文.pdf');
  assert.equal(han.test(t('Windows 凭据加密失败。', 'fr')), false); // Missing translation falls back to English.
});
