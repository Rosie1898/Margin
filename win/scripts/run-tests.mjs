import { spawn } from 'node:child_process';
import { mkdir,readdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const temp=path.join(root,'test-results','tmp');await mkdir(temp,{recursive:true});
const tests=[];for(const folder of ['tests','backend'])for(const file of await readdir(path.join(root,folder)))if(file.endsWith('.test.mjs'))tests.push(path.join(root,folder,file));
const child=spawn(process.execPath,['--test',...tests],{cwd:root,stdio:'inherit',windowsHide:true,env:{...process.env,TEMP:temp,TMP:temp}});
child.on('exit',code=>process.exitCode=code??1);
