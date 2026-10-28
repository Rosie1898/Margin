import { _electron as electron } from 'playwright';
import { mkdir,writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const require=createRequire(import.meta.url);
const output=path.join(root,'test-results');await mkdir(output,{recursive:true});
const env={...process.env,LEAF_DATA_DIR:path.join(output,'ui-data'),TEMP:path.join(root,'.cache/tmp'),TMP:path.join(root,'.cache/tmp')};delete env.ELECTRON_RUN_AS_NODE;
let instance;
try{
  instance=await electron.launch({executablePath:require('electron'),args:[root,path.join(output,'fixtures/Margin verification.pdf')],env,timeout:30000});
  instance.process().stderr.on('data',b=>process.stderr.write(b));
  const page=await instance.firstWindow({timeout:30000});
  const errors=[];page.on('pageerror',error=>{errors.push(error.message);console.error(error.message);});
  page.on('console',msg=>{if(msg.type()==='error')console.error(msg.text());});
  await page.waitForTimeout(4000);
  console.log(await page.locator('body').innerText());
  console.log('CANVASES',await page.locator('.pdf-page canvas').count());
  await page.screenshot({path:path.join(output,'initial.png')});
  await writeFile(path.join(output,'ui-inspection.json'),JSON.stringify({errors,text:await page.locator('body').innerText()},null,2));
}catch(error){console.error(error);process.exitCode=1;}
finally{if(instance)await instance.close().catch(()=>instance.process().kill());}
