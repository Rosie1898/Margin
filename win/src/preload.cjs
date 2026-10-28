const { contextBridge, ipcRenderer } = require('electron');
const invoke=(channel,...args)=>ipcRenderer.invoke(`margin:${channel}`,...args);
contextBridge.exposeInMainWorld('margin',Object.freeze({
  bootstrap:()=>invoke('bootstrap'), chooseFolder:()=>invoke('choose-folder'), refreshFolder:()=>invoke('refresh-folder'),
  chooseFile:()=>invoke('choose-file'), openDocument:file=>invoke('open-document',file),
  saveDocument:value=>invoke('save-document',value), saveSettings:value=>invoke('save-settings',value),
  chooseBackground:()=>invoke('choose-background'), openDataFolder:()=>invoke('open-data-folder'), sample:()=>invoke('sample'),
  chat:(route,body)=>invoke('chat',route,body), ocrStatus:()=>invoke('ocr-status'),
  ocr:request=>invoke('ocr',request), cancelOCR:()=>invoke('cancel-ocr'),
  ocrCache:(documentId,language)=>invoke('ocr-cache',documentId,language),
  openExternal:url=>invoke('open-external',url), windowControl:action=>invoke('window-control',action),
  confirmClose:()=>invoke('confirm-close'), abortClose:()=>invoke('abort-close'),
  onMenu:callback=>{const listener=(_event,action)=>callback(action);ipcRenderer.on('margin:menu',listener);return()=>ipcRenderer.removeListener('margin:menu',listener);}
}));
