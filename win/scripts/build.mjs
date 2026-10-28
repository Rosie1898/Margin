import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdir, readFile, readdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const flags = process.argv.slice(2);
if (flags.some(flag => !['--package-only', '--install-only'].includes(flag)) || flags.length > 1) {
  throw new Error('Usage: node scripts/build.mjs [--package-only | --install-only]');
}
if (process.platform !== 'win32') throw new Error('Build and install Margin on Windows.');
const env = { ...process.env,
  ELECTRON_CACHE: path.join(root, '.cache/electron'),
  ELECTRON_BUILDER_CACHE: path.join(root, '.cache/builder'),
  TEMP: path.join(root, '.cache/tmp'), TMP: path.join(root, '.cache/tmp')
};
await mkdir(env.TEMP, { recursive: true });

function run(executable, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(executable, args, { cwd: root, env, stdio: 'inherit', windowsHide: true });
    child.once('error', reject);
    child.once('exit', code => code === 0 ? resolve() : reject(new Error(`${path.basename(executable)} exited with ${code ?? 'a signal'}`)));
  });
}

async function fileRecord(relativePath) {
  const bytes = await readFile(path.join(root, relativePath));
  return { path: relativePath.replaceAll('\\', '/'), sha256: createHash('sha256').update(bytes).digest('hex') };
}

try {
  if (!flags.includes('--install-only')) {
    await run(process.execPath, ['scripts/prepare-assets.mjs']);
    await run(process.execPath, ['node_modules/electron-builder/cli.js', '--win', 'nsis', '--x64']);
    const { version } = JSON.parse(await readFile(path.join(root, 'package.json'), 'utf8'));
    const files = ['dist/win-unpacked/Margin.exe', 'dist/win-unpacked/resources/app.asar'];
    async function unpackedFiles(directory) {
      for (const entry of await readdir(path.join(root, directory), { withFileTypes: true })) {
        const file = path.posix.join(directory, entry.name);
        if (entry.isDirectory()) await unpackedFiles(file);
        else if (entry.isFile()) files.push(file);
      }
    }
    await unpackedFiles('dist/win-unpacked/resources/app.asar.unpacked');
    const receipt = { version, builtAt: new Date().toISOString(),
      installer: await fileRecord(`dist/Margin-${version}-Windows-x64-Setup.exe`),
      files: await Promise.all(files.map(fileRecord)) };
    // Written only after the installer build succeeds; stale packages cannot be installed silently.
    await writeFile(path.join(root, 'dist/local-build.json'), JSON.stringify(receipt, null, 2) + '\n');
  }
  if (!flags.includes('--package-only')) {
    console.log('Installing the new build over the local Margin installation...');
    const powershell = path.join(process.env.SystemRoot || 'C:\\Windows', 'System32/WindowsPowerShell/v1.0/powershell.exe');
    await run(powershell, ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', path.join(root, 'scripts/install-local.ps1')]);
  }
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
