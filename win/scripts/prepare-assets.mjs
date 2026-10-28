import { mkdir, copyFile, cp } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const vendor = path.join(root, 'src/renderer/vendor');
await mkdir(vendor, { recursive: true });
for (const [source, target] of [
  ['marked/lib/marked.esm.js','marked.esm.js'],
  ['dompurify/dist/purify.es.mjs','purify.es.mjs'],
  ['katex/dist/katex.mjs','katex.mjs'],
  ['katex/dist/katex.css','katex.css'],
  ['katex/dist/contrib/auto-render.mjs','auto-render.mjs']
]) await copyFile(path.join(root, 'node_modules', source), path.join(vendor, target));
await cp(path.join(root, 'node_modules/katex/dist/fonts'), path.join(vendor, 'fonts'), { recursive: true });
console.log('Offline Markdown and math assets are ready.');
