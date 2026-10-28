import { PDFReader } from './pdf.mjs';
import { t, supportedLanguages, fontSample, resolveLanguage, setSystemLocales } from './i18n.mjs';
import { themeFor, themePresets, luminance, mix } from './theme.mjs';
import { Marked } from './vendor/marked.esm.js';
import DOMPurify from './vendor/purify.es.mjs';
import katex from './vendor/katex.mjs';

const api = window.margin;
const $ = (selector, root = document) => root.querySelector(selector);
const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];
const defaults = { language: 'system', textSize: 13, themeHex: 'F5F7F3', centerOpacity: .94, sidesOpacity: .94,
  highlightColorHex: 'A8DCC5', paneProportions: [.2, .6, .2], userBubble: 'EAF1FB', aiBubble: 'E8F3ED',
  selectedModel: '', selectedEffort: 'auto', ocrLanguage: '', contextScope: 'page', contextPages: '', customInstructions: '' };
const state = { library: { documents: {}, settings: {} }, settings: { ...defaults }, files: [], doc: null,
  selectedId: null, selection: null, folders: new Set(), account: {}, models: [], jobs: new Map(), drafts: new Map(),
  errors: new Map(), expandedMessages: new Set(), sending: new Set(), version: '', dataDir: '', epoch: 0, opening: false,
  ocrInfo: null, ocrBusy: false, ocrToken: 0, autoAttempted: new Set(), samplePrevious: null, sampleOpen: false,
  settingsSection: 'general', status: '', saveTimers: new Map() };
const T = text => t(text, state.settings.language);
const pendingWrites = new Set();
function trackWrite(promise) { pendingWrites.add(promise); promise.finally(() => pendingWrites.delete(promise)).catch(() => {}); return promise; }
const iconPaths = {
  'folder-plus':'<path d="M3 7h6l2 2h10v11H3z"/><path d="M3 7V4h6l2 3M12 12v5m-2.5-2.5h5"/>',
  folder:'<path d="M3 7V4h6l2 3h10v13H3z"/>',file:'<path d="M14 2H5v20h14V7zM14 2v6h5M8 12h8M8 16h6"/>',
  search:'<circle cx="10.5" cy="10.5" r="6.5"/><path d="m16 16 5 5"/>',refresh:'<path d="M20 7v5h-5M4 17v-5h5M5.5 6a8 8 0 0 1 13.3 1M18.5 18A8 8 0 0 1 5.2 17"/>',
  drive:'<rect x="3" y="5" width="18" height="14" rx="2"/><path d="M3 14h18M16 17h2"/>',settings:'<path d="M9.8 3.1 10.3 1h3.4l.5 2.1 1.8.8 1.9-1.1 2.4 2.4-1.1 1.9.8 1.8 2.1.5v3.4l-2.1.5-.8 1.8 1.1 1.9-2.4 2.4-1.9-1.1-1.8.8-.5 2.1h-3.4l-.5-2.1-1.8-.8-1.9 1.1-2.4-2.4 1.1-1.9-.8-1.8-2.1-.5v-3.4l2.1-.5.8-1.8-1.1-1.9 2.4-2.4 1.9 1.1z"/><circle cx="12" cy="10.9" r="3.4"/>',
  book:'<path d="M5 3h15v18H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2zM6 3v15h14M3 18h17"/>',
  personalization:'<rect x="2" y="4" width="20" height="16" rx="2"/><circle cx="8" cy="10" r="2"/><path d="M5 17v-1a3 3 0 0 1 6 0v1M14 9h5m-5 4h5m-5 4h3"/>',
  'book-open':'<path d="M12 5C8 2 4 3 2 4v15c3-1 6-1 10 2 4-3 7-3 10-2V4c-3-1-6-1-10 1zM12 5v16M5 7l4 1M5 11l4 1M15 8l4-1M15 12l4-1"/>',
  back:'<path d="m10 5-7 7 7 7M3 12h18"/>',left:'<path d="m15 5-7 7 7 7"/>',right:'<path d="m9 5 7 7-7 7"/>',up:'<path d="m5 15 7-7 7 7"/>',down:'<path d="m5 9 7 7 7-7"/>',
  close:'<path d="m6 6 12 12M6 18 18 6"/>',minus:'<circle cx="10" cy="10" r="6.5"/><path d="M7 10h6m2 5 6 6"/>',plus:'<circle cx="10" cy="10" r="6.5"/><path d="M7 10h6m-3-3v6m5 2 6 6"/>',fit:'<path d="M9 3H3v6m12 12h6v-6M3 3l7 7m11 11-7-7M15 3h6v6M3 15v6h6"/>',
  scan:'<path d="M8 3H3v5m13-5h5v5M3 16v5h5m13-5v5h-5M8 9h8m-4 0v7m-3 0h6"/>',
  message:'<path d="M4 4h16v13H9l-5 4zM8 8h8M8 12h5"/>',trash:'<path d="M3 6h18M9 6V3h6v3M5 6l1 15h12l1-15M10 10v7m4-7v7"/>',
  highlight:'<path d="m14 3 7 7-10 10-7-7zM4 13l-2 7 7-2M3 23h10"/>',sparkles:'<path d="m12 2 2.5 7.5L22 12l-7.5 2.5L12 22l-2.5-7.5L2 12l7.5-2.5zM20 2v4m-2-2h4"/>',
  palette:'<path d="M12 3a9 9 0 1 0 0 18c3 0 3-3 1-4-1-1 0-3 2-3h3c5 0 3-11-6-11z"/><circle cx="7" cy="10" r=".7"/><circle cx="10" cy="7" r=".7"/><circle cx="15" cy="7" r=".7"/>',
  target:'<circle cx="12" cy="12" r="7"/><path d="M12 2v5m0 10v5M2 12h5m10 0h5"/>',send:'<path d="M12 20V4m-7 7 7-7 7 7"/>',check:'<path d="m5 12 4 4L19 6"/>',ellipsis:'<circle cx="5" cy="12" r="1"/><circle cx="12" cy="12" r="1"/><circle cx="19" cy="12" r="1"/>'
};
function icon(name) { const span = document.createElement('span'); span.innerHTML = `<svg viewBox="0 0 24 24" aria-hidden="true">${iconPaths[name] || iconPaths.file}</svg>`; return span.firstElementChild; }
function el(tag, className = '', text = '') { const node = document.createElement(tag); if (className) node.className = className; if (text) node.textContent = text; return node; }
function button(text, action, className = '', iconName) { const b = el('button', className); if (iconName) b.append(icon(iconName)); if (text) b.append(document.createTextNode(T(text))); b.addEventListener('click', safe(action)); return b; }
function closePopover() { state.popover?.remove(); state.popover = null; state.popoverAnchor = null; }
function popover(anchor, content, width = 240) {
  closePopover();
  const panel = el('div', 'control-popover'); panel.style.width = `${width}px`; panel.setAttribute('role', 'dialog'); panel.append(content);
  (anchor.closest('dialog') || document.body).append(panel); state.popover = panel; state.popoverAnchor = anchor;
  const rect = anchor.getBoundingClientRect(), height = panel.getBoundingClientRect().height;
  panel.style.left = `${Math.max(8, Math.min(innerWidth - width - 8, rect.right - width))}px`;
  panel.style.top = `${rect.bottom + height + 12 < innerHeight ? rect.bottom + 6 : Math.max(42, rect.top - height - 6)}px`;
  return panel;
}
function colorPopover(anchor, value, title, onChange) {
  const content = el('div', 'color-popover'); content.append(el('h3', '', T(title)));
  const picker = el('input'); picker.type = 'color'; picker.value = `#${value}`; picker.setAttribute('aria-label', T('颜色选择器'));
  const row = el('label', 'settings-row'); row.append(el('span', '', T('颜色选择器')), picker); content.append(row);
  const hexRow = el('div', 'hex-color-row'), hex = el('input'); hex.value = value; hex.placeholder = 'RRGGBB'; hex.maxLength = 7; hex.setAttribute('aria-label', T('十六进制颜色')); hexRow.append(el('span', 'muted', '#'), hex); content.append(hexRow);
  const valid = () => /^#?[0-9a-f]{6}$/i.test(hex.value.trim());
  const apply = async () => { if (!valid()) return; await onChange(hex.value.trim().replace(/^#/, '').toUpperCase()); closePopover(); };
  const applyButton = button('应用颜色', apply, 'primary'); content.append(applyButton);
  hex.addEventListener('input', () => { applyButton.disabled = !valid(); }); hex.addEventListener('keydown', safe(async event => { if (event.key === 'Enter') { event.preventDefault(); await apply(); } }));
  picker.addEventListener('input', safe(async () => { hex.value = picker.value.slice(1).toUpperCase(); applyButton.disabled = false; await onChange(hex.value); }));
  popover(anchor, content);
}
function colorButton(value, title, onChange) {
  const b = button('', event => colorPopover(event.currentTarget, value(), title, onChange), 'annotation-color');
  b.title = T(title); b.setAttribute('aria-label', T(title));
  const swatch = el('span', 'annotation-color-swatch', '+'); swatch.style.backgroundColor = `#${value()}`; b.append(swatch); return b;
}
function presetColorMenu(anchor, onChange) {
  const list = el('div', 'compact-menu');
  for (const [hex, label] of [['A8DCC5','薄荷绿'],['F4D884','浅杏黄'],['A8CFF0','雾蓝'],['E9BBD2','浅玫瑰']]) {
    const item = button('', async () => { await onChange(hex); closePopover(); }, 'menu-item');
    const swatch = el('span', 'menu-swatch'); swatch.style.backgroundColor = `#${hex}`; item.append(swatch, el('span', '', T(label))); list.append(item);
  }
  popover(anchor, list, 155);
}
function safe(fn) { return (...args) => { try { Promise.resolve(fn(...args)).catch(showError); } catch (error) { showError(error); } }; }
function showError(error) { console.error(error); toast(T(String(error?.message || error).replace(/^Error invoking remote method '[^']+': Error: /, ''))); }
function toast(text, action, duration = 6500) { clearTimeout(state.toastTimer); const box = $('#toast'); box.replaceChildren(document.createTextNode(text)); if (action) box.append(button(action.label, action.run)); box.hidden = false; state.toastTimer = setTimeout(() => { box.hidden = true; }, duration); }
function localize(root = document) {
  for (const node of $$('[data-i18n]', root)) node.textContent = T(node.dataset.i18n);
  for (const node of $$('[data-placeholder]', root)) node.placeholder = T(node.dataset.placeholder);
  for (const node of $$('[data-tip]', root)) { node.title = T(node.dataset.tip); node.setAttribute('aria-label', T(node.dataset.tip)); }
  for (const node of $$('[data-icon]', root)) if (!node.querySelector('svg')) node.append(icon(node.dataset.icon));
}
function applySettings() {
  const s = state.settings, style = document.documentElement.style;
  const theme = themeFor(s.themeHex);
  for (const [key, value] of Object.entries(theme.css)) style.setProperty(key, value);
  document.documentElement.dataset.theme = theme.dark ? 'dark' : 'light';
  style.colorScheme = theme.dark ? 'dark' : 'light';
  style.setProperty('--text', `${s.textSize}px`); style.setProperty('--theme', `#${s.themeHex}`);
  style.setProperty('--sides-opacity', s.sidesOpacity); style.setProperty('--center-opacity', s.centerOpacity);
  style.setProperty('--user-bubble', `#${s.userBubble}`); style.setProperty('--ai-bubble', `#${s.aiBubble}`);
  for (const kind of ['user', 'ai']) {
    const background = s[`${kind}Bubble`], lightness = luminance(background);
    const ink = lightness < .179 ? 'FFFFFF' : '000000';
    style.setProperty(`--${kind}-bubble-ink`, `#${ink}`);
    let amount = .35, muted = mix(ink, background, amount);
    const contrast = color => { const value = luminance(color); return (Math.max(value, lightness) + .05) / (Math.min(value, lightness) + .05); };
    while (amount > 0 && contrast(muted) < 4.5) { amount = Math.max(0, amount - .05); muted = mix(ink, background, amount); }
    style.setProperty(`--${kind}-bubble-muted`, `#${muted}`);
  }
  const panes = s.paneProportions || [.2, .6, .2]; style.setProperty('--left', `${panes[0] * 100}%`); style.setProperty('--right', `${panes[2] * 100}%`);
  if (s.backgroundImage?.startsWith('data:image/')) document.body.style.backgroundImage = `url("${s.backgroundImage}")`;
  else document.body.style.backgroundImage = '';
  document.documentElement.lang = { zhHans: 'zh-CN', zhHant: 'zh-TW' }[resolveLanguage(s.language)] || resolveLanguage(s.language);
  $('#selection-color .annotation-color-swatch').style.backgroundColor = `#${s.highlightColorHex || 'A8DCC5'}`;
  for (const b of $$('[data-color]')) b.classList.toggle('selected', b.dataset.color === s.highlightColorHex);
  localize();
  if (state.doc) $('#document-title').textContent = state.doc.name.replace(/\.pdf$/i, '');
  if (state.library.folderPath) $('#folder-name').textContent = state.library.folderPath.split(/[\\/]/).filter(Boolean).at(-1);
  for (const preset of $$('[data-theme-color]')) preset.setAttribute('aria-pressed', preset.dataset.themeColor === s.themeHex);
  for (const control of $$('input[data-setting-color]')) control.value = `#${s[control.dataset.settingColor]}`;
}
async function settings(patch, redraw = false) {
  if (patch.themeHex) {
    const theme = themeFor(patch.themeHex);
    patch = { userBubble: theme.userBubble, aiBubble: theme.aiBubble, ...patch };
  }
  const revision = (state.settingsRevision || 0) + 1;
  state.settingsRevision = revision;
  Object.assign(state.settings, patch);
  state.library.settings = state.settings;
  applySettings();
  // Rebuild controls before yielding: a later input must never be replaced by
  // an earlier language-change response, or keep updating detached labels.
  if (redraw) { closePopover(); renderLibrary(); renderNotes(); renderAccount(); renderOCRMenu(); if ($('#settings-dialog').open) renderSettings(); }
  const saved = await trackWrite(api.saveSettings(patch));
  if (saved && revision === state.settingsRevision) {
    Object.assign(state.settings, saved);
    state.library.settings = state.settings;
    applySettings();
  }
}
function currentAnnotations() { return state.doc?.annotations || []; }
function activeAnnotations() { return currentAnnotations().filter(a => !a.deletedAt); }
function selected() { return activeAnnotations().find(a => a.id === state.selectedId); }
async function persist(doc = state.doc) {
  if (!doc) return;
  clearTimeout(state.saveTimers.get(doc.id)); state.saveTimers.delete(doc.id);
  const record = { id: doc.id, path: doc.path, name: doc.name, page: doc.page || 0, annotations: doc.annotations || [] };
  // One canonical object per content hash also belongs to in-flight chat jobs.
  // Reopening a document must not leave a job writing an obsolete annotations array.
  state.library.documents[doc.id] = doc;
  await trackWrite(api.saveDocument({ id: record.id, page: record.page, annotations: record.annotations }));
}
function scheduleSave(doc = state.doc) {
  if (!doc) return;
  clearTimeout(state.saveTimers.get(doc.id)); state.saveTimers.set(doc.id, setTimeout(() => persist(doc).catch(showError), 350));
}
function setStatus(text, cancel = false) {
  state.status = text; const node = $('#reader-status'); node.title = text; node.replaceChildren();
  if (state.ocrBusy) node.append(el('span', 'spinner'));
  node.append(document.createTextNode(text));
  if (cancel) node.append(button('取消', cancelOCR));
}

const reader = new PDFReader({ scroll: $('#pdf-scroll'), pages: $('#pdf-pages'),
  onPage(index, count) {
    $('#page-number').value = index + 1; $('#page-number').max = count; $('#page-total').textContent = `/ ${count}`;
    $('#prev-page').disabled = index <= 0; $('#next-page').disabled = index >= count - 1;
    if (state.doc && state.doc.page !== index) {
      state.doc.page = index; scheduleSave();
      if (state.ocrBusy && state.ocrMode === 'auto' && state.ocrPage !== index) void cancelOCR().then(() => autoOCR(index)).catch(showError);
    }
  },
  onSelection(snapshot) {
    if (!snapshot) { $('#selection-toolbar').hidden = true; return; }
    state.selection = snapshot;
    const bar = $('#selection-toolbar'); bar.hidden = false;
    const width = bar.offsetWidth, height = bar.offsetHeight;
    const readerBox = $('#reader').getBoundingClientRect();
    bar.style.left = `${Math.max(readerBox.left + 8, Math.min(snapshot.anchor.x - width / 2, readerBox.right - width - 8))}px`;
    const below = snapshot.anchor.y + 9;
    bar.style.top = `${Math.max(45, below + height < innerHeight - 40 ? below : snapshot.anchor.top - height - 9)}px`;
  },
  onAnnotation: id => focusAnnotation(id),
  onNeedOCR: index => autoOCR(index),
  onZoom: scale => { $('#zoom-value').textContent = `${Math.round(scale * 100)}%`; },
  onError: showError
});

function renderLibrary() {
  const list = $('#file-list'); list.replaceChildren();
  const folder = state.library.folderPath;
  $('#folder-name').textContent = folder ? folder.split(/[\\/]/).filter(Boolean).at(-1) : T('本地文件夹');
  $('#folder-name').title = folder || '';
  $('#file-count').textContent = T(`${state.files.length} 份 PDF · 本地保存`);
  const query = $('#file-search').value.trim().toLocaleLowerCase();
  const files = state.files.filter(f => !query || f.relativePath.toLocaleLowerCase().includes(query));
  if (!files.length) { list.append(el('div', 'list-empty', T(query ? '没有匹配的 PDF' : '这里还没有 PDF\n选择一个文件夹，开始阅读。'))); return; }
  const root = { children: new Map() };
  for (const file of files) {
    const pieces = file.relativePath.split(/[\\/]/); let branch = root, key = '';
    for (let i = 0; i < pieces.length - 1; i++) { key += `${pieces[i]}/`; if (!branch.children.has(pieces[i])) branch.children.set(pieces[i], { name: pieces[i], key, children: new Map() }); branch = branch.children.get(pieces[i]); }
    branch.children.set(file.path, { file });
  }
  function walk(branch, depth = 0) {
    const nodes = [...branch.children.values()].sort((a, b) => Number(!!a.file) - Number(!!b.file) || (a.name || a.file.name).localeCompare(b.name || b.file.name, undefined, { numeric: true }));
    for (const node of nodes) {
      if (node.file) {
        const f = node.file, row = button('', () => openPath(f.path), 'file-row', 'file');
        row.classList.toggle('active', state.doc?.path === f.path && !state.sampleOpen);
        row.append(el('span', '', f.name.replace(/\.pdf$/i, ''))); row.title = f.relativePath; row.style.paddingLeft = `${10 + depth * 14}px`; list.append(row);
      } else {
        const expanded = query ? !state.folders.has(`closed:${node.key}`) : state.folders.has(node.key);
        const row = button('', () => { const key = query ? `closed:${node.key}` : node.key; state.folders.has(key) ? state.folders.delete(key) : state.folders.add(key); renderLibrary(); }, 'folder-row');
        const chevron = icon(expanded ? 'down' : 'right'); chevron.classList.add('chevron'); row.append(chevron, icon('folder'), el('span', '', node.name));
        row.style.paddingLeft = `${10 + depth * 14}px`; row.setAttribute('aria-expanded', expanded); list.append(row); if (expanded) walk(node, depth + 1);
      }
    }
  }
  walk(root);
}
async function chooseFolder() {
  const result = await api.chooseFolder(); if (!result) return;
  state.library.folderPath = result.folderPath; state.files = result.files; state.folders.clear(); $('#file-search').value = ''; renderLibrary();
}
async function refreshFolder() { const result = await api.refreshFolder(); if (result) { state.library.folderPath = result.folderPath; state.files = result.files; renderLibrary(); } }
async function openPath(path) { if (!path) return; const request = (state.openRequest || 0) + 1; state.openRequest = request; await persist(); const document = await api.openDocument(path); if (document && request === state.openRequest) { state.sampleOpen = false; await openDocument(document); } }
async function openFile() { const path = await api.chooseFile(); if (path) await openPath(path); }
async function openDocument(doc) {
  const epoch = ++state.epoch;
  await cancelOCR();
  if (epoch !== state.epoch) return;
  const canonical = state.library.documents[doc.id];
  if (canonical) {
    Object.assign(canonical, { id: doc.id, path: doc.path, name: doc.name, bytes: doc.bytes, isSample: doc.isSample });
    doc = canonical;
  }
  state.doc = doc; state.doc.annotations ||= []; state.selectedId = null; state.selection = null; state.autoAttempted.clear(); state.opening = true;
  if (!state.sampleOpen) state.library.selectedPath = doc.path;
  state.library.documents[doc.id] = doc;
  $('#document-title').textContent = doc.name.replace(/\.pdf$/i, ''); $('#document-title').title = doc.path;
  $('#empty-reader').hidden = true; $('#pdf-scroll').hidden = false; $('#selection-toolbar').hidden = true;
  $('#sample-back').hidden = !state.sampleOpen; $('#sample span[data-i18n]').dataset.i18n = state.sampleOpen ? '退出示例' : '打开入门示例'; localize($('#sample'));
  reader.annotations = doc.annotations; reader.selectedId = null;
  const file = state.files.find(f => f.path === doc.path);
  if (file) { const parts = file.relativePath.split(/[\\/]/).slice(0, -1); let key = ''; for (const part of parts) { key += `${part}/`; state.folders.add(key); } }
  renderLibrary(); renderNotes(); setStatus(T('正在打开 PDF…'));
  try {
    await reader.load(doc.bytes, doc.page || 0);
    if (epoch !== state.epoch) return;
    if (api.ocrCache) {
      let entries = [];
      try { entries = await api.ocrCache(doc.id, state.settings.ocrLanguage || ''); } catch (error) { toast(T(error.message)); }
      if (epoch !== state.epoch) return;
      for (const entry of entries || []) if (entry.page >= 0 && entry.page < reader.pageCount) { reader.applyOCR(entry.page, entry.result); state.autoAttempted.add(entry.page); }
    }
    doc.bytes = undefined; state.opening = false; setStatus('');
    reader.setAnnotations(doc.annotations, null);
    if (!state.sampleOpen) autoOCR(reader.currentPage);
    else await seedSample();
  } catch (error) { if (epoch === state.epoch) { state.opening = false; setStatus(T('无法打开 PDF')); showError(error); } }
}
async function toggleSample() {
  if (state.sampleOpen) {
    const previous = state.samplePrevious; state.sampleOpen = false; state.samplePrevious = null;
    if (previous?.path) await openPath(previous.path);
    else {
      await persist(); await cancelOCR(); const epoch = ++state.epoch; await reader.clear(); if (epoch !== state.epoch) return; state.doc = null; state.selectedId = null; state.selection = null;
      $('#sample-back').hidden = true; $('#sample span[data-i18n]').dataset.i18n = '打开入门示例'; localize($('#sample'));
      $('#document-title').textContent = T('你的阅读空间'); $('#document-title').title = ''; $('#pdf-scroll').hidden = true; $('#empty-reader').hidden = false;
      $('#selection-toolbar').hidden = true; $('#page-number').value = 0; $('#page-total').textContent = '/ 0'; setStatus(''); renderNotes(); renderLibrary();
    }
    return;
  }
  await persist(); const doc = await api.sample(); if (!doc) return;
  state.samplePrevious = state.doc ? { path: state.doc.path, page: state.doc.page } : null; state.sampleOpen = true;
  await openDocument(doc);
}
async function seedSample() {
  // Stable ID means deleting the seeded passage does not recreate it.
  const doc = state.doc, epoch = state.epoch;
  const id = 'e6170b77-72d0-47f7-823a-cf279301f820';
  const known = doc.annotations.find(a => a.id === id);
  if (known) { if (!known.deletedAt) focusAnnotation(id); return; }
  const index = Math.min(2, reader.pageCount - 1); reader.jump(index); await reader.renderPage(index);
  if (epoch !== state.epoch || state.doc?.id !== doc.id) return;
  const layer = reader.records[index]?.textLayer; if (!layer) return;
  const spans = [...layer.querySelectorAll('span')], full = spans.map(s => s.textContent).join(' ');
  const match = /I\s+do\s+not\s+see\s+how\s+one\s+can\s+look\s+at\s+figures\s+like\s+these[\s\S]*?about\s+anything\s+(?:else|rise)\./i.exec(full);
  if (!match) return;
  const box = reader.records[index].el.getBoundingClientRect(), rects = []; let offset = 0;
  for (const span of spans) {
    const end = offset + span.textContent.length;
    if (end > match.index && offset < match.index + match[0].length) { const r = span.getBoundingClientRect(); rects.push({ page: index, x: (r.left - box.left) / box.width, y: (r.top - box.top) / box.height, width: r.width / box.width, height: r.height / box.height }); }
    offset = end + 1;
  }
  if (!rects.length) return;
  doc.annotations.push({ id, kind: 'highlight', quote: match[0], page: index, rects, color: 'A8DCC5', comment: '', messages: [], createdAt: new Date().toISOString(), deletedAt: null, sourceFilename: doc.name });
  await persist(doc); if (epoch === state.epoch) focusAnnotation(id);
}

function focusAnnotation(id, navigate = true) {
  const annotation = activeAnnotations().find(a => a.id === id); if (!annotation) return;
  state.selectedId = id; $('#selection-toolbar').hidden = true;
  reader.setAnnotations(currentAnnotations(), id);
  if (navigate) reader.jump(annotation.page, annotation.rects?.[0]);
  renderNotes();
  if (annotation.kind === 'question') void readThread(annotation).catch(showError);
}
async function createAnnotation(kind, snapshot = state.selection) {
  if (!state.doc || !snapshot?.quote || !snapshot.rects?.length) return;
  if (snapshot.quote.length > 16000) throw new Error(T('选中文字过长，请缩小范围。'));
  const a = { id: crypto.randomUUID(), kind, quote: snapshot.quote, page: snapshot.page, rects: snapshot.rects,
    color: state.settings.highlightColorHex || 'A8DCC5', comment: '', messages: [], createdAt: new Date().toISOString(), deletedAt: null,
    sourceFilename: state.doc.name, contextScope: state.settings.contextScope, contextPages: state.settings.contextPages };
  state.doc.annotations.push(a); await persist(); window.getSelection()?.removeAllRanges(); state.selection = null;
  focusAnnotation(a.id, false); if (kind === 'comment') $('#comment-input')?.focus(); if (kind === 'question') $('#question-input')?.focus();
}
async function deleteAnnotation(a) {
  if (state.jobs.has(a.id) || state.sending.has(a.id)) return;
  const doc = state.doc; a.deletedAt = new Date().toISOString(); state.selectedId = null; await persist(doc); reader.setAnnotations(doc.annotations); renderNotes();
  toast(T('已移到回收站，可在设置中恢复。'), { label: '撤销', run: async () => { a.deletedAt = null; await persist(doc); if (state.doc?.id === doc.id) { reader.setAnnotations(doc.annotations); renderNotes(); } } }, 5000);
}
function renderNotes() {
  const container = $('#notes'), scroll = container.scrollTop;
  const previousThread = container.dataset.annotationId, previousMessages = $('#chat-messages', container), previousScroll = previousMessages?.scrollTop || 0;
  container.replaceChildren();
  const annotations = activeAnnotations(); $('#note-count').textContent = annotations.length;
  const a = selected();
  container.dataset.annotationId = a?.id || '';
  if (!a) {
    if (!annotations.length) { const empty = el('div', 'notes-empty notes-empty-prompt'); empty.append(icon('message'), el('h3', '', T('先从一段文字开始')), el('p', '', T('在 PDF 中拖选文字，选择“评论”或“问 AI”。\n每段讨论都能回到原文的位置。'))); container.append(empty); return; }
    for (const note of [...annotations].sort((a, b) => a.page - b.page || String(a.createdAt || '').localeCompare(String(b.createdAt || '')))) {
      const card = el('article', 'note-card'); card.tabIndex = 0; card.setAttribute('role', 'button');
      const meta = el('div', 'note-meta'); meta.append(icon(note.kind === 'question' ? 'sparkles' : note.kind === 'comment' ? 'message' : 'highlight'), el('span', '', T(kindLabel(note.kind))), el('span', 'spacer'), el('span', '', T(`第 ${note.page + 1} 页`)));
      const quote = el('blockquote', '', note.quote); quote.style.borderColor = `#${note.color}`; card.append(meta, quote);
      if (note.comment) card.append(el('div', 'note-preview', note.comment));
      if (note.kind === 'question') card.append(el('div', 'note-preview', note.messages?.length ? `${note.messages.length} ${T('条发言')}` : T('尚未提问')));
      card.addEventListener('click', () => focusAnnotation(note.id)); card.addEventListener('keydown', e => { if (e.key === 'Enter') focusAnnotation(note.id); }); container.append(card);
    }
    return;
  }
  const heading = el('div', 'detail-heading');
  heading.append(button('全部笔记', () => { state.selectedId = null; reader.setAnnotations(currentAnnotations()); renderNotes(); }, 'text-button', 'left'));
  const tools = el('div', 'annotation-tools'); tools.append(el('span', 'annotation-kind', T(kindLabel(a.kind))));
  const trash = button('', () => deleteAnnotation(a), 'icon-button', 'trash'); trash.title = T('移到最近删除'); trash.disabled = state.jobs.has(a.id) || state.sending.has(a.id); tools.append(trash);
  const changeColor = async value => { a.color = value; reader.setAnnotations(currentAnnotations(), a.id); scheduleSave(); const q = $('.source-quote', container); if (q) q.style.borderColor = `#${value}`; const swatch = $('.annotation-color-swatch', tools); if (swatch) swatch.style.backgroundColor = `#${value}`; };
  const presets = button('', event => presetColorMenu(event.currentTarget, changeColor), 'icon-button', 'palette'); presets.title = T('预设颜色'); presets.setAttribute('aria-label', T('预设颜色'));
  tools.append(presets, colorButton(() => a.color || 'A8DCC5', '标注颜色', changeColor)); heading.append(tools); container.append(heading);
  const source = el('div', 'source-card'), caption = el('div', 'source-caption'), quote = el('blockquote', 'source-quote', a.quote);
  caption.append(el('span', '', `${T(`第 ${a.page + 1} 页`)} · ${T('引用原文')}`)); const locate = button('', () => reader.jump(a.page, a.rects?.[0]), 'icon-button', 'target'); locate.title = T('定位原文'); caption.append(locate);
  quote.style.borderColor = `#${a.color}`; quote.addEventListener('click', () => reader.jump(a.page, a.rects?.[0])); source.append(caption, quote); container.append(source);
  if (a.kind === 'comment') {
    container.append(el('p', 'muted small', T('你的评论')));
    const input = el('textarea', 'annotation-comment'); input.id = 'comment-input'; input.value = a.comment || ''; input.setAttribute('aria-label', T('你的评论'));
    input.addEventListener('input', () => { a.comment = input.value; scheduleSave(); }); container.append(input, el('p', 'muted small', T('自动保存到本机')));
    const actions = el('div', 'comment-actions'); actions.append(button('也向 AI 讨论这段文字', () => createAnnotation('question', a))); container.append(actions);
  } else if (a.kind === 'highlight') {
    const empty = el('div', 'notes-empty'); empty.append(icon('highlight'), el('p', '', T('这段高亮已经保存'))); container.append(empty, button('问 AI', () => createAnnotation('question', a)));
  } else renderConversation(a, container);
  container.scrollTop = scroll;
  if (a.kind === 'question') {
    state.messageCounts ||= new Map();
    const changed = state.messageCounts.get(a.id) !== (a.messages?.length || 0); state.messageCounts.set(a.id, a.messages?.length || 0);
    const messages = $('#chat-messages', container);
    if (messages) requestAnimationFrame(() => { if (messages.isConnected) messages.scrollTop = changed || previousThread !== a.id ? messages.scrollHeight : previousScroll; });
  }
}
function kindLabel(kind) { return { highlight: '高亮', comment: '评论', question: 'AI 讨论' }[kind] || '高亮'; }

export function markdown(text) {
  const math = [], nonce = crypto.randomUUID().replaceAll('-', '');
  // The extension runs within Markdown's inline tokenizer. Fenced and inline
  // code are consumed by their own tokens, so TeX examples stay literal.
  const parser = new Marked({ breaks: true, gfm: true, extensions: [{
    name: 'marginMath', level: 'inline',
    start(source) { return source.search(/\\\[|\$\$|\\\(|\$(?!\$)/); },
    tokenizer(source) {
      const match = /^(?:\\\[([\s\S]+?)\\\]|\$\$([\s\S]+?)\$\$|\\\(([^\n]+?)\\\)|\$([^$\n]+?)\$(?!\$))/.exec(source);
      if (!match) return;
      return { type: 'marginMath', raw: match[0], text: match[1] ?? match[2] ?? match[3] ?? match[4], display: match[1] != null || match[2] != null };
    },
    renderer(token) { const index = math.length; math.push(token); return `MARGIN${nonce}MATH${index}END`; }
  }] });
  const body = el('div', 'message-body');
  body.innerHTML = DOMPurify.sanitize(parser.parse(String(text)), { FORBID_TAGS: ['img', 'iframe', 'object', 'embed', 'style', 'form', 'input', 'button'], FORBID_ATTR: ['style', 'srcset'], ALLOW_DATA_ATTR: false });
  const walker = document.createTreeWalker(body, NodeFilter.SHOW_TEXT); const nodes = []; while (walker.nextNode()) nodes.push(walker.currentNode);
  const pattern = new RegExp(`MARGIN${nonce}MATH(\\d+)END`, 'g');
  for (const node of nodes) {
    const matches = [...node.textContent.matchAll(pattern)]; if (!matches.length) continue;
    const fragment = document.createDocumentFragment(); let start = 0;
    for (const match of matches) {
      fragment.append(document.createTextNode(node.textContent.slice(start, match.index)));
      const value = math[Number(match[1])], span = el('span');
      if (node.parentElement.closest('code,pre')) span.textContent = value.raw;
      else try { katex.render(value.text, span, { displayMode: value.display, throwOnError: false, trust: false, strict: 'ignore', maxExpand: 1000, maxSize: 20 }); } catch { span.textContent = value.text; }
      fragment.append(span); start = match.index + match[0].length;
    }
    fragment.append(document.createTextNode(node.textContent.slice(start))); node.replaceWith(fragment);
  }
  for (const a of $$('a', body)) { a.addEventListener('click', safe(async event => { event.preventDefault(); if (api.openExternal && /^https?:\/\//.test(a.href)) await api.openExternal(a.href); })); a.rel = 'noopener noreferrer'; }
  return body;
}
function renderConversation(a, container) {
  const intro = el('div', 'detail-heading'); intro.append(el('span', '', T('围绕这段原文讨论')));
  if (a.messages?.length) intro.append(button(a.collapsed ? '展开对话' : '折叠对话', () => { a.collapsed = !a.collapsed; scheduleSave(); renderNotes(); }, 'text-button')); container.append(intro);
  const messages = el('div', 'chat-messages'); messages.id = 'chat-messages';
  if (!a.collapsed) {
    for (const message of a.messages || []) messages.append(messageBubble(message));
    const job = state.jobs.get(a.id);
    if (job) { const partial = el('div', 'chat-message'); partial.append(el('div', 'message-meta', T('正在思考与回复…'))); if (job.text) partial.append(markdown(job.text)); messages.append(partial); }
    if (!a.messages?.length && !job) messages.append(el('p', 'notes-empty', T('有什么让你停下来思考？\n问概念、推导，或让 AI 举一个例子。')));
  } else messages.append(el('p', 'muted small', `${a.messages.length} ${T('条发言')}`));
  container.append(messages);
  if (state.errors.get(a.id)) container.append(el('p', 'chat-state error', T(state.errors.get(a.id))));
  const composer = el('div', 'chat-composer'), input = el('textarea'); input.id = 'question-input'; input.placeholder = T(a.messages?.length ? '继续追问…' : '输入你的问题…'); input.value = state.drafts.get(a.id) || ''; input.maxLength = 16000;
  input.addEventListener('input', () => { state.drafts.set(a.id, input.value); const send = $('#send-question'); if (send) send.disabled = !input.value.trim() || !state.account.authenticated || !state.account.planEnabled || state.sending.has(a.id); });
  input.addEventListener('keydown', safe(async event => { if (event.key === 'Enter' && event.ctrlKey) { event.preventDefault(); await sendQuestion(a); } })); composer.append(input);
  const actions = el('div', 'compose-actions');
  const context = button('', event => contextPopover(event.currentTarget, a), 'context-button'); context.id = 'context-button';
  context.title = T('AI 参考范围'); context.setAttribute('aria-label', `${T('AI 参考范围')}: ${T(scopes[a.contextScope || state.settings.contextScope])}`);
  context.append(icon('file'), el('span', '', T(scopes[a.contextScope || state.settings.contextScope])), icon('down')); context.disabled = state.jobs.has(a.id) || state.sending.has(a.id); actions.append(context);
  if (state.jobs.has(a.id)) actions.append(button('停止', async () => { await api.chat('/api/chat/cancel', { jobId: state.jobs.get(a.id).jobId }); }));
  else { const send = button('发送', () => sendQuestion(a), 'primary', 'send'); send.id = 'send-question'; send.disabled = !input.value.trim() || !state.account.authenticated || !state.account.planEnabled || state.sending.has(a.id); actions.append(send); }
  composer.append(actions); container.append(composer);
}
function contextPopover(anchor, a) {
  const content = el('div', 'context-popover'); content.append(el('h3', '', T('AI 参考范围')));
  const group = el('div', 'context-options'); group.setAttribute('role', 'radiogroup'); group.setAttribute('aria-label', T('AI 参考范围')); content.append(group);
  const pages = el('input', 'context-pages'); pages.placeholder = T('例如 1-3, 5'); pages.setAttribute('aria-label', T('参考页码')); pages.value = a.contextPages || ''; content.append(pages);
  const pageHelp = el('p', 'context-help', T('使用 PDF 页序，与阅读区底部页码一致。')), summary = el('p', 'context-summary'); content.append(pageHelp, summary);
  function update() {
    const scope = a.contextScope || state.settings.contextScope;
    pages.hidden = pageHelp.hidden = scope !== 'custom';
    if (scope === 'custom' && !a.contextPages) { a.contextPages = String(a.page + 1); pages.value = a.contextPages; }
    try { const numbers = contextPages(scope, a.contextPages || '', a.page + 1, reader.pageCount); summary.textContent = numbers.length ? `${T('参考页码')}: ${compactPages(numbers)}` : ''; } catch { summary.textContent = ''; }
    const label = $('span', anchor); if (label) label.textContent = T(scopes[scope]);
    anchor.setAttribute('aria-label', `${T('AI 参考范围')}: ${T(scopes[scope])}`);
  }
  for (const [value, label] of Object.entries(scopes)) {
    const row = el('label'), radio = el('input'); radio.type = 'radio'; radio.name = 'chat-context'; radio.value = value; radio.checked = value === (a.contextScope || state.settings.contextScope);
    radio.addEventListener('change', () => { a.contextScope = value; update(); scheduleSave(); }); row.append(radio, el('span', '', T(label))); group.append(row);
  }
  pages.addEventListener('input', () => { a.contextPages = pages.value; update(); scheduleSave(); });
  content.append(el('p', 'context-help', T('每次发送都会附加选中文字，并保留本条讨论历史。')));
  const footer = el('div', 'popover-actions'); footer.append(button('完成', closePopover, 'primary')); content.append(footer); update(); popover(anchor, content, 300);
}
function messageBubble(message) {
  const bubble = el('div', `chat-message ${message.role === 'user' ? 'user' : ''} ${message.status === 'failed' || message.failed ? 'failed' : ''}`);
  const meta = el('div', 'message-meta'); meta.append(el('span', '', message.role === 'user' ? T('你') : 'AI')); if (message.role !== 'user') meta.append(el('span', '', [message.model, message.effort].filter(Boolean).join(' · '))); bubble.append(meta);
  const body = message.role === 'user' ? el('div', 'message-body', message.text) : markdown(message.text);
  if (message.role === 'user') body.style.whiteSpace = 'pre-wrap';
  const long = message.text.length > 1000, expanded = state.expandedMessages.has(message.id); if (long && !expanded) body.classList.add('folded'); bubble.append(body);
  if (long) bubble.append(button(expanded ? '收起长回复' : '展开完整回复', () => { if (expanded) state.expandedMessages.delete(message.id); else state.expandedMessages.add(message.id); renderNotes(); }, 'fold-button'));
  if (message.reference) bubble.append(el('div', 'message-meta', `${T('参考')}: ${T(scopes[message.reference.scope] || '')}${message.reference.pages?.length ? ` · ${compactPages(message.reference.pages)}` : ''}`));
  if (message.error || message.status === 'failed' || message.failed) bubble.append(el('div', 'message-error', T(message.error || '这次发送未完成，可在下方重试')));
  return bubble;
}
const scopes = { selection: '仅选中文字', page: '划线所在页', nearby: '前后各一页', custom: '指定页码', document: '整份文档' };
function compactPages(pages) { const spans = []; for (let i = 0; i < pages.length; i++) { const first = pages[i]; let last = first; while (pages[i + 1] === last + 1) last = pages[++i]; spans.push(first === last ? String(first) : `${first}–${last}`); } return spans.join(', '); }
export function contextPages(scope, range, anchor, total) {
  if (!Number.isInteger(anchor) || anchor < 1 || anchor > total) throw new Error('请先打开 PDF。');
  if (scope === 'selection') return [];
  if (scope === 'page') return [anchor];
  if (scope === 'nearby') return Array.from({ length: Math.min(total, anchor + 1) - Math.max(1, anchor - 1) + 1 }, (_, i) => Math.max(1, anchor - 1) + i);
  if (scope === 'document') { if (total > 200) throw new Error('参考范围最多 200 页，请缩小范围。'); return Array.from({ length: total }, (_, i) => i + 1); }
  if (scope !== 'custom') throw new Error('请输入有效页码，例如 1-3, 5。');
  const pages = new Set();
  for (const part of String(range).replace(/[，、]/g, ',').replace(/[–—]/g, '-').split(',')) {
    const match = /^\s*(\d+)\s*(?:-\s*(\d+)\s*)?$/.exec(part); if (!match) throw new Error('请输入有效页码，例如 1-3, 5。');
    const first = Number(match[1]), last = Number(match[2] || first);
    if (first < 1 || last < first || last > total) throw new Error('请输入有效页码，例如 1-3, 5。');
    if (last - first >= 200) throw new Error('参考范围最多 200 页，请缩小范围。');
    for (let p = first; p <= last; p++) pages.add(p);
    if (pages.size > 200) throw new Error('参考范围最多 200 页，请缩小范围。');
  }
  return [...pages].sort((a, b) => a - b);
}
async function buildReference(a) {
  const scope = a.contextScope || state.settings.contextScope, total = reader.pageCount;
  const numbers = contextPages(scope, a.contextPages || '', a.page + 1, total), pages = []; let length = 0; const missing = [];
  for (const page of numbers) { const text = (await reader.text(page - 1)).trim(); if (!text) missing.push(page); length += text.length; if (length > 100000) throw new Error(T('参考文字超过 100,000 字符，请缩小页码范围。')); pages.push({ page, text }); }
  if (missing.length) throw new Error(`${T('以下页面尚无可用文字，请先运行本地 OCR 或调整范围：')} ${missing.join(', ')}`);
  return { scope, pages, totalPages: total };
}
async function readThread(a, doc = state.doc) {
  const result = await api.chat(`/api/chat/thread?id=${encodeURIComponent(a.id)}`);
  if (result.messages) { a.messages = result.messages; scheduleSave(doc); }
  if (result.busy && result.jobId && !state.jobs.has(a.id)) { state.jobs.set(a.id, { jobId: result.jobId, text: '', doc }); void pollJob(a, doc); }
  if (state.doc?.id === doc?.id && state.selectedId === a.id) renderNotes();
}
async function sendQuestion(a) {
  if (state.jobs.has(a.id) || state.sending.has(a.id)) return;
  const text = (state.drafts.get(a.id) || '').trim(); if (!text) return;
  if (!state.account.authenticated || !state.account.planEnabled) throw new Error(T('请先登录并授权 ChatGPT 套餐'));
  const doc = state.doc, epoch = state.epoch;
  state.errors.delete(a.id); state.sending.add(a.id); renderNotes();
  try {
    const reference = await buildReference(a); if (epoch !== state.epoch) return;
    const customInstructions = state.settings.customInstructions;
    if (customInstructions.length > 16000) throw new Error(T('个性化指令过长，请缩短至 16,000 个字符以内。'));
    const context = { filename: a.sourceFilename || doc.name, quote: a.quote, page: a.page + 1, pageText: '' };
    const result = await api.chat('/api/chat/start', { threadId: a.id, documentId: doc.id, context, reference,
      model: state.settings.selectedModel, effort: state.settings.selectedEffort || 'auto', text, customInstructions, requestId: crypto.randomUUID() });
    state.jobs.set(a.id, { jobId: result.jobId, text: '', doc }); state.drafts.set(a.id, '');
    await readThread(a, doc); renderNotes(); void pollJob(a, doc);
  } catch (error) { state.errors.set(a.id, error.message); renderNotes(); }
  finally { state.sending.delete(a.id); if (state.selectedId === a.id && state.doc?.id === doc.id) renderNotes(); }
}
async function pollJob(a, doc) {
  const job = state.jobs.get(a.id); if (!job || job.polling) return; job.polling = true;
  try {
    while (state.jobs.get(a.id) === job) {
      const result = await api.chat(`/api/chat/status?id=${encodeURIComponent(job.jobId)}`);
      job.text = result.text || '';
      if (result.status !== 'running') {
        if (result.error) state.errors.set(a.id, result.error);
        state.jobs.delete(a.id); await readThread(a, doc); await persist(doc); break;
      }
      if (state.selectedId === a.id && state.doc?.id === doc.id) updatePartial(a, job);
      await new Promise(resolve => setTimeout(resolve, 650));
    }
  } catch (error) { state.jobs.delete(a.id); state.errors.set(a.id, error.message); await readThread(a, doc).catch(() => {}); }
  if (state.selectedId === a.id && state.doc?.id === doc.id) renderNotes();
}
function updatePartial(a, job) {
  const box = $('#chat-messages'); if (!box || a.collapsed) return;
  const atBottom = box.scrollHeight - box.scrollTop - box.clientHeight < 45;
  let partial = $('.live-partial', box);
  if (!partial) { const existing = [...box.children].find(node => node.textContent.startsWith(T('正在思考与回复…'))); existing?.remove(); partial = el('div', 'chat-message live-partial'); box.append(partial); }
  partial.replaceChildren(el('div', 'message-meta', T('正在思考与回复…')), markdown(job.text));
  if (atBottom) box.scrollTop = box.scrollHeight;
}
async function refreshAccount() {
  if (state.accountRefreshing) return;
  state.accountRefreshing = true;
  try {
    state.account = await api.chat('/api/status');
    state.accountError = null;
    if (state.account.models?.length) state.models = state.account.models;
    if (state.account.authenticated && (!state.models.length || !state.accountWasAuthenticated)) {
      const result = await api.chat('/api/models'); state.models = result.models || [];
    }
    await reconcileModels();
    const changed = state.accountWasAuthenticated !== state.account.authenticated;
    state.accountWasAuthenticated = state.account.authenticated; renderAccount(); if (changed && selected()?.kind === 'question') renderNotes();
  } catch (error) { state.accountError = error.message; renderAccount(); }
  finally { state.accountRefreshing = false; }
}
async function reconcileModels() {
  if (!state.models.length || !state.account.authenticated) return;
  const model = state.models.find(m => m.id === state.settings.selectedModel) || state.models[0];
  const efforts = model.efforts?.length ? model.efforts : ['auto'];
  const effort = efforts.includes(state.settings.selectedEffort) ? state.settings.selectedEffort : efforts.includes(model.defaultEffort) ? model.defaultEffort : efforts[0];
  if (model.id !== state.settings.selectedModel || effort !== state.settings.selectedEffort) await settings({ selectedModel: model.id, selectedEffort: effort });
}
function renderAccount() {
  const renderKey = JSON.stringify([state.account.authenticated, state.account.planEnabled, state.account.auth, state.account.lastError,
    state.accountError, state.models, state.settings.selectedModel, state.settings.selectedEffort, state.settings.language]);
  if (state.accountRenderKey === renderKey) return;
  state.accountRenderKey = renderKey;
  const container = $('#account'); container.replaceChildren();
  const line = el('div', 'account-line'), connected = state.account.authenticated && state.account.planEnabled;
  line.append(el('span', `status-dot ${connected ? 'connected' : ''}`), el('span', 'account-label', T(state.account.authenticated ? 'ChatGPT 已连接' : '连接 ChatGPT 后即可提问')));
  if (state.account.authenticated) {
    const menu = button('', event => {
      const list = el('div', 'compact-menu');
      list.append(button('刷新模型', async () => { closePopover(); const result = await api.chat('/api/models'); state.models = result.models || []; await reconcileModels(); renderAccount(); }, 'menu-item'),
        button('退出登录', async () => { closePopover(); await api.chat('/api/logout', {}); state.models = []; await refreshAccount(); }, 'menu-item'));
      popover(event.currentTarget, list, 155);
    }, 'icon-button', 'ellipsis'); menu.setAttribute('aria-label', 'ChatGPT'); line.append(menu);
  } else line.append(button('登录', async () => { await api.chat('/api/auth/start', {}); await refreshAccount(); }));
  container.append(line);
  if (state.models.length && state.account.authenticated) {
    const models = el('div', 'account-models'), select = el('select'); select.setAttribute('aria-label', T('模型'));
    for (const model of state.models) { const o = el('option', '', model.name); o.value = model.id; select.append(o); } select.value = state.settings.selectedModel;
    const effort = el('select'); effort.setAttribute('aria-label', T('推理强度'));
    const model = state.models.find(m => m.id === select.value) || state.models[0];
    for (const value of model?.efforts || ['auto']) { const o = el('option', '', T({ auto:'自动', low:'低', medium:'中', high:'高', xhigh:'很高', max:'最高' }[value] || value)); o.value = value; effort.append(o); }
    effort.value = state.settings.selectedEffort; if (!effort.value) effort.value = model.defaultEffort || 'auto';
    select.addEventListener('change', safe(async () => { const next = state.models.find(m => m.id === select.value); await settings({ selectedModel: select.value, selectedEffort: next.defaultEffort || 'auto' }); renderAccount(); }));
    effort.addEventListener('change', safe(() => settings({ selectedEffort: effort.value }))); models.append(select, effort); container.append(models);
  }
  const message = !state.account.authenticated && state.account.auth?.status !== 'idle' && (state.account.auth?.message || state.account.auth?.status === 'pending' && T('请在浏览器中完成登录…'));
  if (message) container.append(el('p', 'account-message', T(message)));
  const error = state.account.lastError || state.accountError; if (error) container.append(el('p', 'account-message account-error', T(error)));
}

async function autoOCR(index) {
  if (state.opening || state.ocrBusy || state.ocrCancelling || state.ocrReloading || !state.doc || !state.ocrInfo || state.autoAttempted.has(index)) return;
  const epoch = state.epoch;
  try {
    const text = await reader.text(index);
    if (text.trim() || epoch !== state.epoch || index !== reader.currentPage || state.ocrBusy || state.ocrCancelling) return;
    if (!state.ocrInfo.available) { setStatus(T(state.ocrInfo.error || '本地 OCR 不可用，请在 Windows 设置中安装 OCR 语言包。')); return; }
    state.autoAttempted.add(index); await recognize([index], true);
  } catch (error) { if (epoch === state.epoch) setStatus(T(error.message)); }
}
async function recognize(indices, automatic = false) {
  if (!state.doc || state.ocrBusy || state.ocrReloading) return;
  if (!state.ocrInfo?.available) { const error = state.ocrInfo?.error || T('本地 OCR 不可用，请在 Windows 设置中安装 OCR 语言包。'); if (automatic) setStatus(error); else throw new Error(error); return; }
  const token = ++state.ocrToken, epoch = state.epoch, id = state.doc.id, language = state.settings.ocrLanguage || '';
  state.ocrBusy = true; state.ocrMode = automatic ? 'auto' : indices.length > 1 ? 'document' : 'page'; let completed = 0, emptyPage = false;
  renderOCRMenu();
  try {
    for (const index of indices) {
      if (token !== state.ocrToken || epoch !== state.epoch) break;
      const text = await reader.nativeText(index);
      if (token !== state.ocrToken || epoch !== state.epoch) break;
      if (text.trim()) { completed++; continue; }
      state.ocrPage = index;
      setStatus(`${T('本地 OCR')} · ${T(`第 ${index + 1} 页`)}${indices.length > 1 ? ` · ${completed}/${indices.length}` : ''}`, true);
      const raster = await reader.raster(index);
      if (token !== state.ocrToken || epoch !== state.epoch) break;
      const result = await api.ocr({ documentId: id, page: index, ...raster, language: language || undefined });
      if (token !== state.ocrToken || epoch !== state.epoch) break;
      reader.applyOCR(index, result); completed++;
      if (!result.text?.trim() && indices.length === 1) emptyPage = true;
    }
    if (token === state.ocrToken && epoch === state.epoch) setStatus(completed && !emptyPage ? '' : T('未识别到文字'));
  } catch (error) { if (token === state.ocrToken && epoch === state.epoch) { setStatus(T(error.message)); if (!automatic) showError(error); } }
  finally { if (token === state.ocrToken) { state.ocrBusy = false; const text = state.status; setStatus(text); renderOCRMenu(); } }
}
async function cancelOCR() {
  state.ocrToken++;
  if (state.ocrBusy) {
    if (state.ocrMode === 'auto') state.autoAttempted.delete(state.ocrPage);
    state.ocrBusy = false; state.ocrCancelling = true;
    try { await api.cancelOCR(); setStatus(T('文字识别已取消')); } finally { state.ocrCancelling = false; renderOCRMenu(); }
  }
}
function interfaceLocale() { return { zhHans: 'zh-CN', zhHant: 'zh-TW' }[resolveLanguage(state.settings.language)] || resolveLanguage(state.settings.language); }
export function localizedOCRLanguage(tag, language = interfaceLocale()) {
  try { return new Intl.DisplayNames([language], { type: 'language', languageDisplay: 'standard' }).of(tag) || tag; } catch { return tag; }
}
function renderOCRMenu() {
  const select = $('#ocr-language'), current = state.settings.ocrLanguage || '';
  select.replaceChildren();
  const automatic = el('option', '', T('自动')); automatic.value = ''; select.append(automatic);
  for (const item of state.ocrInfo?.languages || []) { const option = el('option', '', localizedOCRLanguage(item.tag)); option.value = item.tag; select.append(option); }
  select.value = current; select.setAttribute('aria-label', T('OCR 语言'));
  $('#ocr-page').disabled = $('#ocr-document').disabled = !state.doc || state.ocrBusy || state.ocrReloading;
  $('#ocr-cancel').hidden = !state.ocrBusy;
}
async function changeOCRLanguage(language) {
  const generation = (state.ocrLanguageGeneration || 0) + 1; state.ocrLanguageGeneration = generation;
  const epoch = state.epoch, document = state.doc; state.ocrReloading = true; renderOCRMenu();
  try {
    await cancelOCR();
    await settings({ ocrLanguage: language });
    if (generation !== state.ocrLanguageGeneration || epoch !== state.epoch || state.doc?.id !== document?.id) return;
    if (!document) return;
    reader.clearOCR(); state.autoAttempted.clear(); state.selection = null; $('#selection-toolbar').hidden = true; window.getSelection()?.removeAllRanges();
    const entries = api.ocrCache ? await api.ocrCache(document.id, language) : [];
    if (generation !== state.ocrLanguageGeneration || epoch !== state.epoch) return;
    for (const entry of entries) if (entry.page >= 0 && entry.page < reader.pageCount) { reader.applyOCR(entry.page, entry.result); state.autoAttempted.add(entry.page); }
    if ($('#pdf-search').value) { await reader.search($('#pdf-search').value); updateSearchCount(); }
    setStatus('');
  } finally {
    if (generation === state.ocrLanguageGeneration) { state.ocrReloading = false; renderOCRMenu(); if (state.doc) void autoOCR(reader.currentPage); }
  }
}

function openSettings(section = 'general') { state.settingsSection = section; renderSettings(); if (!$('#settings-dialog').open) $('#settings-dialog').showModal(); }
function settingsCard(title, description) { const card = el('div', 'settings-card'); if (title) card.append(el('h3', '', T(title))); if (description) card.append(el('p', '', T(description))); return card; }
function settingsRow(label, control) { const row = el('div', 'settings-row'); row.append(el('span', '', T(label)), control); return row; }
function rangeControl(card, label, key, min, max, step, format) {
  const group = el('div', 'settings-range');
  const value = el('span', 'muted', format(state.settings[key])), row = settingsRow(label, value);
  const range = el('input'); range.type = 'range'; range.min = min; range.max = max; range.step = step; range.value = state.settings[key]; range.setAttribute('aria-label', T(label));
  range.addEventListener('input', safe(async () => { value.textContent = format(Number(range.value)); await settings({ [key]: Number(range.value) }); if (key === 'textSize') { const preview = $('.font-preview'); if (preview) preview.style.fontSize = `${range.value}px`; } })); group.append(row, range); card.append(group);
}
function colorControl(label, key) { const color = el('input'); color.type = 'color'; color.dataset.settingColor = key; color.value = `#${state.settings[key]}`; color.title = T(label); color.addEventListener('input', safe(() => settings({ [key]: color.value.slice(1).toUpperCase() }))); return settingsRow(label, color); }
function renderSettings() {
  const body = $('#settings-body'); body.replaceChildren();
  for (const b of $$('[data-section]')) b.classList.toggle('active', b.dataset.section === state.settingsSection);
  $('.settings-version').textContent = `Margin ${state.version} · Windows`;
  if (state.settingsSection === 'general') {
    body.append(el('h2', '', T('通用')), el('p', 'settings-intro', T('更改会自动保存，并立即应用。')));
    const card = settingsCard();
    const language = el('select'); for (const item of supportedLanguages) { const option = el('option', '', T(item.label)); option.value = item.id; language.append(option); } language.value = state.settings.language;
    language.addEventListener('change', safe(() => settings({ language: language.value }, true))); card.append(settingsRow('界面语言', language));
    rangeControl(card, '字体大小', 'textSize', 11, 20, 1, n => `${n} pt`);
    card.append(el('p', 'small-text', T('调整界面、评论和讨论文字。PDF 正文请使用阅读区的缩放按钮。')));
    const sample = fontSample(state.settings.language), preview = el('div', 'font-preview', sample.text); preview.style.fontSize = `${state.settings.textSize}px`; preview.title = sample.attribution; card.append(preview); body.append(card);
    const records = settingsCard('本地记录');
    records.classList.add('settings-records');
    const description = T('阅读记录和设置保存在本机，不改动原始 PDF。登录凭据由 Windows 加密保存，退出登录时清除。');
    records.append(el('p', 'records-description', description), button('在 Finder 中查看', () => api.openDataFolder())); body.append(records);
  } else if (state.settingsSection === 'personalization') {
    body.append(el('h2', '', T('个性化指令')), el('p', 'settings-intro', T('写下你希望 AI 遵循的回答方式。内容自动保存，并从下一次提问或追问起应用。')));
    const card = settingsCard(), label = el('label', 'instructions-label', T('你的要求'));
    label.htmlFor = 'custom-instructions';
    const description = el('p', 'instructions-description', T('这些指令会随每次提问发送给模型，独立于 ChatGPT 账户的个性化设置。留空即可停用。'));
    description.id = 'instructions-description';
    const input = el('textarea', 'custom-instructions'); input.id = 'custom-instructions'; input.value = state.settings.customInstructions;
    input.setAttribute('aria-label', T('个性化指令')); input.setAttribute('aria-describedby', 'instructions-description instructions-error');
    const error = el('p', 'instructions-error', T('个性化指令过长，请缩短至 16,000 个字符以内。')); error.id = 'instructions-error'; error.setAttribute('role', 'status');
    const validate = () => { const tooLong = input.value.length > 16000; error.hidden = !tooLong; input.setAttribute('aria-invalid', String(tooLong)); };
    validate();
    input.addEventListener('input', safe(async () => { validate(); await settings({ customInstructions: input.value }); }));
    card.append(label, description, input, error); body.append(card);
  } else if (state.settingsSection === 'appearance') {
    body.append(el('h2', '', T('外观')), el('p', 'settings-intro', T('选择主题色或背景图片，再分别调整阅读区与侧栏的遮罩。')));
    const card = settingsCard('背景主题色'), presets = el('div', 'color-options');
    for (const preset of themePresets) { const b = button('', () => settings({ themeHex: preset.hex })); b.style.background = `#${preset.hex}`; b.title = T(preset.label); b.setAttribute('aria-label', T(preset.label)); b.setAttribute('aria-pressed', state.settings.themeHex === preset.hex); b.dataset.themeColor = preset.hex; presets.append(b); }
    card.append(presets, colorControl('自定义', 'themeHex'));
    const background = el('div', 'settings-row'); background.append(el('span', '', T('背景图片')),
      button('选择图片…', async () => { const image = await api.chooseBackground(); if (image) { state.settings.backgroundImage = image; applySettings(); renderSettings(); } }));
    if (state.settings.backgroundImage) background.append(button('移除', () => settings({ backgroundImage: null }, true))); card.append(background); body.append(card);
    const opacity = settingsCard(); rangeControl(opacity, '中心区域不透明度', 'centerOpacity', 0, 1, .05, n => `${Math.round(n * 100)}%`); rangeControl(opacity, '两侧区域不透明度', 'sidesOpacity', 0, 1, .05, n => `${Math.round(n * 100)}%`);
    opacity.append(el('p', '', T('向左拖动会露出更多背景。PDF 纸页保持不透明，确保正文清楚。')));
    const preview = el('div', 'appearance-preview'); for (const name of ['folder', 'file', 'message']) { const pane = el('div'); pane.append(icon(name)); preview.append(pane); } opacity.append(preview); body.append(opacity);
    const bubbles = settingsCard('讨论气泡'); bubbles.append(colorControl('你的发言', 'userBubble'), colorControl('AI 的回复', 'aiBubble')); body.append(bubbles);
  } else {
    body.append(el('h2', '', T('最近删除')), el('p', 'settings-intro', T('删除只会将记录移到这里。恢复后，原文位置、评论和完整对话都会回来。')),
      settingsCard('保留至你恢复', '本版不会自动永久删除，也不设恢复截止日。关闭应用后，最近删除的记录仍会保留。'));
    let count = 0;
    for (const doc of Object.values(state.library.documents)) {
      const document = state.doc?.id === doc.id ? state.doc : doc;
      for (const a of document.annotations || []) {
        if (!a.deletedAt) continue; count++;
        const item = settingsCard(); item.classList.add('trash-item');
        const restore = button('恢复', async () => { a.deletedAt = null; await persist(document); if (document.id === state.doc?.id) { reader.setAnnotations(document.annotations); renderNotes(); } renderSettings(); });
        item.append(settingsRow(kindLabel(a.kind), restore), el('blockquote', '', a.quote), el('p', 'small-text', `${document.name || document.title} · ${T(`第 ${a.page + 1} 页`)}`), el('p', 'small-text', new Date(a.deletedAt).toLocaleString())); body.append(item);
      }
    }
    if (!count) body.append(el('p', 'notes-empty', T('这里暂时是空的')));
  }
  localize($('#settings-dialog'));
}

function bind(id, handler, event = 'click') { $(id).addEventListener(event, safe(handler)); }
bind('#choose-folder', chooseFolder); bind('#empty-choose', chooseFolder); bind('#refresh', refreshFolder); bind('#open-file', openFile);
bind('#file-search', renderLibrary, 'input'); bind('#sample', toggleSample); bind('#sample-back', toggleSample);
bind('#settings', () => openSettings()); bind('#trash', () => openSettings('trash')); bind('#close-settings', () => $('#settings-dialog').close());
for (const b of $$('[data-section]')) b.addEventListener('click', () => { state.settingsSection = b.dataset.section; renderSettings(); });
for (const b of $$('[data-window]')) b.addEventListener('click', safe(async () => { if (b.dataset.window === 'close') { await Promise.all([...state.saveTimers.keys()].map(id => persist(state.doc?.id === id ? state.doc : state.library.documents[id]))); } await api.windowControl(b.dataset.window); }));
bind('#prev-page', () => reader.jump(reader.currentPage - 1)); bind('#next-page', () => reader.jump(reader.currentPage + 1));
bind('#page-number', event => { if (event.key === 'Enter') { reader.jump(Number(event.target.value) - 1); event.target.blur(); } }, 'keydown');
bind('#zoom-out', () => reader.zoom(reader.scale / 1.15)); bind('#zoom-in', () => reader.zoom(reader.scale * 1.15)); bind('#fit', () => reader.zoom(null)); bind('#zoom-value', () => reader.zoom(1));
function showSearch() { if (!state.doc) return; $('#searchbar').hidden = false; $('#pdf-search').focus(); $('#pdf-search').select(); }
function updateSearchCount() { $('#search-count').textContent = reader.hits.length ? `${reader.hitIndex + 1}/${reader.hits.length}` : $('#pdf-search').value ? T('未找到匹配') : ''; }
function nextMatch(direction) { reader.nextHit(direction); updateSearchCount(); }
bind('#find', showSearch); bind('#search-close', () => { $('#searchbar').hidden = true; $('#pdf-search').value = ''; reader.clearSearch(); updateSearchCount(); });
bind('#search-prev', () => nextMatch(-1)); bind('#search-next', () => nextMatch(1));
bind('#pdf-search', () => { clearTimeout(state.searchTimer); state.searchTimer = setTimeout(safe(async () => { $('#search-count').textContent = T('正在搜索…'); const result = await reader.search($('#pdf-search').value); if (result) updateSearchCount(); }), 250); }, 'input');
bind('#pdf-search', event => { if (event.key === 'Enter') { event.preventDefault(); nextMatch(event.shiftKey ? -1 : 1); } }, 'keydown');
bind('#ocr-menu-button', () => { renderOCRMenu(); $('#ocr-menu').hidden = !$('#ocr-menu').hidden; });
bind('#ocr-language', event => changeOCRLanguage(event.target.value), 'change');
bind('#ocr-page', () => { $('#ocr-menu').hidden = true; return recognize([reader.currentPage]); });
bind('#ocr-document', () => { $('#ocr-menu').hidden = true; return recognize(Array.from({ length: reader.pageCount }, (_, i) => i)); });
bind('#ocr-cancel', () => { $('#ocr-menu').hidden = true; return cancelOCR(); });
document.addEventListener('click', event => { if (!event.target.closest('.menu-anchor')) $('#ocr-menu').hidden = true; if (state.popover && !state.popover.contains(event.target) && !state.popoverAnchor?.contains(event.target)) closePopover(); });
$('#selection-toolbar').addEventListener('mousedown', event => { if (event.target.type !== 'color') event.preventDefault(); });
for (const b of $$('[data-annotation]')) b.addEventListener('click', safe(() => createAnnotation(b.dataset.annotation)));
for (const b of $$('[data-color]')) b.addEventListener('click', safe(() => settings({ highlightColorHex: b.dataset.color })));
bind('#selection-color', event => colorPopover(event.currentTarget, state.settings.highlightColorHex || 'A8DCC5', '自定义标注颜色', value => settings({ highlightColorHex: value })));
const commands = { folder: chooseFolder, file: openFile, find: showSearch, next: () => nextMatch(1), previous: () => nextMatch(-1), highlight: () => createAnnotation('highlight'), comment: () => createAnnotation('comment'), ask: () => createAnnotation('question'), settings: () => openSettings() };
api.onMenu?.(action => {
  if (action === 'before-close') {
    safe(async () => {
      try {
        await cancelOCR();
        const ids = [...state.saveTimers.keys()];
        for (const id of ids) { clearTimeout(state.saveTimers.get(id)); state.saveTimers.delete(id); }
        await Promise.all(ids.map(id => persist(state.doc?.id === id ? state.doc : state.library.documents[id])));
        await Promise.all([...pendingWrites]);
        await persist();
        await api.confirmClose();
      } catch (error) { await api.abortClose?.(); showError(error); }
    })();
  } else if (typeof action === 'object' && action.action === 'open-file') safe(() => openPath(action.path))();
  else if (commands[action]) safe(commands[action])();
});
document.addEventListener('keydown', safe(async event => {
  if (event.key === 'Escape') { closePopover(); $('#selection-toolbar').hidden = true; $('#ocr-menu').hidden = true; if (!$('#settings-dialog').open) { $('#searchbar').hidden = true; reader.clearSearch(); } }
  if (!event.ctrlKey || event.altKey) return;
  const key = event.key.toLowerCase(); let action;
  if (key === 'f') action = showSearch;
  else if (key === 'g') action = () => nextMatch(event.shiftKey ? -1 : 1);
  else if (key === 'o') action = event.shiftKey ? chooseFolder : openFile;
  else if (key === 'h' && event.shiftKey) action = () => createAnnotation('highlight');
  else if (key === 'm' && event.shiftKey) action = () => createAnnotation('comment');
  else if (key === 'k') action = () => createAnnotation('question');
  else if (key === ',') action = () => openSettings();
  else if ((key === '+' || key === '=') && !event.target.matches('input,textarea')) action = () => reader.zoom(reader.scale * 1.15);
  else if (key === '-' && !event.target.matches('input,textarea')) action = () => reader.zoom(reader.scale / 1.15);
  if (action) { event.preventDefault(); await action(); }
}));
for (const [id, side] of [['#split-left', 0], ['#split-right', 2]]) {
  const divider = $(id); let drag;
  divider.addEventListener('pointerdown', event => { divider.setPointerCapture(event.pointerId); divider.classList.add('dragging'); drag = { x: event.clientX, left: $('#library').getBoundingClientRect().width, right: $('#discussion').getBoundingClientRect().width, width: $('#workspace').clientWidth }; event.preventDefault(); });
  divider.addEventListener('pointermove', event => { if (!drag) return; const delta = event.clientX - drag.x; const left = side === 0 ? Math.max(180, Math.min(drag.width - drag.right - 408, drag.left + delta)) : drag.left; const right = side === 2 ? Math.max(220, Math.min(drag.width - drag.left - 408, drag.right - delta)) : drag.right; state.settings.paneProportions = [left / drag.width, (drag.width - left - right) / drag.width, right / drag.width]; applySettings(); });
  divider.addEventListener('pointerup', safe(async () => { if (!drag) return; drag = null; divider.classList.remove('dragging'); await settings({ paneProportions: state.settings.paneProportions }); }));
  divider.addEventListener('keydown', safe(async event => { if (!['ArrowLeft', 'ArrowRight'].includes(event.key)) return; event.preventDefault(); const p = [...state.settings.paneProportions], change = (event.key === 'ArrowRight' ? 1 : -1) * .015 * (side === 0 ? 1 : -1); p[side] = Math.max(.15, Math.min(.4, p[side] + change)); p[1] = 1 - p[0] - p[2]; await settings({ paneProportions: p }); }));
}
window.addEventListener('error', event => showError(event.error || event.message));
window.addEventListener('unhandledrejection', event => { event.preventDefault(); showError(event.reason); });

async function init() {
  localize();
  const bootstrap = await api.bootstrap(); state.library = bootstrap.library; state.library.documents ||= {};
  if (bootstrap.systemLocale) setSystemLocales([bootstrap.systemLocale]);
  state.settings = { ...defaults, ...bootstrap.library.settings }; state.files = bootstrap.files || []; state.version = bootstrap.version; state.dataDir = bootstrap.dataDir;
  applySettings(); renderLibrary(); renderNotes(); renderAccount(); renderOCRMenu();
  api.ocrStatus().then(result => { state.ocrInfo = result; renderOCRMenu(); if (state.doc) autoOCR(reader.currentPage); }).catch(error => { state.ocrInfo = { available: false, error: error.message, languages: [] }; renderOCRMenu(); });
  void refreshAccount(); setInterval(() => { if (!document.hidden || state.account.auth?.status === 'pending') void refreshAccount(); }, 3500);
  if (bootstrap.startupWarning) toast(bootstrap.startupWarning, null, 15000);
  const path = bootstrap.openPath || state.library.selectedPath;
  if (path) { try { await openPath(path); } catch (error) { toast(T(error.message)); } }
}
init().catch(showError);
