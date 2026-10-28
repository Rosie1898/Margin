import * as pdfjs from '../../node_modules/pdfjs-dist/build/pdf.mjs';

pdfjs.GlobalWorkerOptions.workerSrc = new URL('../../node_modules/pdfjs-dist/build/pdf.worker.mjs', import.meta.url).href;
const clamp = (n, a, b) => Math.min(b, Math.max(a, n));

/** Only reads PDFs. Annotations and OCR text live in application storage. */
export class PDFReader {
  constructor({ scroll, pages, onPage, onSelection, onAnnotation, onNeedOCR, onZoom, onError }) {
    Object.assign(this, { scroll, pages, onPage, onSelection, onAnnotation, onNeedOCR, onZoom, onError });
    this.epoch = 0; this.currentPage = 0; this.scale = 1; this.fitMode = true;
    this.records = []; this.annotations = []; this.texts = new Map(); this.ocr = new Map();
    this.rendered = new Set(); this.jobs = new Map(); this.hits = []; this.hitIndex = -1;
    this.observer = new IntersectionObserver(entries => {
      for (const entry of entries) {
        if (entry.isIntersecting) this.renderPage(Number(entry.target.dataset.page)).catch(e => this.onError?.(e));
      }
    }, { root: scroll, rootMargin: '650px 0px' });
    scroll.addEventListener('scroll', () => {
      this.onSelection?.(null);
      clearTimeout(this.scrollTimer);
      this.scrollTimer = setTimeout(() => this.trackPage(), 80);
    }, { passive: true });
    document.addEventListener('mouseup', event => {
      if (event.target.closest('#selection-toolbar')) return;
      setTimeout(() => this.readSelection(), 10);
    });
    scroll.addEventListener('keyup', event => { if (event.shiftKey) this.readSelection(); });
    pages.addEventListener('click', event => {
      if (!window.getSelection()?.isCollapsed) return;
      const pageElement = event.target.closest('.pdf-page'); if (!pageElement) return;
      const index = Number(pageElement.dataset.page), box = pageElement.getBoundingClientRect();
      const x = (event.clientX - box.left) / box.width, y = (event.clientY - box.top) / box.height;
      const annotation = this.annotations.find(a => !a.deletedAt && a.rects?.some(r => r.page === index && x >= r.x && x <= r.x + r.width && y >= r.y && y <= r.y + r.height));
      if (annotation) this.onAnnotation?.(annotation.id);
    });
    this.resizeObserver = new ResizeObserver(() => {
      clearTimeout(this.resizeTimer);
      this.resizeTimer = setTimeout(() => { if (this.pdf && this.fitMode) this.zoom(null); }, 150);
    });
    this.resizeObserver.observe(scroll);
  }

  async load(data, initialPage = 0) {
    const epoch = ++this.epoch;
    this.zoomGeneration = (this.zoomGeneration || 0) + 1;
    this.observer.disconnect();
    for (const job of this.jobs.values()) job.renderTask?.cancel();
    this.jobs.clear(); this.rendered.clear();
    const previousTask = this.loadingTask;
    this.loadingTask = null; this.pdf = null;
    this.records = []; this.texts.clear(); this.ocr.clear(); this.hits = []; this.hitIndex = -1;
    this.pages.replaceChildren(); this.scroll.scrollTop = 0; this.scroll.scrollLeft = 0;
    await this.disposeTask(previousTask);
    if (epoch !== this.epoch) return;
    const task = pdfjs.getDocument({ data: new Uint8Array(data), isEvalSupported: false,
      cMapUrl: new URL('../../node_modules/pdfjs-dist/cmaps/', import.meta.url).href, cMapPacked: true,
      standardFontDataUrl: new URL('../../node_modules/pdfjs-dist/standard_fonts/', import.meta.url).href,
      wasmUrl: new URL('../../node_modules/pdfjs-dist/wasm/', import.meta.url).href });
    this.loadingTask = task;
    let pdf;
    try { pdf = await task.promise; }
    catch (error) { if (epoch !== this.epoch) return; throw error; }
    if (epoch !== this.epoch) { await this.disposeTask(task); return; }
    this.pdf = pdf; this.currentPage = clamp(initialPage, 0, pdf.numPages - 1);
    let first;
    try { first = await pdf.getPage(1); }
    catch (error) { if (epoch !== this.epoch) return; throw error; }
    if (epoch !== this.epoch) return;
    const viewport = first.getViewport({ scale: 1 });
    this.baseWidth = viewport.width; this.baseHeight = viewport.height;
    if (this.fitMode) this.scale = this.fitScale();
    for (let i = 0; i < pdf.numPages; i++) {
      const el = document.createElement('div'); el.className = 'pdf-page'; el.dataset.page = i;
      const label = document.createElement('span'); label.className = 'page-number'; label.textContent = String(i + 1); el.append(label);
      const record = { el, width: viewport.width, height: viewport.height, pdfPage: i === 0 ? first : null, label };
      this.records.push(record); this.sizePage(record); this.pages.append(el); this.observer.observe(el);
    }
    this.onZoom?.(this.scale);
    this.jump(this.currentPage);
    await this.renderPage(this.currentPage);
    if (epoch !== this.epoch) return;
    this.trackPage();
  }

  get pageCount() { return this.pdf?.numPages || 0; }
  disposeTask(task) {
    if (!task) return Promise.resolve();
    // PDF.js 6 owns worker teardown on PDFDocumentLoadingTask, not its proxy.
    // Reuse the promise when an interrupted load and its successor both dispose it.
    this.disposals ||= new WeakMap();
    if (!this.disposals.has(task)) this.disposals.set(task, Promise.resolve().then(() => task.destroy()));
    return this.disposals.get(task);
  }
  async clear() {
    this.epoch++; this.zoomGeneration = (this.zoomGeneration || 0) + 1;
    this.observer.disconnect();
    for (const job of this.jobs.values()) job.renderTask?.cancel();
    this.jobs.clear(); this.rendered.clear(); this.records = []; this.texts.clear(); this.ocr.clear();
    const task = this.loadingTask; this.loadingTask = null; this.pdf = null; this.pages.replaceChildren();
    this.annotations = []; this.currentPage = 0; this.clearSearch();
    await this.disposeTask(task);
  }
  fitScale() { return clamp((this.scroll.clientWidth - 42) / this.baseWidth, .2, 6); }
  sizePage(r) {
    r.el.style.width = `${r.width * this.scale}px`; r.el.style.height = `${r.height * this.scale}px`;
    r.el.style.setProperty('--scale-factor', this.scale);
    r.el.style.setProperty('--total-scale-factor', this.scale);
  }
  async getPage(index) {
    const r = this.records[index]; if (!r || !this.pdf) throw new Error('Page unavailable');
    if (!r.pdfPage) r.pdfPage = await this.pdf.getPage(index + 1);
    return r.pdfPage;
  }

  async renderPage(index) {
    const r = this.records[index];
    if (!r || this.rendered.has(index)) return;
    if (this.jobs.has(index)) return this.jobs.get(index).promise;
    const epoch = this.epoch, scale = this.scale;
    const job = {};
    this.jobs.set(index, job);
    job.promise = (async () => {
      const page = await this.getPage(index);
      if (epoch !== this.epoch || scale !== this.scale) return;
      const base = page.getViewport({ scale: 1 }); r.width = base.width; r.height = base.height; this.sizePage(r);
      const viewport = page.getViewport({ scale });
      const outputScale = Math.min(window.devicePixelRatio || 1, 2, Math.sqrt(12_000_000 / (viewport.width * viewport.height)));
      const canvas = document.createElement('canvas');
      canvas.width = Math.max(1, Math.floor(viewport.width * outputScale)); canvas.height = Math.max(1, Math.floor(viewport.height * outputScale));
      r.el.append(canvas); r.canvas = canvas;
      job.renderTask = page.render({ canvasContext: canvas.getContext('2d', { alpha: false }), viewport,
        transform: outputScale !== 1 ? [outputScale, 0, 0, outputScale, 0, 0] : null });
      await job.renderTask.promise;
      if (epoch !== this.epoch || scale !== this.scale) { canvas.remove(); return; }
      const content = await page.getTextContent();
      if (epoch !== this.epoch || scale !== this.scale) return;
      const text = content.items.filter(item => 'str' in item).map(item => item.str + (item.hasEOL ? '\n' : ' ')).join('').trim();
      this.texts.set(index, text);
      const layer = document.createElement('div'); layer.className = 'textLayer'; r.el.append(layer); r.textLayer = layer;
      if (text) {
        const textLayer = new pdfjs.TextLayer({ textContentSource: content, container: layer, viewport });
        await textLayer.render();
      } else if (this.ocr.has(index)) this.buildOCRLayer(index);
      if (epoch !== this.epoch || scale !== this.scale) return;
      r.label.hidden = true; this.rendered.add(index); this.drawAnnotations(index); this.markSearch(index);
      if (!text && !this.ocr.has(index) && index === this.currentPage) this.onNeedOCR?.(index);
      this.evict();
    })().catch(error => {
      if (error?.name !== 'RenderingCancelledException' && epoch === this.epoch) throw error;
    }).finally(() => { if (this.jobs.get(index) === job) this.jobs.delete(index); });
    return job.promise;
  }

  evict() {
    for (const index of this.rendered) {
      if (Math.abs(index - this.currentPage) <= 3) continue;
      const r = this.records[index];
      r.canvas?.remove(); if (r.canvas) { r.canvas.width = 0; r.canvas.height = 0; }
      r.textLayer?.remove(); r.annotationLayer?.remove(); r.searchLayer?.remove(); r.label.hidden = false;
      r.canvas = null; r.textLayer = null; r.annotationLayer = null; this.rendered.delete(index);
    }
  }

  trackPage() {
    if (!this.records.length) return;
    const position = this.scroll.scrollTop + Math.min(130, this.scroll.clientHeight * .2);
    let low = 0, high = this.records.length - 1;
    while (low < high) { const mid = Math.ceil((low + high) / 2); if (this.records[mid].el.offsetTop <= position) low = mid; else high = mid - 1; }
    if (low !== this.currentPage) { this.currentPage = low; this.onPage?.(low, this.pageCount); }
    else this.onPage?.(low, this.pageCount);
    this.renderPage(low).catch(e => this.onError?.(e));
    if (this.rendered.has(low) && !this.texts.get(low) && !this.ocr.has(low)) this.onNeedOCR?.(low);
  }

  jump(index, rect) {
    if (!this.records.length) return;
    index = clamp(Number(index) || 0, 0, this.records.length - 1);
    const r = this.records[index], left = this.scroll.scrollLeft;
    this.currentPage = index;
    this.scroll.scrollTop = r.el.offsetTop + (rect ? rect.y * r.height * this.scale - 70 : -16);
    this.scroll.scrollLeft = left;
    this.onPage?.(index, this.pageCount);
    this.renderPage(index).catch(e => this.onError?.(e));
  }

  async zoom(value) {
    if (!this.pdf) return;
    const epoch = this.epoch;
    const generation = (this.zoomGeneration || 0) + 1; this.zoomGeneration = generation;
    this.onSelection?.(null);
    const index = this.currentPage, r = this.records[index];
    const relativeY = (this.scroll.scrollTop - r.el.offsetTop) / (r.height * this.scale);
    const relativeX = this.scroll.scrollLeft / this.scale;
    this.fitMode = value == null;
    const scale = value == null ? this.fitScale() : clamp(value, .2, 6);
    if (Math.abs(scale - this.scale) < .0001) return;
    for (const job of this.jobs.values()) job.renderTask?.cancel();
    await Promise.allSettled([...this.jobs.values()].map(job => job.promise));
    if (generation !== this.zoomGeneration || epoch !== this.epoch) return;
    this.scale = scale;
    for (const r of this.records) {
      r.canvas?.remove(); if (r.canvas) { r.canvas.width = 0; r.canvas.height = 0; }
      r.textLayer?.remove(); r.annotationLayer?.remove(); r.searchLayer?.remove(); r.canvas = null; r.textLayer = null; r.annotationLayer = null;
      this.sizePage(r);
    }
    this.rendered.clear(); this.jobs.clear();
    this.scroll.scrollTop = r.el.offsetTop + relativeY * r.height * scale;
    this.scroll.scrollLeft = this.fitMode ? 0 : relativeX * scale;
    this.onZoom?.(scale);
    this.observer.disconnect(); for (const r of this.records) this.observer.observe(r.el);
    await this.renderPage(index);
  }

  readSelection() {
    const selection = window.getSelection();
    if (!selection || selection.isCollapsed || !selection.rangeCount || !this.pages.contains(selection.anchorNode) || !this.pages.contains(selection.focusNode)) return;
    const text = selection.toString().trim();
    if (!text) return;
    const range = selection.getRangeAt(0), rects = [];
    for (const index of this.rendered) {
      const r = this.records[index], box = r.el.getBoundingClientRect();
      if (!r.textLayer || !range.intersectsNode(r.textLayer)) continue;
      // Clip each text node to the user's selection. A range crossing pages
      // also reports whole container/canvas boxes; those must never be saved.
      const boxes = [], walker = document.createTreeWalker(r.textLayer, NodeFilter.SHOW_TEXT);
      while (walker.nextNode()) {
        const node = walker.currentNode;
        if (!range.intersectsNode(node) || !node.textContent.trim()) continue;
        const fragment = document.createRange(); fragment.selectNodeContents(node);
        if (range.compareBoundaryPoints(Range.START_TO_START, fragment) > 0) fragment.setStart(range.startContainer, range.startOffset);
        if (range.compareBoundaryPoints(Range.END_TO_END, fragment) < 0) fragment.setEnd(range.endContainer, range.endOffset);
        if (!fragment.collapsed) boxes.push(...fragment.getClientRects());
      }
      for (const b of boxes) {
        const x = Math.max(box.left, b.left), y = Math.max(box.top, b.top);
        const right = Math.min(box.right, b.right), bottom = Math.min(box.bottom, b.bottom);
        if (right - x < 1 || bottom - y < 1 || b.width > box.width * 1.2) continue;
        const n = { page: index, x: (x - box.left) / box.width, y: (y - box.top) / box.height, width: (right - x) / box.width, height: (bottom - y) / box.height };
        if (!rects.some(o => o.page === n.page && Math.abs(o.x - n.x) < .001 && Math.abs(o.y - n.y) < .001 && Math.abs(o.width - n.width) < .001)) rects.push(n);
      }
    }
    rects.sort((a, b) => a.page - b.page || a.y - b.y || a.x - b.x);
    if (!rects.length) return;
    const box = range.getBoundingClientRect();
    this.onSelection?.({ quote: text, page: rects[0].page, rects, anchor: { x: box.left + box.width / 2, y: box.bottom, top: box.top } });
  }

  setAnnotations(annotations, selectedId) {
    this.annotations = annotations; this.selectedId = selectedId;
    for (const index of this.rendered) this.drawAnnotations(index);
  }
  drawAnnotations(index) {
    const r = this.records[index]; if (!r) return;
    r.annotationLayer?.remove();
    const layer = document.createElement('div'); layer.className = 'annotation-layer';
    for (const a of this.annotations) {
      if (a.deletedAt) continue;
      for (const rect of a.rects || []) {
        if (rect.page !== index) continue;
        const mark = document.createElement('span'); mark.className = 'annotation-mark' + (a.id === this.selectedId ? ' selected' : '');
        mark.title = a.quote; mark.setAttribute('aria-label', a.quote.slice(0, 160));
        const y = a.kind === 'question' ? rect.y + rect.height * .9 : rect.y;
        const height = a.kind === 'question' ? Math.max(.0025, rect.height * .12) : rect.height;
        Object.assign(mark.style, { left: `${rect.x * 100}%`, top: `${y * 100}%`, width: `${rect.width * 100}%`, height: `${height * 100}%`, background: `#${a.color || 'A8DCC5'}` });
        // Clicking is resolved by the page; this overlay never intercepts text selection.
        mark.style.pointerEvents = 'none';
        layer.append(mark);
      }
    }
    r.annotationLayer = layer; r.el.append(layer);
  }

  async text(index) {
    if (this.texts.get(index)) return this.texts.get(index);
    if (this.ocr.has(index)) return this.ocr.get(index).text || '';
    return this.nativeText(index);
  }
  async nativeText(index) {
    if (this.texts.has(index)) return this.texts.get(index);
    const epoch = this.epoch;
    const content = await (await this.getPage(index)).getTextContent();
    const text = content.items.filter(i => 'str' in i).map(i => i.str + (i.hasEOL ? '\n' : ' ')).join('').trim();
    if (epoch === this.epoch) this.texts.set(index, text);
    return text;
  }

  async raster(index) {
    const page = await this.getPage(index), base = page.getViewport({ scale: 1 });
    const scale = Math.min(2.6, 2500 / Math.max(base.width, base.height));
    const viewport = page.getViewport({ scale });
    const canvas = document.createElement('canvas'); canvas.width = Math.ceil(viewport.width); canvas.height = Math.ceil(viewport.height);
    await page.render({ canvasContext: canvas.getContext('2d', { alpha: false }), viewport }).promise;
    const blob = await new Promise(resolve => canvas.toBlob(resolve, 'image/png'));
    const png = new Uint8Array(await blob.arrayBuffer());
    const result = { png, width: canvas.width, height: canvas.height };
    canvas.width = 0; canvas.height = 0; return result;
  }

  applyOCR(index, result) {
    this.ocr.set(index, result);
    if (this.records[index]?.textLayer && !this.texts.get(index)) this.buildOCRLayer(index);
  }
  clearOCR() {
    for (const index of this.ocr.keys()) {
      const record = this.records[index];
      if (record?.textLayer && !this.texts.get(index)) record.textLayer.replaceChildren();
      record?.searchLayer?.remove();
    }
    this.ocr.clear();
    this.clearSearch();
  }
  buildOCRLayer(index) {
    const r = this.records[index], result = this.ocr.get(index); if (!r?.textLayer || !result) return;
    r.textLayer.replaceChildren();
    const width = result.width, height = result.height;
    if (!(width > 0 && height > 0)) return;
    const context = document.createElement('canvas').getContext('2d');
    for (const word of result.words || []) {
      const span = document.createElement('span'); span.className = 'ocr-word'; span.textContent = `${word.text} `;
      const fontSize = word.height / height * r.height * this.scale;
      context.font = `${fontSize}px Arial`;
      const measured = context.measureText(span.textContent).width || 1;
      Object.assign(span.style, { left: `${word.x / width * 100}%`, top: `${word.y / height * 100}%`,
        fontSize: `${fontSize}px`, height: `${fontSize}px`, transform: `scaleX(${word.width / width * r.width * this.scale / measured})` });
      r.textLayer.append(span);
    }
    this.markSearch(index);
  }

  async search(query, onProgress) {
    const searchId = (this.searchId || 0) + 1; this.searchId = searchId;
    this.query = query.trim(); this.hits = []; this.hitIndex = -1;
    for (const index of this.rendered) this.markSearch(index);
    if (!this.query || !this.pdf) return [];
    const epoch = this.epoch, needle = this.query.replace(/\s+/g, ' ').toLocaleLowerCase();
    for (let index = 0; index < this.pageCount; index++) {
      const text = (await this.text(index)).replace(/\s+/g, ' ').trim().toLocaleLowerCase();
      if (searchId !== this.searchId || epoch !== this.epoch) return null;
      let offset = 0;
      while ((offset = text.indexOf(needle, offset)) !== -1) { this.hits.push({ page: index, offset }); offset += needle.length; }
      if (index % 10 === 0) { onProgress?.(index + 1, this.pageCount); await new Promise(resolve => setTimeout(resolve, 0)); }
    }
    if (this.hits.length) this.nextHit(1);
    for (const index of this.rendered) this.markSearch(index);
    return this.hits;
  }
  nextHit(direction = 1) {
    if (!this.hits.length) return;
    this.hitIndex = (this.hitIndex + direction + this.hits.length) % this.hits.length;
    const hit = this.hits[this.hitIndex]; this.jump(hit.page);
    for (const index of this.rendered) this.markSearch(index);
    this.renderPage(hit.page).then(() => {
      this.markSearch(hit.page);
      const r = this.records[hit.page];
      const pageHitIndex = this.hits.slice(0, this.hitIndex).filter(h => h.page === hit.page).length;
      const rect = r.searchRects?.[pageHitIndex]?.[0];
      if (rect) this.scroll.scrollTop = r.el.offsetTop + rect.y * r.height * this.scale - 100;
    }).catch(e => this.onError?.(e));
  }
  markSearch(index) {
    const r = this.records[index], layer = r?.textLayer; if (!layer) return;
    r.searchLayer?.remove(); r.searchRects = [];
    const needle = this.query?.replace(/\s+/g, ' ').trim().toLocaleLowerCase(); if (!needle) return;
    // Map normalized searchable text back to actual text nodes, including words
    // spanning multiple PDF.js runs. Range geometry preserves native selection.
    const chars = [], positions = [];
    const spans = [...layer.querySelectorAll('span')].filter(s => !s.classList.contains('markedContent'));
    for (const span of spans) {
      const walker = document.createTreeWalker(span, NodeFilter.SHOW_TEXT);
      while (walker.nextNode()) {
        const node = walker.currentNode;
        for (let offset = 0; offset < node.textContent.length; offset++) {
          const raw = node.textContent[offset], character = /\s/.test(raw) ? ' ' : raw.toLocaleLowerCase();
          if (character === ' ' && (!chars.length || chars.at(-1) === ' ')) continue;
          for (const lower of character) { chars.push(lower); positions.push({ node, offset, end: offset + 1 }); }
        }
      }
      if (chars.length && chars.at(-1) !== ' ') { chars.push(' '); positions.push(null); }
    }
    const text = chars.join(''), box = r.el.getBoundingClientRect(), overlay = document.createElement('div'); overlay.className = 'search-layer';
    const selectedHit = this.hits[this.hitIndex], selectedOrdinal = selectedHit?.page === index ? this.hits.slice(0, this.hitIndex).filter(h => h.page === index).length : -1;
    let offset = 0, ordinal = 0;
    while ((offset = text.indexOf(needle, offset)) !== -1) {
      let first = offset, last = offset + needle.length - 1;
      while (first <= last && !positions[first]) first++;
      while (last >= first && !positions[last]) last--;
      const rects = [];
      if (positions[first] && positions[last]) {
        const range = document.createRange(); range.setStart(positions[first].node, positions[first].offset); range.setEnd(positions[last].node, positions[last].end);
        for (const b of range.getClientRects()) {
          if (b.width < 1 || b.height < 1) continue;
          const rect = { x: (b.left - box.left) / box.width, y: (b.top - box.top) / box.height, width: b.width / box.width, height: b.height / box.height };
          if (rects.some(other => Math.abs(other.x - rect.x) < .001 && Math.abs(other.y - rect.y) < .001 && Math.abs(other.width - rect.width) < .001)) continue;
          rects.push(rect); const mark = document.createElement('span'); mark.className = `search-mark${ordinal === selectedOrdinal ? ' current' : ''}`;
          Object.assign(mark.style, { left: `${rect.x * 100}%`, top: `${rect.y * 100}%`, width: `${rect.width * 100}%`, height: `${rect.height * 100}%` }); overlay.append(mark);
        }
      }
      r.searchRects.push(rects); ordinal++; offset += needle.length;
    }
    r.searchLayer = overlay; r.el.append(overlay);
  }
  clearSearch() { this.searchId = (this.searchId || 0) + 1; this.query = ''; this.hits = []; this.hitIndex = -1; for (const index of this.rendered) this.markSearch(index); }
}
