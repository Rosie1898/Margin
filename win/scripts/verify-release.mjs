import { createRequire } from 'node:module';
import { readFile,writeFile,readdir,stat } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const require=createRequire(import.meta.url),asar=require('@electron/asar');
const archive=path.join(root,'dist/win-unpacked/resources/app.asar');
const {version}=JSON.parse(await readFile(path.join(root,'package.json'),'utf8'));
const hash=bytes=>createHash('sha256').update(bytes).digest('hex');
const source=[];
async function walk(directory){for(const entry of await readdir(path.join(root,directory),{withFileTypes:true})){const name=path.posix.join(directory,entry.name);if(entry.isDirectory())await walk(name);else source.push(name);}}
for(const directory of ['src','assets','native'])await walk(directory);
for(const entry of await readdir(path.join(root,'backend')))if(entry.endsWith('.mjs')&&!entry.endsWith('.test.mjs'))source.push('backend/'+entry);
source.push('THIRD_PARTY_NOTICES.md');
const records=[];
for(const file of source){const bytes=await readFile(path.join(root,file));const packaged=asar.extractFile(archive,file.split('/').join(path.sep));if(!bytes.equals(packaged))throw new Error(`Packaged source mismatch: ${file}`);records.push({file,sha256:hash(bytes)});}
const artifacts=[];
for(const file of [`dist/Margin-${version}-Windows-x64-Setup.exe`,'dist/win-unpacked/Margin.exe','dist/win-unpacked/resources/app.asar']){
 const bytes=await readFile(path.join(root,file));artifacts.push({file,size:bytes.length,sha256:hash(bytes)});
}
const reports={};for(const name of ['packaged-ui-result','packaged-chat-ui-result','packaged-refinements-result','localization-native-result','native-electron-result']){const report=JSON.parse(await readFile(path.join(root,'test-results',name+'.json'),'utf8'));if(!report.passed)throw new Error(`${name} did not pass`);reports[name]={passed:true,checks:report.checks,testedAt:report.checkedAt||report.testedAt};}
const result={product:'Margin',version,platform:'Windows x64',verifiedAt:new Date().toISOString(),sourceBase:'Margin macOS 0.5.0 with synchronized 0.5.1 source refinements',packagedSourceFiles:records.length,artifacts,reports,realAccountLoginTested:false,realModelCalls:0,installerExecuted:false,sourceFiles:records};
await writeFile(path.join(root,'dist/release-verification.json'),JSON.stringify(result,null,2));
await writeFile(path.join(root,'dist/SHA256SUMS.txt'),artifacts.map(a=>`${a.sha256}  ${a.file.replace(/^dist\//,'')}`).join('\n')+'\n');
console.log(JSON.stringify({verified:true,packagedSourceFiles:records.length,artifacts},null,2));
