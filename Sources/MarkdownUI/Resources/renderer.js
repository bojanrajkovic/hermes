// The page side of MarkdownUI. Swift calls `Hermes.render(payload)`; the page
// posts messages back through `window.webkit.messageHandlers.hermes`.
//
// payload: {
//   mode: 'document' | 'diff',
//   markdown,            // document mode
//   old, new,            // diff mode
//   baseURL,             // string or null; relative links and images resolve against it
//                        // (images under a file: base load from local/, see BundleSchemeHandler)
//   markers,             // diff mode: {line: comment count}
//   fit                  // true when the host sizes the view to its content
// }
//
// messages: {type: 'ready'} | {type: 'height', value} | {type: 'link', url}
//         | {type: 'comment', start, end} | {type: 'marker', line}
//         | {type: 'scroll', top}   // fit only: an in-page link's target, in points from the top
var Hermes = (function () {
  'use strict';

  var content = document.getElementById('content');
  var darkQuery = window.matchMedia('(prefers-color-scheme: dark)');
  var md = MDCore.createMarkdown({
    markdownit: window.markdownit,
    taskLists: window.markdownitTaskLists,
    footnote: window.markdownitFootnote,
    anchor: window.markdownItAnchor,
    emoji: window.markdownitEmoji,
    hljs: window.hljs
  });

  var baseURL = null;       // Base for the render in progress.
  var lastKey = null;       // Identifies the rendered content, to skip rebuilding it.
  var lastPayload = null;
  var lastRender = Promise.resolve(); // Settles when the diagrams of the last rebuild are drawn.
  var diagrams = {};        // Mermaid SVG by theme and source, so a re-render does not flicker.
  var diagramCount = 0;
  var mermaidLoading = null; // Settles when the Mermaid library is loaded and set up.

  // Marks the diff markup this page generates; see MDCore.renderDiff.
  var mark = Array.prototype.map.call(crypto.getRandomValues(new Uint8Array(16)), function (byte) {
    return byte.toString(16);
  }).join('');

  function post(message) {
    window.webkit.messageHandlers.hermes.postMessage(message);
  }

  // Resolve relative links and images while the nodes are still in DOMPurify's
  // inert document, so nothing loads from the unresolved URL.
  DOMPurify.addHook('afterSanitizeAttributes', function (node) {
    if (!node.getAttribute) return;

    // Raw HTML must not restyle or cover the page, or pass for diff markup
    // with made-up line numbers. github.com drops these attributes as well.
    var style = node.getAttribute('style');
    if (style && !/^text-align:(left|center|right)$/.test(style)) node.removeAttribute('style'); // markdown-it aligns table cells this way
    if (node.getAttribute('data-md') !== mark) {
      ['data-md', 'data-start', 'data-end', 'data-line'].forEach(function (name) { node.removeAttribute(name); });
      var classes = node.getAttribute('class');
      if (classes && /(^|\s)md-/.test(classes)) {
        node.setAttribute('class', classes.split(/\s+/).filter(function (name) { return name.indexOf('md-') !== 0; }).join(' '));
      }
    }

    if (!baseURL) return;
    ['href', 'src'].forEach(function (name) {
      var value = node.getAttribute(name);
      if (!value || value.charAt(0) === '#') return;
      try {
        var url = new URL(value, baseURL);
        node.setAttribute(name, name === 'src' && node.nodeName === 'IMG' && localImage(url) || url.href);
      } catch (e) { /* leave an unparsable URL as written */ }
    });
  });

  // The page cannot load file: URLs. Swift serves the images under a local
  // base directory at local/<path from that directory>.
  function localImage(url) {
    var directory = new URL('.', baseURL);
    if (url.protocol !== 'file:' || directory.protocol !== 'file:' || url.pathname.indexOf(directory.pathname) !== 0) return null;
    return 'local/' + url.pathname.slice(directory.pathname.length);
  }

  function sanitize(html) {
    return DOMPurify.sanitize(html, {
      RETURN_DOM_FRAGMENT: true,
      FORBID_TAGS: ['style', 'form', 'button', 'textarea', 'select', 'dialog'],
      FORBID_ATTR: ['srcset']
    });
  }

  function theme() {
    return darkQuery.matches ? 'dark' : 'default';
  }

  function setUpMermaid() {
    if (!window.mermaid) return;
    mermaid.initialize({
      startOnLoad: false,
      securityLevel: 'strict',
      theme: theme(),
      fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif'
    });
  }

  function diagramElement(svg) {
    var div = document.createElement('div');
    div.className = 'mermaid-diagram';
    div.innerHTML = svg; // Mermaid sanitizes its own output at securityLevel 'strict'.
    return div;
  }

  // Swaps cached diagrams in before the fragment is attached.
  function insertCachedDiagrams(root) {
    root.querySelectorAll('pre.mermaid-src').forEach(function (pre) {
      var svg = diagrams[theme() + '\n' + pre.textContent];
      if (svg) pre.replaceWith(diagramElement(svg));
    });
  }

  // Mermaid is most of the bundle, so it loads with the first diagram: a
  // comment without one costs a small page.
  function loadMermaid() {
    if (!mermaidLoading) {
      mermaidLoading = new Promise(function (resolve, reject) {
        var script = document.createElement('script');
        script.src = 'vendor/mermaid.min.js';
        script.onload = resolve;
        script.onerror = function () { reject(new Error('the Mermaid library did not load')); };
        document.head.appendChild(script);
      }).then(setUpMermaid);
    }
    return mermaidLoading;
  }

  function renderDiagrams() {
    var sources = content.querySelectorAll('pre.mermaid-src');
    if (sources.length === 0) return Promise.resolve();
    return loadMermaid().then(function () { return drawDiagrams(sources); });
  }

  function drawDiagrams(sources) {
    var jobs = Array.prototype.map.call(sources, function (pre) {
      var source = pre.textContent, key = theme() + '\n' + source, id = 'mermaid-' + (++diagramCount);
      return mermaid.render(id, source).then(function (result) {
        diagrams[key] = result.svg;
        if (pre.isConnected) pre.replaceWith(diagramElement(result.svg));
      }).catch(function (error) {
        // Mermaid leaves its error drawing in the body. Show the source instead.
        var stray = document.getElementById('d' + id);
        if (stray) stray.remove();
        if (!pre.isConnected) return;
        pre.className = '';
        var note = document.createElement('p');
        note.className = 'mermaid-error';
        note.textContent = 'Mermaid: ' + String(error && error.message || error).split('\n')[0];
        pre.before(note);
      });
    });
    return Promise.all(jobs).then(function () {});
  }

  // ---- diff affordances ----------------------------------------------------

  var addButton = document.createElement('button');
  addButton.className = 'md-add';
  addButton.textContent = '+';
  addButton.title = 'Comment on this block';

  function unitRange(unit) {
    return { start: Number(unit.dataset.start), end: Number(unit.dataset.end) };
  }

  function applyMarkers(markers) {
    content.querySelectorAll('.md-badge').forEach(function (badge) { badge.remove(); });
    var units = content.querySelectorAll('[data-start]');
    MDCore.assignMarkers(Array.prototype.map.call(units, unitRange), markers || {}).forEach(function (marker) {
      var badge = document.createElement('button');
      badge.className = 'md-badge';
      badge.textContent = String(marker.count);
      badge.dataset.line = String(marker.line);
      badge.title = marker.count === 1 ? '1 comment' : marker.count + ' comments';
      units[marker.unit].appendChild(badge);
    });
  }

  content.addEventListener('mouseover', function (event) {
    if (!document.body.classList.contains('diff')) return;
    var unit = event.target.closest('[data-start]');
    if (unit && addButton.parentNode !== unit) unit.appendChild(addButton);
  });

  document.documentElement.addEventListener('mouseleave', function () {
    addButton.remove();
  });

  document.addEventListener('click', function (event) {
    var badge = event.target.closest('.md-badge');
    if (badge) {
      post({ type: 'marker', line: Number(badge.dataset.line) });
      return;
    }
    if (event.target === addButton) {
      var range = unitRange(addButton.parentNode);
      post({ type: 'comment', start: range.start, end: range.end });
      return;
    }

    var link = event.target.closest('a[href]');
    if (!link) return;
    event.preventDefault();
    var href = link.getAttribute('href');
    if (href.charAt(0) === '#') {
      var target = document.getElementById(decodeURIComponent(href.slice(1)));
      if (!target) return;
      // Sized to content, the page has nothing to scroll: the host scrolls instead.
      if (lastPayload && lastPayload.fit) post({ type: 'scroll', top: target.getBoundingClientRect().top + window.scrollY });
      else target.scrollIntoView();
    } else {
      post({ type: 'link', url: link.href });
    }
  });

  // ---- rendering -----------------------------------------------------------

  /// Renders a payload in place. Resolves when the diagrams are drawn.
  /// The same content with different markers only redraws the badges.
  function render(payload) {
    lastPayload = payload;
    var diff = payload.mode === 'diff';
    document.body.classList.toggle('diff', diff);
    document.body.classList.toggle('fit', !!payload.fit);

    var key = JSON.stringify([payload.mode, payload.markdown, payload.old, payload.new, payload.baseURL, theme()]);
    if (key === lastKey) {
      if (diff) applyMarkers(payload.markers);
      return lastRender;
    }
    lastKey = key;

    baseURL = payload.baseURL || null;
    var html = diff ? MDCore.renderDiff(md, payload.old, payload.new, mark) : md.render(payload.markdown);
    var fragment = sanitize(html);
    insertCachedDiagrams(fragment);
    content.replaceChildren(fragment);
    if (diff) applyMarkers(payload.markers);
    lastRender = renderDiagrams();
    return lastRender;
  }

  darkQuery.addEventListener('change', function () {
    setUpMermaid();
    if (lastPayload) render(lastPayload);
  });

  // The content element's height depends only on the view's width, so the
  // host can resize the view to it without causing another change.
  new ResizeObserver(function () {
    post({ type: 'height', value: Math.ceil(content.getBoundingClientRect().height) });
  }).observe(content);

  post({ type: 'ready' });

  return { render: render };
})();
