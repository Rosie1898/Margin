import test from 'node:test';
import assert from 'node:assert/strict';
import { themeFor,themePresets,luminance } from '../src/renderer/theme.mjs';
import { LibraryStore,normalizeSettings } from '../src/store.mjs';
import { mkdtemp,mkdir,rm } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const contrast=(a,b)=>(Math.max(luminance(a),luminance(b))+.05)/(Math.min(luminance(a),luminance(b))+.05);
test('all seven themes keep text readable across panes and coordinated bubbles',()=>{
  assert.equal(themePresets.length,7);
  assert.ok(!themePresets.some(p=>p.hex==='F4EBDD'));
  for(const preset of themePresets){
    const theme=themeFor(preset.hex);
    for(const key of ['sidebar','center','canvas','card','raised','userBubble','aiBubble']){
      assert.ok(contrast(theme.ink,theme[key])>=4.5,`${preset.hex} ${key} foreground contrast`);
    }
    assert.ok(contrast(theme.muted,theme.card)>=3,`${preset.hex} muted contrast`);
    assert.equal(theme.dark,['253247','202124'].includes(preset.hex));
  }
});
test('choosing a theme updates both bubbles, while explicit custom colors remain editable',async()=>{
  const parent=fileURLToPath(new URL('../test-results/',import.meta.url));await mkdir(parent,{recursive:true});
  const dir=await mkdtemp(path.join(parent,'theme-'));
  try{
    const store=new LibraryStore(dir);await store.init();
    let settings=await store.saveSettings({themeHex:'253247'});
    assert.equal(settings.userBubble,themeFor('253247').userBubble);
    assert.equal(settings.aiBubble,themeFor('253247').aiBubble);
    await store.saveSettings({userBubble:'FEDCBA'});
    settings=await store.saveSettings({textSize:15});assert.equal(settings.userBubble,'FEDCBA');
    settings=await store.saveSettings({themeHex:'202124'});assert.equal(settings.userBubble,themeFor('202124').userBubble);
    const restored=new LibraryStore(dir);await restored.init();assert.deepEqual(restored.snapshot().settings,settings);
    assert.equal(normalizeSettings({themeHex:'202124'}).aiBubble,themeFor('202124').aiBubble);
  }finally{
    assert.ok(path.resolve(dir).startsWith(path.resolve(parent)+path.sep));await rm(dir,{recursive:true,force:true,maxRetries:5,retryDelay:100});
  }
});
