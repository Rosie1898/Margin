import { app, BrowserWindow, ipcMain, dialog, shell, Menu, safeStorage, nativeImage } from 'electron';
import { readFile, mkdir, writeFile, unlink } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createHash } from 'node:crypto';
import { LibraryStore, scanPDFs, atomicWrite } from './store.mjs';
import { createChatService } from './services/chat-service.mjs';
import { OcrService } from './services/ocr-service.mjs';
import { t, resolveLanguage } from './renderer/i18n.mjs';

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const entry=pathToFileURL(path.join(root,'src/renderer/index.html')).href;
app.setPath('userData',process.env.LEAF_DATA_DIR?path.resolve(process.env.LEAF_DATA_DIR):path.join(app.getPath('appData'),'Margin'));
const dataDir=app.getPath('userData');
app.setAppUserModelId('com.margin.reader');
let win,store,chat,ocr,files=[],closing=false,allowQuit=false,closeRequested=false;
const nativeLanguage=()=>resolveLanguage(store?.library.settings.language||'system',[app.getLocale()||'en']);
const T=(text,...values)=>t(text,nativeLanguage(),values);
let documentQueue=Promise.resolve();
const authorized=new Set();
const key=file=>path.resolve(file).toLowerCase();
let pendingFile=process.argv.find(value=>/\.pdf$/i.test(value)&&path.isAbsolute(value));
if(!app.requestSingleInstanceLock()){app.quit();}else{
  app.on('second-instance',(_e,argv)=>{if(win){if(win.isMinimized())win.restore();win.focus();const file=argv.find(value=>/\.pdf$/i.test(value)&&path.isAbsolute(value));if(file){authorized.add(key(file));win.webContents.send('margin:menu',{action:'open-file',path:file});}}});
  app.whenReady().then(start).catch(error=>{dialog.showErrorBox(T('Margin 无法启动'),T(error.message));app.exit(1);});
}

function handle(name,handler){
  ipcMain.handle(`margin:${name}`,async(event,...args)=>{
    if(!win||event.sender!==win.webContents||event.senderFrame!==win.webContents.mainFrame||event.senderFrame.url!==entry)throw new Error(T('已拒绝非阅读器页面访问本地数据。'));
    try{return await handler(...args);}catch(error){throw new Error(T(error.message||String(error)));}
  });
}
function authorizeFiles(){for(const file of files)authorized.add(key(file.path));}
async function refresh(){files=await scanPDFs(store.library.folderPath);authorizeFiles();return {folderPath:store.library.folderPath,files};}
function openInOrder(file,options){
  // Disk reads can finish out of order; the last clicked document must remain
  // the last selected document even if the previous PDF was much larger.
  const operation=documentQueue.catch(()=>{}).then(()=>store.openDocument(file,options));
  documentQueue=operation;return operation;
}
async function safeExternal(url){
  const parsed=new URL(url);if(!['https:','http:'].includes(parsed.protocol)||parsed.username||parsed.password)throw new Error(T('此链接不可打开。'));
  await shell.openExternal(parsed.href);
}
async function start(){
  store=new LibraryStore(dataDir);await store.init();
  for(const doc of Object.values(store.library.documents))if(typeof doc.path==='string')authorized.add(key(doc.path));
  if(store.library.selectedPath)authorized.add(key(store.library.selectedPath));
  if(pendingFile)authorized.add(key(pendingFile));
  let startupWarning=null;
  try{await refresh();}catch(e){startupWarning=T('文件夹暂时无法读取：{0}',T(e.message));}
  ocr=new OcrService({dataDir});
  try{chat=await createChatService({dataDir,safeStorage,openExternal:safeExternal});}catch(error){startupWarning=T('账号服务未启动：{0}',T(error.message));}
  win=new BrowserWindow({width:1380,height:900,minWidth:1000,minHeight:700,show:false,frame:false,
    backgroundColor:'#F5F7F3',title:'Margin',icon:path.join(root,'assets/AppIcon.png'),
    webPreferences:{preload:path.join(root,'src/preload.cjs'),contextIsolation:true,nodeIntegration:false,sandbox:true,webSecurity:true,spellcheck:false}});
  win.webContents.setWindowOpenHandler(({url})=>{safeExternal(url).catch(()=>{});return {action:'deny'};});
  win.webContents.on('will-navigate',(event,url)=>{if(url!==entry){event.preventDefault();safeExternal(url).catch(()=>{});}});
  win.webContents.session.setPermissionRequestHandler((_contents,_permission,callback)=>callback(false));
  win.webContents.session.setPermissionCheckHandler(()=>false);
  // Reading and OCR have no renderer networking. Chat requests cross the narrow IPC bridge.
  win.webContents.session.webRequest.onBeforeRequest((details,callback)=>{
    callback({cancel:/^https?:/i.test(details.url)});
  });
  handle('bootstrap',()=>({library:store.snapshot(),files,version:app.getVersion(),platform:process.platform,systemLocale:app.getLocale(),dataDir,startupWarning,openPath:pendingFile}));
  handle('choose-folder',async()=>{const result=await dialog.showOpenDialog(win,{title:T('选择 PDF 文件夹'),buttonLabel:T('打开文件夹'),properties:['openDirectory']});if(result.canceled)return null;const value=await store.setFolder(result.filePaths[0]);files=value.files;authorizeFiles();return value;});
  handle('refresh-folder',refresh);
  handle('choose-file',async()=>{const result=await dialog.showOpenDialog(win,{title:T('打开 PDF'),buttonLabel:T('打开 PDF'),filters:[{name:'PDF',extensions:['pdf']}],properties:['openFile']});if(result.canceled)return null;const file=result.filePaths[0];authorized.add(key(file));return file;});
  handle('open-document',async file=>{if(typeof file!=='string'||!authorized.has(key(file)))throw new Error('请先通过文件夹或文件选择器打开这份 PDF。');ocr.cancel();return openInOrder(file);});
  handle('save-document',value=>store.saveDocument(value));
  handle('save-settings',async value=>{const previous=store.library.settings.language;const saved=await store.saveSettings(value);if(previous!==store.library.settings.language)rebuildMenu();return saved;});
  handle('open-data-folder',async()=>{const result=await shell.openPath(dataDir);if(result)throw new Error(result);});
  handle('choose-background',async()=>{
    const result=await dialog.showOpenDialog(win,{title:T('选择背景图片'),buttonLabel:T('选择图片…'),filters:[{name:T('图片'),extensions:['png','jpg','jpeg','webp']}],properties:['openFile']});if(result.canceled)return null;
    const bytes=await readFile(result.filePaths[0]);if(bytes.length>15*1024*1024)throw new Error('请选择小于 15 MB 的背景图片。');
    const img=nativeImage.createFromBuffer(bytes);if(img.isEmpty())throw new Error('无法读取此图片。');
    const value=img.toDataURL();if(value.length>20*1024*1024)throw new Error('图片解码后过大，请选择尺寸较小的图片。');await store.saveSettings({backgroundImage:value});return value;
  });
  handle('chat',(route,body)=>{if(!chat)throw new Error('账号服务未启动，请重新打开 Margin。');return chat.request(route,body);});
  handle('ocr-status',()=>ocr.status());
  handle('ocr-cache',(documentId,language)=>{if(!store.library.documents[documentId])throw new Error('文档尚未打开。');return ocr.cached(documentId,language);});
  handle('ocr',request=>{if(!request||!store.library.documents[request.documentId])throw new Error('OCR 文档尚未打开。');return ocr.recognize(request);});
  handle('cancel-ocr',()=>{ocr.cancel();return {cancelled:true};});
  handle('sample',openSample);
  handle('open-external',safeExternal);
  handle('window-control',action=>{if(action==='minimize')win.minimize();else if(action==='maximize'){win.isMaximized()?win.unmaximize():win.maximize();}else if(action==='close')win.close();});
  handle('confirm-close',()=>{if(closeRequested)void shutdown();return true;});
  handle('abort-close',()=>{closeRequested=false;return true;});
  rebuildMenu();
  win.setMenuBarVisibility(false);
  win.on('close',event=>{if(!allowQuit){event.preventDefault();requestClose();}});
  win.once('ready-to-show',()=>win.show());
  await win.loadURL(entry);
}
function rebuildMenu(){
  Menu.setApplicationMenu(Menu.buildFromTemplate([
    {label:T('文件'),submenu:[{label:T('打开 PDF'),accelerator:'Ctrl+O',click:()=>sendMenu('file')},{label:T('选择文件夹'),accelerator:'Ctrl+Shift+O',click:()=>sendMenu('folder')},{type:'separator'},{label:T('设置'),accelerator:'Ctrl+,',click:()=>sendMenu('settings')},{role:'quit',label:T('退出')}]},
    {label:T('编辑'),submenu:[{role:'undo',label:T('撤销')},{role:'redo',label:T('重做')},{type:'separator'},{role:'cut',label:T('剪切')},{role:'copy',label:T('复制')},{role:'paste',label:T('粘贴')},{role:'selectAll',label:T('全选')}]},
    {label:T('阅读'),submenu:[['搜索 PDF','Ctrl+F','find'],['下一处','Ctrl+G','next'],['上一处','Ctrl+Shift+G','previous'],['高亮','Ctrl+Shift+H','highlight'],['评论','Ctrl+Shift+M','comment'],['问 AI','Ctrl+K','ask']].map(([label,accelerator,action])=>({label:T(label),accelerator,click:()=>sendMenu(action)}))}
  ]));
}
function sendMenu(action){win?.webContents.send('margin:menu',action);}
function requestClose(){if(!closeRequested&&!closing){closeRequested=true;sendMenu('before-close');}}

async function openSample(){
  const source=JSON.parse(await readFile(path.join(root,'assets/Lucas-SOURCE.json'),'utf8'));
  const file=path.join(dataDir,'Samples',source.filename);
  let bytes;try{bytes=await readFile(file);}catch(error){if(error.code!=='ENOENT')throw error;}
  if(!bytes||createHash('sha256').update(bytes).digest('hex')!==source.sha256){
    const result=await dialog.showMessageBox(win,{type:'question',title:T('下载入门示例？'),message:T('从 Stanford 下载 Robert Lucas 的《On the Mechanics of Economic Development》？'),detail:T('文件将缓存在本机，之后可以离线阅读。此下载不使用 ChatGPT。')+'\n\n'+source.source_url,buttons:[T('下载'),T('取消')],defaultId:0,cancelId:1});
    if(result.response!==0)return null;
    const response=await fetch(source.source_url,{signal:AbortSignal.timeout(90000)});
    if(!response.ok)throw new Error(T('示例下载失败 ({0})',response.status));
    const chunks=[];let count=0;for await(const chunk of response.body){count+=chunk.length;if(count>50*1024*1024){await response.body.cancel().catch(()=>{});throw new Error('示例文件超过允许大小。');}chunks.push(chunk);}
    bytes=Buffer.concat(chunks);
    if(createHash('sha256').update(bytes).digest('hex')!==source.sha256)throw new Error('示例来源文件已变化，校验未通过。');
    await atomicWrite(file,bytes);
  }
  authorized.add(key(file));
  ocr.cancel();return openInOrder(file,{sample:true});
}

async function shutdown(){
  if(closing)return;closing=true;
  try{await documentQueue.catch(()=>{});await ocr?.close();await chat?.close();await store?.close();allowQuit=true;app.quit();}
  catch(error){closing=false;closeRequested=false;await dialog.showMessageBox(win,{type:'error',title:T('暂时无法退出'),message:T('本地记录或登录凭据尚未安全保存。请重试退出。'),detail:T(error.message),buttons:[T('好')]});}
}
app.on('before-quit',event=>{if(!allowQuit&&win){event.preventDefault();requestClose();}});
app.on('window-all-closed',()=>{if(allowQuit)app.quit();});
