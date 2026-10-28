import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';

const root = fileURLToPath(new URL('../', import.meta.url));
const directory = path.join(root, 'test-results', 'native-electron');
const reportPath = path.join(root, 'test-results', 'native-electron-result.json');
await mkdir(directory, { recursive: true });
const testId = randomUUID();
const environment = { ...process.env, MARGIN_NATIVE_TEST_DIR: directory, MARGIN_NATIVE_TEST_REPORT: reportPath, MARGIN_NATIVE_TEST_ID: testId };
delete environment.ELECTRON_RUN_AS_NODE;
delete environment.NODE_OPTIONS;
const executable = path.join(root, 'node_modules', 'electron', 'dist', 'electron.exe');
const entry = path.join(root, 'tests', 'electron-native-entry.mjs');
const start = Date.now();
let standardError = '', standardOutput = '', timedOut = false;
const result = await new Promise(resolve => {
  const child = spawn(executable, [entry], { cwd: root, env: environment, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
  const timeout = setTimeout(() => { timedOut = true; child.kill(); }, 90000);
  child.stdout.on('data', bytes => { if (standardOutput.length < 16000) standardOutput += bytes.toString('utf8').slice(0, 16000 - standardOutput.length); });
  child.stderr.on('data', bytes => { if (standardError.length < 16000) standardError += bytes.toString('utf8').slice(0, 16000 - standardError.length); });
  child.on('error', error => { clearTimeout(timeout); resolve({ exitCode: null, launchError: error.message }); });
  child.on('close', exitCode => { clearTimeout(timeout); resolve({ exitCode }); });
});
let evidence;
try {
  evidence = JSON.parse(await readFile(reportPath, 'utf8'));
  if (evidence.testId !== testId) throw new Error('Previous report is not evidence for this run.');
}
catch { evidence = { passed: false, error: 'Electron did not create a native integration report.' }; }
const report = { ...evidence, driver: { ...result, elapsedMs: Date.now() - start, timedOut, standardOutput, standardError } };
if (result.exitCode !== 0 || timedOut || result.launchError) report.passed = false;
await writeFile(reportPath, `${JSON.stringify(report, null, 2)}\n`);
console.log(JSON.stringify({ passed: report.passed, electronVersion: report.electronVersion, checks: report.checks, reportPath, error: report.error, ...result, timedOut }, null, 2));
if (!report.passed) process.exitCode = 1;
