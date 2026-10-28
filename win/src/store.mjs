import { readFile, writeFile, rename, mkdir, readdir, stat, copyFile, unlink } from 'node:fs/promises';
import path from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { themeFor } from './renderer/theme.mjs';

export const defaults = Object.freeze({ language:'system',textSize:13,themeHex:'F5F7F3',centerOpacity:.94,sidesOpacity:.94,
  highlightColorHex:'A8DCC5',paneProportions:[.2,.6,.2],userBubble:'EAF1FB',aiBubble:'E8F3ED',selectedModel:'',
  selectedEffort:'auto',ocrLanguage:'',backgroundImage:null,contextScope:'page',contextPages:'',customInstructions:'' });
const clone = value => structuredClone(value);
const validHash = id => typeof id === 'string' && /^[a-f0-9]{64}$/.test(id);
const hex = value => typeof value === 'string' && /^#?[a-fA-F0-9]{6}$/.test(value);
const validUUID = id => typeof id === 'string' && /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(id);
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const validPath = value => typeof value === 'string' && value.length <= 32767 && !value.includes('\0') && path.isAbsolute(value);
const MAX_LIBRARY_BYTES = 128 * 1024 * 1024;
const scopes = ['selection','page','nearby','custom','document'];

function optionalString(value, maximum, label) {
  if(value !== undefined && value !== null && (typeof value !== 'string' || value.length > maximum)) throw new Error(`${label}格式无效或过长。`);
}
function optionalDate(value) {
  if(value !== undefined && value !== null && (typeof value !== 'string' || value.length > 64 || !Number.isFinite(Date.parse(value)))) throw new Error('记录日期无效。');
}
function validateReference(reference) {
  if(reference === undefined || reference === null)return;
  if(!object(reference)||!scopes.includes(reference.scope)||!Number.isInteger(reference.totalPages)||reference.totalPages<1||reference.totalPages>100000||!Array.isArray(reference.pages)||reference.pages.length>200)throw new Error('讨论参考页码无效。');
  let previous=0;
  for(const page of reference.pages){if(!Number.isInteger(page)||page<=previous||page>reference.totalPages)throw new Error('讨论参考页码无效。');previous=page;}
}
function validateMessages(messages) {
  if(messages === undefined)return;
  if(!Array.isArray(messages)||messages.length>10000)throw new Error('讨论消息格式无效或数量过多。');
  const ids=new Set();let characters=0;
  for(const message of messages) {
    if(!object(message)||!validUUID(message.id)||ids.has(message.id.toLowerCase())||!['user','assistant'].includes(message.role)||typeof message.text!=='string'||message.text.length>8*1024*1024)throw new Error('讨论消息格式无效。');
    ids.add(message.id.toLowerCase());characters+=message.text.length;
    if(characters>24*1024*1024)throw new Error('讨论消息内容过多。');
    optionalString(message.model,1000,'模型');optionalString(message.effort,100,'推理强度');optionalString(message.error,100000,'错误信息');
    optionalDate(message.createdAt);
    if(message.status!==undefined&&!['pending','completed','failed'].includes(message.status))throw new Error('讨论消息状态无效。');
    for(const key of ['failed','hasImage'])if(message[key]!==undefined&&typeof message[key]!=='boolean')throw new Error('讨论消息状态无效。');
    if(message.evidence!==undefined&&message.evidence!==null&&(!object(message.evidence)||JSON.stringify(message.evidence).length>16384))throw new Error('讨论来源信息无效。');
    validateReference(message.reference);
  }
}

export function normalizeSettings(input={}) {
  const s={...clone(defaults)};
  if (!input || typeof input !== 'object') return s;
  if (['system','zhHans','zhHant','en','ja','ko','fr','de','es','pt'].includes(input.language)) s.language=input.language;
  for (const [key,min,max] of [['textSize',11,20],['centerOpacity',0,1],['sidesOpacity',0,1]])
    if (Number.isFinite(input[key])) s[key]=Math.max(min,Math.min(max,input[key]));
  for (const key of ['themeHex','highlightColorHex','userBubble','aiBubble']) if(hex(input[key])) s[key]=input[key].replace('#','').toUpperCase();
  const palette=themeFor(s.themeHex);
  for(const key of ['userBubble','aiBubble'])if(!hex(input[key]))s[key]=palette[key];
  const p=input.paneProportions;
  if(Array.isArray(p)&&p.length===3&&p.every(x=>Number.isFinite(x)&&x>0)&&Number.isFinite(p.reduce((a,b)=>a+b,0))) {
    const sum=p.reduce((a,b)=>a+b,0); s.paneProportions=p.map(x=>x/sum);
  }
  for(const key of ['selectedModel','selectedEffort','ocrLanguage','contextPages']) if(typeof input[key]==='string') s[key]=input[key].slice(0,1000);
  // Keep the complete draft. Overlong instructions are shown for correction and
  // blocked before inference, never silently shortened while saving.
  if(typeof input.customInstructions==='string')s.customInstructions=input.customInstructions;
  if(['selection','page','nearby','custom','document'].includes(input.contextScope))s.contextScope=input.contextScope;
  if(typeof input.backgroundImage==='string'&&input.backgroundImage.length<=20*1024*1024&&/^data:image\/(png|jpeg|webp);base64,[A-Za-z0-9+/=]+$/.test(input.backgroundImage))s.backgroundImage=input.backgroundImage;
  return s;
}

export async function atomicWrite(file, bytes) {
  await mkdir(path.dirname(file),{recursive:true});
  const tmp=`${file}.${randomUUID()}.tmp`;
  try {
    await writeFile(tmp,bytes,{mode:0o600});
    // Windows sync/indexing tools can briefly hold a destination handle without
    // delete sharing. Keep the original intact and retry the atomic rename.
    for(let attempt=0;;attempt++){
      try { await rename(tmp,file); break; }
      catch(error){
        if(process.platform!=='win32'||attempt>=6||!['EPERM','EACCES','EBUSY'].includes(error.code))throw error;
        await new Promise(resolve=>setTimeout(resolve,25*2**attempt));
      }
    }
  }
  finally { await unlink(tmp).catch(()=>{}); }
}

export async function scanPDFs(folder) {
  if(!folder)return [];
  const found=[];
  async function walk(dir) {
    const entries=await readdir(dir,{withFileTypes:true});
    for(const entry of entries) {
      if(entry.isSymbolicLink())continue;
      const full=path.join(dir,entry.name);
      if(entry.isDirectory()) { try { await walk(full); }catch(error){if(!['EACCES','EPERM','ENOENT'].includes(error.code))throw error;} }
      else if(entry.isFile()&&/\.pdf$/i.test(entry.name))found.push({path:full,relativePath:path.relative(folder,full).split(path.sep).join('/'),name:entry.name});
    }
  }
  await walk(folder);
  return found.sort((a,b)=>a.relativePath.localeCompare(b.relativePath,undefined,{numeric:true,sensitivity:'base'}));
}

function validateAnnotations(annotations) {
  if(!Array.isArray(annotations)||annotations.length>50000)throw new Error('标注格式无效或数量过多。');
  const ids=new Set();
  for(const a of annotations) {
    if(!object(a)||!validUUID(a.id)||ids.has(a.id.toLowerCase())||!['highlight','comment','question'].includes(a.kind)||typeof a.quote!=='string'||a.quote.length>100000||!Array.isArray(a.rects)||a.rects.length>20000)throw new Error('标注格式无效。');
    ids.add(a.id.toLowerCase());
    if(!Number.isInteger(a.page)||a.page<0)throw new Error('标注页码无效。');
    if(a.comment!==undefined&&(typeof a.comment!=='string'||a.comment.length>1000000))throw new Error('评论过长。');
    for(const r of a.rects)if(!object(r)||!Number.isInteger(r.page)||r.page<0||!['x','y','width','height'].every(k=>Number.isFinite(r[k]))||r.x<-.01||r.y<-.01||r.width<=0||r.height<=0||r.x+r.width>1.02||r.y+r.height>1.02)throw new Error('标注位置无效。');
    optionalDate(a.createdAt);optionalDate(a.deletedAt);
    optionalString(a.pageText,1000000,'页面文字');optionalString(a.sourceFilename,32767,'来源文件名');
    optionalString(a.contextPages,10000,'讨论参考页码');
    if(a.contextScope!==undefined&&!scopes.includes(a.contextScope))throw new Error('讨论参考范围无效。');
    if(a.collapsed!==undefined&&typeof a.collapsed!=='boolean')throw new Error('讨论折叠状态无效。');
    if(a.color!==undefined&&!hex(a.color)&&!['mint','yellow','blue','pink'].includes(a.color))throw new Error('标注颜色无效。');
    if(a.customColorHex!==undefined&&a.customColorHex!==null&&!hex(a.customColorHex))throw new Error('标注颜色无效。');
    if(a.contextPreference!==undefined&&a.contextPreference!==null){
      if(!object(a.contextPreference)||!scopes.includes(a.contextPreference.scope))throw new Error('讨论参考范围无效。');
      optionalString(a.contextPreference.pageRange,10000,'讨论参考页码');
    }
    validateMessages(a.messages);
  }
}

export class LibraryStore {
  constructor(dataDir){this.dataDir=dataDir;this.file=path.join(dataDir,'library.json');this.queue=Promise.resolve();this.blocked=false;this.library={version:1,platform:'windows',settings:clone(defaults),folderPath:null,selectedPath:null,documents:{}};}
  async init(){
    await mkdir(this.dataDir,{recursive:true});
    try {
      if((await stat(this.file)).size>MAX_LIBRARY_BYTES)throw new Error('资料库超过 128 MB，请备份后检查记录。');
      const value=JSON.parse(await readFile(this.file,'utf8'));
      if(!object(value)||value.version!==1||value.platform!=='windows'||!object(value.documents)||Object.keys(value.documents).length>100000)throw new Error('不支持的资料库格式');
      for(const key of ['folderPath','selectedPath'])if(value[key]!==undefined&&value[key]!==null&&!validPath(value[key]))throw new Error('保存的文件路径无效');
      for(const [id,doc]of Object.entries(value.documents)){
        if(!validHash(id)||!object(doc)||doc.id!==id||!Number.isInteger(doc.page)||doc.page<0||doc.page>1000000||!validPath(doc.path)||!doc.path.toLowerCase().endsWith('.pdf')||typeof doc.name!=='string'||!doc.name||doc.name.length>1024||/[\0/\\]/.test(doc.name))throw new Error('文档记录无效');
        validateAnnotations(doc.annotations);
      }
      this.library={...value,settings:normalizeSettings(value.settings)};
    } catch(error){if(error.code!=='ENOENT'){this.blocked=true;throw new Error(`资料库无法读取，已停止写入以保护原文件。请备份并检查 ${this.file}。${error.message}`);}}
    return this.snapshot();
  }
  snapshot(){return clone(this.library);}
  async persist(){
    if(this.blocked)throw new Error('资料库写入已暂停。');
    const bytes=JSON.stringify(this.library,null,2);
    if(Buffer.byteLength(bytes)>MAX_LIBRARY_BYTES)throw new Error('资料库超过 128 MB，尚未保存本次更改。请备份现有记录。');
    const task=this.queue.catch(()=>{}).then(async()=>{
      try{await copyFile(this.file,`${this.file}.bak`);}catch(e){if(e.code!=='ENOENT')throw e;}
      await atomicWrite(this.file,bytes);
    });
    this.queue=task;await task;
  }
  async setFolder(folder){this.library.folderPath=folder;await this.persist();return {folderPath:folder,files:await scanPDFs(folder)};}
  async openDocument(file,{sample=false}={}){
    if(typeof file!=='string'||!path.isAbsolute(file)||!file.toLowerCase().endsWith('.pdf'))throw new Error('请选择 PDF 文件。');
    const info=await stat(file);if(!info.isFile()||info.size>1024*1024*1024)throw new Error('PDF 文件为空或超过 1 GB。');
    const bytes=await readFile(file);if(!bytes.subarray(0,1024).includes(Buffer.from('%PDF-')))throw new Error('文件不是有效的 PDF。');
    const id=createHash('sha256').update(bytes).digest('hex');
    const name=path.basename(file);
    const old=this.library.documents[id];
    const record=old?{...old,path:file,name}:{id,path:file,name,page:sample?2:0,annotations:[]};
    this.library.documents[id]=record;
    if(!sample)this.library.selectedPath=file;
    await this.persist();
    return {...clone(record),bytes:new Uint8Array(bytes),isSample:sample};
  }
  async saveDocument({id,page,annotations}){
    if(!validHash(id)||!this.library.documents[id])throw new Error('文档尚未打开。');
    const next={...this.library.documents[id]};
    if(page!==undefined){if(!Number.isInteger(page)||page<0||page>1000000)throw new Error('页码无效。');next.page=page;}
    if(annotations!==undefined){validateAnnotations(annotations);next.annotations=clone(annotations);}
    this.library.documents[id]=next;await this.persist();
  }
  async saveSettings(patch){
    const changes={...patch};
    if(hex(changes.themeHex)&&changes.themeHex.replace('#','').toUpperCase()!==this.library.settings.themeHex){
      const palette=themeFor(changes.themeHex);
      for(const key of ['userBubble','aiBubble'])if(changes[key]===undefined)changes[key]=palette[key];
    }
    this.library.settings=normalizeSettings({...this.library.settings,...changes});await this.persist();return clone(this.library.settings);
  }
  async close(){await this.queue;}
}
