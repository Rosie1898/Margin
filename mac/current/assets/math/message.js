/* Margin's offline Markdown + math view. Message text is always untrusted. */
(() => {
  'use strict';
  const article = document.getElementById('message');
  const escapeHTML = value => String(value).replace(/[&<>"']/g, character => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[character]));
  const latexSignal = /\\(?:[a-zA-Z]+|[,;!])/;

  function formula(tex, display) {
    // Fresh macros for each formula: definitions cannot change a later reply.
    try {
      const rendered = katex.renderToString(tex, {
        displayMode: display, output: 'htmlAndMathml', throwOnError: false,
        trust: false, strict: 'ignore', maxExpand: 250, maxSize: 20, macros: {},
        errorColor: '#72554b'
      });
      return `<span class="math-${display ? 'display' : 'inline'}">${rendered}</span>`;
    } catch (_) {
      return `<code class="katex-error">${escapeHTML(tex)}</code>`;
    }
  }

  function displayToken(source) {
    const paired = /^(?:\$\$([\s\S]*?)\$\$|\\\[([\s\S]*?)\\\])(?:[ \t]*(?:\n|$))?/.exec(source);
    if (paired) return {type:'marginDisplayMath',raw:paired[0],tex:paired[1] ?? paired[2]};
    // Some replies lose the backslashes around display brackets. Only treat a
    // standalone bracket block as math when the body contains a LaTeX command.
    const bare = /^\[[ \t]*\n([\s\S]*?)\n[ \t]*\](?:[ \t]*(?:\n|$))/.exec(source);
    if (bare && latexSignal.test(bare[1])) return {type:'marginDisplayMath',raw:bare[0],tex:bare[1]};
  }

  function displayStart(source) {
    const candidates = /(?:^|\n)(?:\$\$|\\\[|\[[ \t]*\n)/g;
    let match;
    while ((match = candidates.exec(source))) {
      const start = match.index + (match[0][0] === '\n' ? 1 : 0);
      if (displayToken(source.slice(start))) return start;
    }
  }

  function inlineToken(source) {
    if (source.startsWith('\\(')) {
      const end = source.indexOf('\\)', 2);
      if (end >= 0) return {type:'marginInlineMath',raw:source.slice(0,end+2),tex:source.slice(2,end),display:false};
    }
    if (source.startsWith('\\[')) {
      const end = source.indexOf('\\]', 2);
      if (end >= 0) return {type:'marginInlineMath',raw:source.slice(0,end+2),tex:source.slice(2,end),display:true};
    }
    if (source.startsWith('$$')) {
      const end = source.indexOf('$$', 2);
      if (end >= 0) return {type:'marginInlineMath',raw:source.slice(0,end+2),tex:source.slice(2,end),display:true};
    }
    if (source[0] === '$' && source[1] && !/[\s$]/.test(source[1])) {
      // Avoid interpreting prices such as "$5 and $10" as a formula. A plain
      // numeric currency amount remains text; "$x$" and "$5+x$" remain math.
      const match = /^\$((?:\\.|[^$\n\\])+?)\$(?!\d)/.exec(source);
      if (match && !/\s$/.test(match[1]) && !/^\d[\d,.]*$/.test(match[1])) {
        return {type:'marginInlineMath',raw:match[0],tex:match[1],display:false};
      }
    }
  }

  const parser = new marked.Marked({
    gfm: true, breaks: true,
    tokenizer: {
      lheading(source) {
        // Setext headings are recognized before Marked applies block-start
        // extensions. A formula's standalone "=" must never turn preceding
        // prose and its opening delimiter into a Markdown heading.
        const token = marked.Tokenizer.prototype.lheading.call(this, source);
        const start = displayStart(source);
        if (token && start !== undefined && start < token.raw.length) return undefined;
        return token;
      }
    },
    renderer: {
      // Raw HTML is visible as text, never passed through to the DOM.
      html(token) { return escapeHTML(token.text); },
      image(token) { return escapeHTML(token.text || ''); },
      link(token) {
        const label = this.parser.parseInline(token.tokens);
        let url;
        try { url = new URL(token.href); } catch (_) { return label; }
        if (!['https:','http:','mailto:'].includes(url.protocol)) return label;
        return `<a href="${escapeHTML(url.href)}" rel="noopener noreferrer">${label}</a>`;
      }
    },
    extensions: [
      {name:'marginDisplayMath',level:'block',start:displayStart,tokenizer:displayToken,renderer(token) {return formula(token.tex,true);}},
      {name:'marginInlineMath',level:'inline',start(source) {const i=source.search(/\$|\\[([]/);return i < 0 ? undefined : i;},tokenizer:inlineToken,renderer(token) {return formula(token.tex,token.display);}}
    ]
  });

  let lastHeight = 0;
  function reportHeight() {
    const height = Math.ceil(article.getBoundingClientRect().height);
    if (Math.abs(height-lastHeight) >= 1) {
      lastHeight = height;
      window.webkit?.messageHandlers?.marginHeight?.postMessage(height);
    }
  }
  new ResizeObserver(reportHeight).observe(article);
  document.fonts.ready.then(reportHeight);

  window.MarginMath = {
    render(text, fontSize, color) {
      document.body.style.fontSize = `${Math.max(9, Math.min(36, Number(fontSize) || 13))}px`;
      document.body.style.color = /^#[0-9a-fA-F]{6}$/.test(color) ? color : '#294039';
      let html;
      try { html = parser.parse(String(text)); }
      catch (_) { html = `<p>${escapeHTML(text).replace(/\n/g,'<br>')}</p>`; }
      article.innerHTML = DOMPurify.sanitize(html, {
        USE_PROFILES: {html:true, svg:true, mathMl:true},
        FORBID_TAGS: ['style','script','iframe','form','input','button','textarea','video','audio','img','object','embed'],
        FORBID_ATTR: ['id','name','src','srcset'],
        ALLOW_DATA_ATTR: false
      });
      for (const table of article.querySelectorAll('table')) {
        const wrapper = document.createElement('div');
        wrapper.className = 'table-scroll';
        table.replaceWith(wrapper); wrapper.append(table);
      }
      requestAnimationFrame(reportHeight);
      document.fonts.ready.then(reportHeight);
      return true;
    }
  };
})();
