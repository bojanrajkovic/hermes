// Markdown parsing and the rich diff. No DOM access, so it runs in
// JavaScriptCore for tests as well as in the web view.
//
// Exposes one global, `MDCore`:
//   createMarkdown(libs)             -> a configured markdown-it instance
//   renderDiff(md, oldSrc, newSrc, mark) -> HTML of the new document with change marks
//   htmlDiff(oldHtml, newHtml)       -> newHtml with <ins>/<del> around changed words
//   assignMarkers(units, markers)    -> which unit shows each comment badge
var MDCore = (function () {
  'use strict';

  var ALERTS = { NOTE: 'Note', TIP: 'Tip', IMPORTANT: 'Important', WARNING: 'Warning', CAUTION: 'Caution' };

  function escapeHtml(s) {
    return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  }

  // Turns `> [!NOTE]` block quotes into GitHub alerts.
  function alertRule(state) {
    var tokens = state.tokens;
    for (var i = 0; i + 2 < tokens.length; i++) {
      if (tokens[i].type !== 'blockquote_open' || tokens[i + 1].type !== 'paragraph_open') continue;
      var inline = tokens[i + 2];
      var m = /^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\][ \t]*(\n|$)/i.exec(inline.content);
      if (!m) continue;

      var kind = m[1].toUpperCase();
      tokens[i].attrJoin('class', 'markdown-alert markdown-alert-' + kind.toLowerCase());
      inline.content = inline.content.slice(m[0].length);
      inline.children = [];
      state.md.inline.parse(inline.content, state.md, state.env, inline.children);

      var title = new state.Token('html_block', '', 0);
      title.content = '<p class="markdown-alert-title">' + ALERTS[kind] + '</p>\n';
      tokens.splice(i + 1, 0, title);
    }
  }

  // Heading ids the way github.com makes them, so a README's own table of
  // contents links work: lowercase, punctuation dropped, spaces to hyphens.
  function slugify(text) {
    return text.trim().toLowerCase().replace(/[^\p{L}\p{M}\p{N}\p{Pc}\- ]/gu, '').replace(/ /g, '-');
  }

  /// Builds the markdown-it instance used for both plain rendering and diffs.
  /// `libs` holds the vendored globals: markdownit, taskLists, footnote,
  /// anchor, emoji, and hljs.
  function createMarkdown(libs) {
    var md = libs.markdownit({
      html: true, // Raw HTML passes through here; the page sanitizes the output.
      linkify: true,
      highlight: function (code, lang) {
        if (lang && libs.hljs && libs.hljs.getLanguage(lang)) {
          try { return libs.hljs.highlight(code, { language: lang, ignoreIllegals: true }).value; } catch (e) { /* fall through to plain text */ }
        }
        return '';
      }
    });
    if (libs.taskLists) md.use(libs.taskLists, { enabled: false });
    if (libs.footnote) md.use(libs.footnote);
    if (libs.anchor) md.use(libs.anchor, { slugify: slugify });
    if (libs.emoji) md.use(libs.emoji.full || libs.emoji);
    md.core.ruler.after('inline', 'github_alerts', alertRule);

    var fence = md.renderer.rules.fence;
    md.renderer.rules.fence = function (tokens, idx, options, env, self) {
      var token = tokens[idx];
      if (token.info.trim() !== 'mermaid') return fence(tokens, idx, options, env, self);
      // The page replaces this element with the rendered diagram.
      return '<pre class="mermaid-src">' + escapeHtml(token.content) + '</pre>\n';
    };
    return md;
  }

  // ---- sequence diff -------------------------------------------------------

  // Longest-common-subsequence diff of two arrays. `same` decides whether two
  // elements match; it defaults to `===`. Returns steps of
  // {op: 'eq' | 'del' | 'ins', a: index in `a`, b: index in `b`}.
  function diffSeq(a, b, same) {
    same = same || function (x, y) { return x === y; };
    var start = 0, endA = a.length, endB = b.length;
    while (start < endA && start < endB && same(a[start], b[start])) start++;
    while (endA > start && endB > start && same(a[endA - 1], b[endB - 1])) { endA--; endB--; }

    var n = endA - start, m = endB - start, i, j;
    var match = [], table = [];
    for (i = 0; i <= n; i++) { table.push(new Uint32Array(m + 1)); match.push(new Uint8Array(m)); }
    for (i = n - 1; i >= 0; i--) {
      for (j = m - 1; j >= 0; j--) {
        match[i][j] = same(a[start + i], b[start + j]) ? 1 : 0;
        table[i][j] = match[i][j] ? table[i + 1][j + 1] + 1 : Math.max(table[i + 1][j], table[i][j + 1]);
      }
    }

    var steps = [];
    for (i = 0; i < start; i++) steps.push({ op: 'eq', a: i, b: i });
    i = 0; j = 0;
    while (i < n || j < m) {
      if (i < n && j < m && match[i][j]) {
        steps.push({ op: 'eq', a: start + i, b: start + j }); i++; j++;
      } else if (i < n && (j === m || table[i + 1][j] >= table[i][j + 1])) {
        steps.push({ op: 'del', a: start + i }); i++;
      } else {
        steps.push({ op: 'ins', b: start + j }); j++;
      }
    }
    for (i = endA, j = endB; i < a.length; i++, j++) steps.push({ op: 'eq', a: i, b: j });
    return steps;
  }

  // ---- word-level HTML diff ------------------------------------------------

  // shortcut: the diff table is O(n*m); past this many cells the caller shows
  // the block as removed plus added instead. Switch to Myers if that is too coarse.
  var MAX_DIFF_CELLS = 1000000;

  function tokenizeHtml(html) {
    return html.match(/<[^>]+>|&[#\w]+;|\s+|\w+|[^\s\w<&]|[<&]/g) || [];
  }

  // Images count as content, so a swapped image shows as deleted plus inserted.
  function isStructuralTag(token) {
    return token.charAt(0) === '<' && token.length > 1 && !/^<img\b/i.test(token);
  }

  var TABLE_TAG = /^<(\/?)(table|thead|tbody|tfoot|tr|td|th)\b/i;
  function isCell(name) { return name === 'td' || name === 'th'; }
  // Row and cell tags compare by name, so a changed column alignment is not a
  // deleted cell plus an inserted one.
  function rowTagKey(token) { return token.replace(/^<(tr|td|th)\s[^>]*>$/i, '<$1>'); }

  // A line break inside a paragraph renders as a space, so re-wrapped text
  // compares equal. Not inside <pre>, where line breaks show.
  function flowToken(token) { return token === '\n' ? ' ' : token; }
  function sameFlow(oldHtml, newHtml) {
    if (oldHtml === newHtml) return true;
    if (/<pre/.test(oldHtml + newHtml)) return false;
    return oldHtml.replace(/\n/g, ' ') === newHtml.replace(/\n/g, ' ');
  }

  /// Marks the words that differ between two rendered HTML fragments.
  /// The result keeps the tag structure of `newHtml`. Inserted text is wrapped
  /// in `<ins>`, deleted text is placed where it used to be, wrapped in `<del>`.
  /// A change that only touches tags (a link target, emphasis) is not marked.
  ///
  /// Tables are the exception to dropping deleted tags: the parser moves text
  /// that is not in a cell out of the table. A deleted row or cell keeps its
  /// `<tr>`, `<td>`, and `<th>` tags, so its text stays where it was.
  function htmlDiff(oldHtml, newHtml) {
    var a = tokenizeHtml(oldHtml), b = tokenizeHtml(newHtml);
    var pre = /<pre/.test(oldHtml + newHtml);
    var key = function (token) { return rowTagKey(pre ? token : flowToken(token)); };
    var steps = diffSeq(a.map(key), b.map(key));
    var out = '', open = null;
    var table = []; // Names of the table elements open at the end of `out`.

    function wrap(kind) {
      if (open === kind) return;
      if (open) out += '</' + open + '>';
      if (kind) out += '<' + kind + '>';
      open = kind;
    }
    function top() { return table[table.length - 1]; }
    // Directly inside <table>, a row group, or <tr>: text is not allowed here.
    function betweenCells() { return table.length > 0 && !isCell(top()); }

    // Follows a tag of the new document. Like the parser, a new row or cell
    // closes the one that is still open.
    function track(name, closing) {
      if (closing) {
        var at = table.lastIndexOf(name);
        if (at >= 0) table.length = at;
        return;
      }
      if (name === 'tr' || isCell(name)) {
        while (isCell(top()) || (name === 'tr' && top() === 'tr')) table.pop();
      }
      table.push(name);
    }

    // Whether a deleted row or cell tag fits at the current position.
    function keepDeleted(name, closing) {
      if (closing) return top() === name && (name === 'tr' || isCell(name)) && !!table.pop();
      var fits = name === 'tr' ? betweenCells() && top() !== 'tr' : isCell(name) && top() === 'tr';
      if (fits) table.push(name);
      return fits;
    }

    steps.forEach(function (step) {
      var token = step.op === 'del' ? a[step.a] : b[step.b];
      if (isStructuralTag(token)) {
        wrap(null);
        var m = TABLE_TAG.exec(token), name = m && m[2].toLowerCase();
        if (step.op === 'del') {
          if (m && keepDeleted(name, !!m[1])) out += token;
          return;
        }
        if (m) track(name, !!m[1]);
        out += token;
      } else {
        if (step.op !== 'eq' && betweenCells()) {
          if (/^\s+$/.test(token)) return;
          // Changed text with no cell of its own, such as a paragraph that became a table.
          if (top() !== 'tr') { out += '<tr>'; table.push('tr'); }
          out += '<td>'; table.push('td');
        }
        wrap(step.op === 'eq' ? null : step.op);
        out += token;
      }
    });
    wrap(null);
    return out;
  }

  // The words of a fragment as {counts: word -> occurrences, total}.
  function wordsOf(html) {
    var counts = Object.create(null), total = 0;
    tokenizeHtml(html).forEach(function (token) {
      if (!/^\w/.test(token)) return;
      counts[token] = (counts[token] || 0) + 1;
      total++;
    });
    return { counts: counts, total: total };
  }

  // Share of words two fragments have in common, 0...1. Word order does not
  // count: this runs for every removed/added pair, so it has to be linear.
  function similarity(a, b) {
    if (a.total * b.total > MAX_DIFF_CELLS) return 0;
    if (a.total + b.total === 0) return 1;
    var common = 0;
    for (var word in a.counts) common += Math.min(a.counts[word], b.counts[word] || 0);
    return (2 * common) / (a.total + b.total);
  }

  // ---- block diff ----------------------------------------------------------

  // Blocks that share fewer words than this are shown as removed plus added.
  var MODIFIED_THRESHOLD = 0.4;

  // Splits tokens[from..<to] into the blocks that sit directly at `level`.
  // A block is {open, close, map, key}: token index range (inclusive), the
  // source line map, and the trimmed source text used to compare blocks.
  function splitBlocks(tokens, from, to, level, lines) {
    var blocks = [];
    for (var i = from; i < to; i++) {
      var token = tokens[i];
      if (token.level !== level || token.nesting === -1) continue;
      var close = i;
      if (token.nesting === 1) {
        for (var depth = 1; depth > 0;) depth += tokens[++close].nesting;
      }
      var map = token.map;
      if (map) {
        // markdown-it includes trailing blank lines in list item maps.
        var end = map[1];
        while (end > map[0] + 1 && lines[end - 1].trim() === '') end--;
        map = [map[0], end];
      }
      blocks.push({
        open: i, close: close, map: map, type: token.type,
        key: map ? lines.slice(map[0], map[1]).join('\n').trim() : null
      });
      i = close;
    }
    return blocks;
  }

  function isList(block) {
    return block.type === 'bullet_list_open' || block.type === 'ordered_list_open';
  }

  function isMermaid(tokens, block) {
    return block.type === 'fence' && tokens[block.open].info.trim() === 'mermaid';
  }

  function htmlToken(Token, html) {
    var token = new Token('html_block', '', 0);
    token.content = html;
    return token;
  }

  function lineAttrs(block) {
    return block.map ? ' data-start="' + (block.map[0] + 1) + '" data-end="' + block.map[1] + '"' : '';
  }

  /// Renders `newSrc` with block-level change marks against `oldSrc`.
  ///
  /// Each top-level block is wrapped in `<div class="md-block md-STATUS">`, and
  /// each top-level list item gets `md-STATUS` on its `<li>`. Raw HTML blocks
  /// are the exception: they are not wrapped or marked, so the blocks between
  /// an opening and a closing tag stay inside that element. STATUS is one of
  /// unchanged, added, removed, modified. Blocks and items that exist in the
  /// new document carry `data-start` and `data-end`: their 1-based, inclusive
  /// source line range in `newSrc`. Removed blocks appear where they used to
  /// be. Modified blocks contain `<ins>`/`<del>`; a modified Mermaid block
  /// contains the old and the new diagram source instead. A block whose source
  /// changed but renders the same (re-wrapped lines, a renumbered list item)
  /// is unchanged.
  ///
  /// With `mark`, every element this function marks also carries
  /// `data-md="<mark>"`. Raw HTML in the Markdown can imitate the classes and
  /// line attributes; the page passes a random mark and trusts only elements
  /// that carry it.
  function renderDiff(md, oldSrc, newSrc, mark) {
    var markAttr = mark ? ' data-md="' + mark + '"' : '';
    var oldEnv = {}, newEnv = {};
    var oldTokens = md.parse(oldSrc, oldEnv), newTokens = md.parse(newSrc, newEnv);
    var oldLines = oldSrc.split('\n'), newLines = newSrc.split('\n');
    var Token = newTokens.length ? newTokens[0].constructor : (oldTokens.length ? oldTokens[0].constructor : null);
    if (!Token) return '';
    var out = [];

    function render(tokens, from, to) {
      return md.renderer.render(tokens.slice(from, to), md.options, newEnv);
    }
    // Pairing compares every removed block with every added one, so a block's
    // HTML and words are computed once. Top-level blocks render whole, list
    // items render without their <li>.
    function renderBlock(tokens, block) {
      if (block.html === undefined) block.html = render(tokens, block.open, block.close + 1);
      return block.html;
    }
    function renderInner(tokens, block) {
      if (block.html === undefined) block.html = render(tokens, block.open + 1, block.close);
      return block.html;
    }
    function words(block, html) {
      return block.words || (block.words = wordsOf(html));
    }

    // Pairs removed and added blocks inside each run of changes. Returns
    // {old, new} entries in display order; either side may be null.
    function pairUp(steps, oldBlocks, newBlocks, canPair) {
      var entries = [], dels = [], inss = [];
      function flush() {
        diffSeq(dels, inss, canPair).forEach(function (step) {
          if (step.op === 'eq') entries.push({ old: dels[step.a], new: inss[step.b], changed: true });
          else if (step.op === 'del') entries.push({ old: dels[step.a], new: null });
          else entries.push({ old: null, new: inss[step.b] });
        });
        dels = []; inss = [];
      }
      steps.forEach(function (step) {
        if (step.op === 'del') dels.push(oldBlocks[step.a]);
        else if (step.op === 'ins') inss.push(newBlocks[step.b]);
        else { flush(); entries.push({ old: oldBlocks[step.a], new: newBlocks[step.b], changed: false }); }
      });
      flush();
      return entries;
    }

    function diffBlocks(oldBlocks, newBlocks, canPair) {
      var keys = function (blocks) { return blocks.map(function (b) { return b.type + '\n' + b.key; }); };
      return pairUp(diffSeq(keys(oldBlocks), keys(newBlocks)), oldBlocks, newBlocks, canPair);
    }

    function similarEnough(o, oldHtml, n, newHtml) {
      return similarity(words(o, oldHtml), words(n, newHtml)) >= MODIFIED_THRESHOLD;
    }

    // Emits a list. Items are the commentable units, so marks go on each <li>.
    function emitList(oldList, newList) {
      var oldItems = oldList ? splitBlocks(oldTokens, oldList.open + 1, oldList.close, oldTokens[oldList.open].level + 1, oldLines) : [];
      var newItems = newList ? splitBlocks(newTokens, newList.open + 1, newList.close, newTokens[newList.open].level + 1, newLines) : [];
      var entries = diffBlocks(oldItems, newItems, function (o, n) {
        return similarEnough(o, renderInner(oldTokens, o), n, renderInner(newTokens, n));
      });

      var listTokens = newList ? newTokens : oldTokens, list = newList || oldList;
      out.push(listTokens[list.open]);
      entries.forEach(function (entry) {
        var tokens = entry.new ? newTokens : oldTokens, item = entry.new || entry.old;
        var open = tokens[item.open];
        var changed = entry.changed && !sameFlow(renderInner(oldTokens, entry.old), renderInner(newTokens, entry.new));
        var status = !entry.new ? 'removed' : !entry.old ? 'added' : changed ? 'modified' : 'unchanged';
        open.attrJoin('class', 'md-' + status);
        if (mark) open.attrSet('data-md', mark);
        if (entry.new && item.map) {
          open.attrSet('data-start', String(item.map[0] + 1));
          open.attrSet('data-end', String(item.map[1]));
        }
        if (status === 'modified') {
          out.push(open, htmlToken(Token, htmlDiff(renderInner(oldTokens, entry.old), renderInner(newTokens, item))), tokens[item.close]);
        } else {
          for (var i = item.open; i <= item.close; i++) out.push(tokens[i]);
        }
      });
      out.push(listTokens[list.close]);
    }

    function emitWrapped(status, block, html) {
      out.push(htmlToken(Token, '<div class="md-block md-' + status + '"' + lineAttrs(block) + markAttr + '>\n' + html + '</div>\n'));
    }

    var oldBlocks = splitBlocks(oldTokens, 0, oldTokens.length, 0, oldLines).filter(function (b) { return b.map; });
    var newBlocks = splitBlocks(newTokens, 0, newTokens.length, 0, newLines);
    var entries = diffBlocks(oldBlocks, newBlocks.filter(function (b) { return b.map; }), function (o, n) {
      if (isList(o) || isList(n)) return o.type === n.type;
      if (isMermaid(oldTokens, o) || isMermaid(newTokens, n)) return isMermaid(oldTokens, o) && isMermaid(newTokens, n);
      return similarEnough(o, renderBlock(oldTokens, o), n, renderBlock(newTokens, n));
    });

    entries.forEach(function (entry) {
      var o = entry.old, n = entry.new;
      if (isList(n || o)) {
        emitList(o, n);
      } else if ((n || o).type === 'html_block') {
        // Raw HTML can open an element in one block and close it in a later
        // one (<details>, <div align="center">). A wrapper would close the
        // element early, so new HTML goes out as written and removed HTML is dropped.
        if (n) out.push(newTokens[n.open]);
      } else if (!n) {
        emitWrapped('removed', { map: null }, renderBlock(oldTokens, o));
      } else if (!o) {
        emitWrapped('added', n, renderBlock(newTokens, n));
      } else if (!entry.changed || sameFlow(renderBlock(oldTokens, o), renderBlock(newTokens, n))) {
        emitWrapped('unchanged', n, renderBlock(newTokens, n));
      } else if (isMermaid(newTokens, n)) {
        emitWrapped('modified', n,
          '<div class="md-mermaid-diff"' + markAttr + '>' +
          '<div class="md-removed"' + markAttr + '>' + renderBlock(oldTokens, o) + '</div>' +
          '<div class="md-added"' + markAttr + '>' + renderBlock(newTokens, n) + '</div>' +
          '</div>\n');
      } else {
        emitWrapped('modified', n, htmlDiff(renderBlock(oldTokens, o), renderBlock(newTokens, n)));
      }
    });

    // Blocks with no source lines (the footnote section) come from the new document as they are.
    newBlocks.forEach(function (block) {
      if (block.map) return;
      for (var i = block.open; i <= block.close; i++) out.push(newTokens[i]);
    });

    return md.renderer.render(out, md.options, newEnv);
  }

  // ---- comment markers -----------------------------------------------------

  /// Decides which unit shows the badge for each commented line.
  ///
  /// `units` is the list of {start, end} line ranges in document order.
  /// `markers` maps a line number to its comment count. A line inside a unit
  /// belongs to it. A line between units (a blank line, a link definition)
  /// goes to the closest unit above it, or to the first unit.
  /// Returns one {unit, count, line} per unit that has comments: the unit's
  /// index, the summed count, and the lowest commented line.
  function assignMarkers(units, markers) {
    var byUnit = {};
    Object.keys(markers).map(Number).sort(function (x, y) { return x - y; }).forEach(function (line) {
      var count = markers[line];
      if (!(count > 0) || units.length === 0) return;
      var unit = 0;
      for (var i = 0; i < units.length; i++) {
        if (units[i].start <= line) unit = i;
      }
      if (byUnit[unit]) byUnit[unit].count += count;
      else byUnit[unit] = { unit: unit, count: count, line: line };
    });
    return Object.keys(byUnit).map(function (k) { return byUnit[k]; });
  }

  return {
    createMarkdown: createMarkdown,
    renderDiff: renderDiff,
    htmlDiff: htmlDiff,
    assignMarkers: assignMarkers
  };
})();
