import { _electron as electron } from 'playwright';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import { mkdir, mkdtemp, writeFile } from 'node:fs/promises';
import { LibraryStore } from '../src/store.mjs';

const root = path.resolve(fileURLToPath(new URL('../', import.meta.url)));
const output = path.join(root, 'test-results');
await mkdir(output, { recursive: true });
const dataDir = await mkdtemp(path.join(output, 'localization-'));
const store = new LibraryStore(dataDir); await store.init(); await store.saveSettings({ language: 'en' }); await store.close();
const require = createRequire(import.meta.url), env = { ...process.env, LEAF_DATA_DIR: dataDir, TEMP: path.join(root, '.cache/tmp'), TMP: path.join(root, '.cache/tmp') };
delete env.ELECTRON_RUN_AS_NODE;
const evidence = { passed: false, testedAt: new Date().toISOString(), dataDir, checks: [] };
let instance;
const deadline = setTimeout(() => { instance?.process().kill(); }, 80000);
try {
  instance = await electron.launch({ executablePath: require('electron'), args: [root], env, timeout: 30000 });
  const page = await instance.firstWindow(); page.setDefaultTimeout(15000);
  await page.waitForFunction(() => document.querySelector('#choose-folder')?.textContent.includes('Choose'));
  const bootstrap = await page.evaluate(() => window.margin.bootstrap());
  assert.ok(bootstrap.systemLocale);
  evidence.systemLocale = bootstrap.systemLocale;
  const initialText = await page.locator('#workspace').innerText();
  assert.equal(/\p{Script=Han}/u.test(initialText), false, initialText);
  evidence.checks.push('English empty reader, folder, account, and notes contain no Chinese UI text');
  const readMenu = () => instance.evaluate(({ Menu }) => {
    const labels = [];
    const visit = menu => { for (const item of menu.items) { if (item.label) labels.push(item.label); if (item.submenu) visit(item.submenu); } };
    visit(Menu.getApplicationMenu()); return labels;
  });
  const englishMenu = await readMenu();
  assert.ok(englishMenu.includes('File') && englishMenu.includes('Edit'));
  assert.equal(englishMenu.some(label => /\p{Script=Han}/u.test(label)), false);
  await page.evaluate(() => window.margin.saveSettings({ language: 'zhHans' }));
  assert.ok((await readMenu()).includes('文件'));
  await page.evaluate(() => window.margin.saveSettings({ language: 'en' }));
  assert.deepEqual(await readMenu(), englishMenu);
  evidence.checks.push('Native application menus update immediately when the saved language changes');
  evidence.nativeMenu = englishMenu;

  // Capture the app-owned dialog text without opening pickers or downloading a sample.
  await instance.evaluate(({ dialog }) => {
    globalThis.marginDialogProbe = { captured: [], open: dialog.showOpenDialog, message: dialog.showMessageBox };
    dialog.showOpenDialog = async (...args) => { globalThis.marginDialogProbe.captured.push(args.at(-1)); return { canceled: true, filePaths: [] }; };
    dialog.showMessageBox = async (...args) => { globalThis.marginDialogProbe.captured.push(args.at(-1)); return { response: 1, checkboxChecked: false }; };
  });
  await page.evaluate(async () => { await window.margin.chooseFolder(); await window.margin.chooseFile(); await window.margin.chooseBackground(); await window.margin.sample(); });
  const dialogs = await instance.evaluate(({ dialog }) => {
    const probe = globalThis.marginDialogProbe;
    dialog.showOpenDialog = probe.open; dialog.showMessageBox = probe.message;
    return probe.captured;
  });
  assert.equal(dialogs.length, 4);
  assert.equal(/\p{Script=Han}/u.test(JSON.stringify(dialogs)), false);
  assert.deepEqual(dialogs[3].buttons, ['Download', 'Cancel']);
  evidence.dialogs = dialogs;
  evidence.checks.push('App-owned native folder, PDF, image, and sample-dialog text is English');
  const invalid = await page.evaluate(async () => { try { await window.margin.openDocument('C:\\not-selected.pdf'); } catch (error) { return error.message; } });
  assert.equal(/\p{Script=Han}/u.test(invalid), false);
  assert.match(invalid, /folder or file picker/);
  evidence.checks.push('Native validation errors use the selected language');
  evidence.passed = true;
} catch (error) { evidence.error = String(error.stack || error).slice(0, 6000); }
finally {
  clearTimeout(deadline);
  if (instance) await instance.close().catch(() => instance.process().kill());
  const reportPath = path.join(output, 'localization-native-result.json');
  await writeFile(reportPath, `${JSON.stringify(evidence, null, 2)}\n`);
  console.log(JSON.stringify({ passed: evidence.passed, checks: evidence.checks, reportPath, error: evidence.error }, null, 2));
  if (!evidence.passed) process.exitCode = 1;
}
