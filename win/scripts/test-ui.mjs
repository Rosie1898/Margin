import { _electron as electron } from 'playwright';
import assert from 'node:assert/strict';
import { mkdir,mkdtemp,readFile,writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { LibraryStore } from '../src/store.mjs';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..'),require=createRequire(import.meta.url);
const output=path.join(root,'test-results');await mkdir(output,{recursive:true});
const dataDir=await mkdtemp(path.join(output,'ui-'));
const fixture=path.join(output,'fixtures/Margin verification.pdf');
const originalHash=createHash('sha256').update(await readFile(fixture)).digest('hex');
const store=new LibraryStore(dataDir);await store.init();await store.setFolder(path.dirname(fixture));await store.saveSettings({language:'en',ocrLanguage:'en-US'});
const checks=[],errors=[],logs=[];
let instance,page;
const env={...process.env,LEAF_DATA_DIR:dataDir,TEMP:path.join(root,'.cache/tmp'),TMP:path.join(root,'.cache/tmp')};delete env.ELECTRON_RUN_AS_NODE;
const packaged=process.env.MARGIN_PACKAGED==='1';
async function launch(){
  instance=await electron.launch({executablePath:packaged?path.join(root,'dist/win-unpacked/Margin.exe'):require('electron'),args:packaged?[fixture]:[root,fixture],env,timeout:30000});
  instance.process().stderr.on('data',data=>logs.push(String(data)));
  page=await instance.firstWindow({timeout:30000});page.setDefaultTimeout(15000);
  page.on('pageerror',error=>errors.push(error.message));
  page.on('console',msg=>{if(msg.type()==='error')logs.push(msg.text());});
  await page.locator('.pdf-page[data-page="0"] .textLayer span').first().waitFor();
  await page.waitForFunction(()=>document.querySelector('#page-total').textContent==='/ 3');
}
function pass(name){checks.push(name);console.log('PASS '+name);}
async function goto(number){await page.locator('#page-number').fill(String(number));await page.locator('#page-number').press('Enter');await page.waitForTimeout(350);}
async function select(phrase,pageNumber=0){
  await page.evaluate(({phrase,pageNumber})=>{
    const nodes=[...document.querySelectorAll(`.pdf-page[data-page="${pageNumber}"] .textLayer span`)];
    const span=nodes.find(node=>node.textContent.includes(phrase));if(!span)throw new Error('Selection text missing: '+phrase);
    const node=span.firstChild,offset=node.textContent.indexOf(phrase),range=document.createRange();range.setStart(node,offset);range.setEnd(node,offset+phrase.length);
    const selection=window.getSelection();selection.removeAllRanges();selection.addRange(range);span.dispatchEvent(new MouseEvent('mouseup',{bubbles:true}));
  },{phrase,pageNumber});
  await page.locator('#selection-toolbar').waitFor({state:'visible'});
}
async function search(text,expected){await page.locator('#find').click();await page.locator('#pdf-search').fill(text);await page.waitForFunction(expected=>document.querySelector('#search-count').textContent===expected,expected);}
async function close(){
  if(!instance)return;
  const process=instance.process();
  await page.locator('[data-window="close"]').click();
  await new Promise((resolve,reject)=>{if(process.exitCode!==null)return resolve();const timer=setTimeout(()=>reject(new Error('Window close did not drain saves')),15000);process.once('exit',()=>{clearTimeout(timer);resolve();});});
  instance=null;
}
try{
  await launch();
  assert.equal(await page.locator('#file-list .file-row').count(),1);
  assert.equal(await page.evaluate(()=>typeof require),'undefined');
  const bounds=await page.evaluate(()=>['library','reader','discussion'].map(id=>document.getElementById(id).getBoundingClientRect().width));
  assert.ok(Math.abs(bounds[1]/bounds[0]-3)<.15);pass('PDF rendering, folder list, isolated renderer and 1:3:1 layout');
  await page.locator('#notes .notes-empty-prompt').screenshot({path:path.join(output,packaged?'packaged-empty-note.png':'empty-note.png')});
  await search('development','1/3');
  await page.locator('.search-mark.current').first().waitFor();
  const firstRect=await page.locator('.search-mark.current').first().boundingBox();
  await page.locator('#search-next').click();await page.waitForFunction(()=>document.querySelector('#search-count').textContent==='2/3');
  const secondRect=await page.locator('.search-mark.current').first().boundingBox();assert.ok(Math.abs(firstRect.x-secondRect.x)>5);
  await page.locator('#search-next').click();await page.waitForFunction(()=>document.querySelector('#page-number').value==='2');pass('Repeated text matches and rotated-page search navigation');
  await search('PDFs, highlights','1/1');await page.locator('.search-mark.current').first().waitFor();pass('Search phrase spanning two PDF text lines');
  await page.locator('#search-close').click();await goto(1);
  await select('Keep your thoughts beside the source.');await page.locator('[data-annotation="comment"]').click();
  await page.locator('#comment-input').fill('A local note: evidence before conclusions.');
  await page.waitForTimeout(550);
  await select('Every annotation stays linked');await page.locator('[data-annotation="highlight"]').click();
  await page.waitForFunction(()=>document.querySelector('#note-count').textContent==='2');
  const saved=JSON.parse(await readFile(path.join(dataDir,'library.json'),'utf8'));assert.equal(saved.documents[originalHash].annotations.length,2);assert.ok(saved.documents[originalHash].annotations.every(a=>a.rects.every(r=>r.width>0&&r.x+r.width<=1.02)));pass('Native text selection, source coordinates, comment and highlight persistence');
  for(let i=0;i<4;i++)await page.locator('#zoom-in').click();
  await page.waitForTimeout(450);const left=await page.evaluate(()=>{const el=document.querySelector('#pdf-scroll');el.scrollLeft=140;return el.scrollLeft;});
  await page.locator('.source-quote').click();assert.equal(await page.locator('#pdf-scroll').evaluate(el=>el.scrollLeft),left);pass('Zoom and source jump preserve horizontal position');
  await page.locator('#fit').click();await page.waitForTimeout(250);
  await page.locator('.annotation-tools button[title="Move to Recently Deleted"]').click();await page.waitForFunction(()=>document.querySelector('#note-count').textContent==='1');
  await page.locator('#toast button').click();await page.waitForFunction(()=>document.querySelector('#note-count').textContent==='2');pass('Five-second deletion undo');
  await page.locator('.note-card').last().click();await page.locator('.annotation-tools button[title="Move to Recently Deleted"]').click();
  await page.locator('#trash').click();await page.locator('.trash-item button').click();assert.equal(await page.locator('.trash-item').count(),0);await page.locator('#close-settings').click();pass('Recently Deleted restores original annotation');
  await goto(3);await page.locator('.pdf-page[data-page="2"] .ocr-word').first().waitFor({timeout:30000});
  assert.match(await page.locator('.pdf-page[data-page="2"] .textLayer').innerText(),/pineapple/i);
  await search('pineapple','1/1');await page.locator('.search-mark.current').first().waitFor();await page.locator('#search-close').click();
  await select('pineapple',2);await page.locator('[data-annotation="highlight"]').click();
  await page.screenshot({path:path.join(output,packaged?'packaged-ocr.png':'ocr.png')});pass('Real Windows OCR integrates selection, annotations and search');
  const formatting=await page.evaluate(async()=>{const {markdown,contextPages}=await import('./app.mjs');const element=markdown('**Evidence** \\(x^2 + y^2\\)\n\n<script>alert(1)</script><img src="https://example.invalid/a"><a href="javascript:alert(1)">bad</a>');let rejected=false;try{contextPages('document','',1,201);}catch{rejected=true;}return {math:element.querySelectorAll('.katex').length,strong:element.querySelectorAll('strong').length,unsafe:element.querySelectorAll('script,img,[href^="javascript:"]').length,pages:contextPages('custom','3,1-2,2',1,3),rejected};});
  assert.equal(formatting.math,1);assert.equal(formatting.strong,1);assert.equal(formatting.unsafe,0);assert.deepEqual(formatting.pages,[1,2,3]);assert.equal(formatting.rejected,true);pass('Offline Markdown/KaTeX, HTML sanitization and AI context range limits');
  await page.locator('#settings').click();
  await page.locator('#settings-body select').first().selectOption('ja');await page.waitForFunction(()=>document.documentElement.lang==='ja');
  await page.locator('#settings-body select').first().selectOption('en');
  const fontSelectors=['.settings-dialog-header h2','.settings-dialog-header span','#close-settings','.settings-nav button','.settings-version','.settings-content h2','.settings-intro','.settings-row','.settings-row select','.settings-card h3','.settings-card .small-text','.records-description','.settings-records button','.font-preview'];
  const fontSizes=()=>page.evaluate(selectors=>selectors.map(selector=>parseFloat(getComputedStyle(document.querySelector(selector)).fontSize)),fontSelectors);
  const baselineFonts=await fontSizes(),pdfZoom=await page.locator('#zoom-value').innerText();
  for(const size of [11,20,16]){
    await page.locator('#settings-body input[type="range"]').first().evaluate((el,size)=>{el.value=String(size);el.dispatchEvent(new Event('input',{bubbles:true}));},size);
    await page.waitForFunction(size=>document.querySelector('#settings-body').textContent.includes(`${size} pt`)&&document.querySelector('.font-preview').style.fontSize===`${size}px`,size);
    const sizes=await fontSizes();
    sizes.forEach((font,index)=>assert.ok(Math.abs(font/baselineFonts[index]-size/13)<.01,`${fontSelectors[index]} did not scale at ${size} pt`));
    assert.equal(await page.locator('#zoom-value').innerText(),pdfZoom);
    const layout=await page.evaluate(()=>{
      const dialog=document.querySelector('#settings-dialog'),content=document.querySelector('.settings-content'),header=document.querySelector('.settings-dialog-header');
      return {dialogFits:dialog.scrollHeight<=dialog.clientHeight+1,contentFits:content.scrollWidth<=content.clientWidth+1,headerFits:header.scrollWidth<=header.clientWidth+1};
    });
    assert.deepEqual(layout,{dialogFits:true,contentFits:true,headerFits:true},`Settings overflow at ${size} pt`);
    if(size===20)await page.screenshot({path:path.join(output,packaged?'packaged-settings-large.png':'settings-large.png')});
  }
  await page.screenshot({path:path.join(output,packaged?'packaged-settings.png':'settings.png')});await page.locator('#close-settings').click();pass('Settings text scales live at 11, 16 and 20 pt without overflow or changing PDF zoom');
  const splitter=await page.locator('#split-left').boundingBox();await page.mouse.move(splitter.x+splitter.width/2,splitter.y+150);await page.mouse.down();await page.mouse.move(splitter.x+45,splitter.y+150,{steps:5});await page.mouse.up();
  await page.waitForTimeout(400);assert.ok((await page.evaluate(()=>window.margin.bootstrap())).library.settings.paneProportions[0]>.2);pass('Resizable pane proportions saved');
  await page.locator('.detail-heading .text-button').click();await page.locator('.note-card').filter({hasText:'Keep your thoughts'}).click();
  await page.locator('#comment-input').fill('Final keystrokes survive immediate window close.');
  await close();
  const final=JSON.parse(await readFile(path.join(dataDir,'library.json'),'utf8'));assert.equal(final.documents[originalHash].annotations.find(a=>a.kind==='comment').comment,'Final keystrokes survive immediate window close.');pass('Closing window flushes pending comment autosave');
  await launch();await search('pineapple','1/1');await page.locator('.pdf-page[data-page="2"] .ocr-word').first().waitFor();
  assert.equal(await page.locator('#note-count').innerText(),'3');assert.equal((await page.evaluate(()=>window.margin.bootstrap())).library.settings.textSize,16);pass('Restart restores notes/settings and OCR cache before page revisit');
  assert.equal(createHash('sha256').update(await readFile(fixture)).digest('hex'),originalHash);assert.deepEqual(errors,[]);pass('Original PDF unchanged and no renderer exceptions');
  await close();
}catch(error){console.error(error);errors.push(error.stack||error.message);if(page&&!page.isClosed())await page.screenshot({path:path.join(output,'ui-failure.png')}).catch(()=>{});process.exitCode=1;}
finally{
  if(instance){await close().catch(()=>{instance?.process().kill();});}
  await writeFile(path.join(output,packaged?'packaged-ui-result.json':'ui-result.json'),JSON.stringify({passed:!process.exitCode,packaged,dataDir,checks,errors,logs,checkedAt:new Date().toISOString()},null,2));
}
