/* Riffle's demo film. Everything on screen is set for one moment at a time by render(t): no CSS transition or timer
   runs, so any frame can be drawn on its own, in any order, and comes out the same every time. Scripts/../Marketing/
   film/render.cjs steps t frame by frame and photographs each one.

   The switcher is the website's copy of the app's (website/site.js): its order, its badges, its search ranking and its
   five layouts, on the same sample windows. */
(function () {
  'use strict';

  var DURATION = 42.5;
  var IMG = '../../website/img/';

  // ------------------------------------------------------------------ time and easing
  function clamp(x, a, b) { return x < a ? a : x > b ? b : x; }
  function seg(t, a, b) { return clamp((t - a) / (b - a), 0, 1); }
  function mix(a, b, p) { return a + (b - a) * p; }
  // CSS cubic-bezier(x1, y1, x2, y2), solved for x.
  function bezier(x1, y1, x2, y2) {
    function a(p1, p2) { return 1 - 3 * p2 + 3 * p1; }
    function b(p1, p2) { return 3 * p2 - 6 * p1; }
    function c(p1) { return 3 * p1; }
    function at(t, p1, p2) { return ((a(p1, p2) * t + b(p1, p2)) * t + c(p1)) * t; }
    function slope(t, p1, p2) { return 3 * a(p1, p2) * t * t + 2 * b(p1, p2) * t + c(p1); }
    return function (x) {
      if (x <= 0) return 0;
      if (x >= 1) return 1;
      var t = x;
      for (var i = 0; i < 8; i++) {
        var s = slope(t, x1, x2);
        if (Math.abs(s) < 1e-6) break;
        t -= (at(t, x1, x2) - x) / s;
      }
      var lo = 0, hi = 1;
      if (Math.abs(at(t, x1, x2) - x) > 1e-5 || t < 0 || t > 1) {
        t = x;
        for (var k = 0; k < 40; k++) {
          var v = at(t, x1, x2);
          if (Math.abs(v - x) < 1e-6) break;
          if (v < x) lo = t; else hi = t;
          t = (lo + hi) / 2;
        }
      }
      return at(t, y1, y2);
    };
  }
  var E = {
    out: bezier(0.23, 1, 0.32, 1),       // the site's --ease
    glide: bezier(0.3, 1.18, 0.45, 1),   // the site's --glide, the selection's slight overshoot
    inOut: bezier(0.65, 0, 0.35, 1),
    soft: bezier(0.4, 0, 0.2, 1),
    quint: function (p) { return 1 - Math.pow(1 - p, 5); }
  };

  // ------------------------------------------------------------------ the sample Mac (website/site.js)
  var APPS = {
    safari: { name: 'Safari' },
    xcode: { name: 'Xcode' },
    notes: { name: 'Notes' },
    mail: { name: 'Mail', badge: '3' },
    terminal: { name: 'Terminal' },
    chrome: { name: 'Google Chrome' },
    finder: { name: 'Finder' },
    preview: { name: 'Preview' },
    music: { name: 'Music' },
    messages: { name: 'Messages', badge: '2' }
  };
  var WINDOWS = [
    { id: 'safari-lisbon', app: 'safari', title: 'Lisbon: three days on foot', space: 1, at: [25, 13, 50], ratio: 1400 / 876 },
    { id: 'xcode-sketchpad', app: 'xcode', title: 'Sketchpad.swift', space: 1, at: [4, 17, 46], ratio: 1400 / 980 },
    { id: 'notes-weekend', app: 'notes', title: 'Weekend plan', space: 2, at: [12, 14, 42], ratio: 1400 / 1076 },
    { id: 'mail-inbox', app: 'mail', title: 'Inbox', space: 1, at: [52, 9, 43], ratio: 1400 / 934 },
    { id: 'terminal-build', app: 'terminal', title: 'Build log', space: 1, at: [9, 45, 38], ratio: 1400 / 966 },
    { id: 'chrome-kyoto', app: 'chrome', title: 'Flights to Kyoto', space: 3, fullscreen: true, ratio: 1400 / 1056 },
    { id: 'finder-downloads', app: 'finder', title: 'Downloads', space: 1, at: [56, 43, 36], ratio: 1.4 },
    { id: 'preview-invoice', app: 'preview', title: 'Invoice October.pdf', space: 2, at: [60, 9, 24], ratio: 1400 / 1768 },
    { id: 'safari-sourdough', app: 'safari', title: 'Sourdough starter, day 4', space: 1, at: [32, 35, 42], ratio: 1400 / 876 },
    { id: 'notes-books', app: 'notes', title: 'Books to read', space: 1, at: [66, 21, 30], ratio: 1400 / 1076 },
    { id: 'music-now', app: 'music', title: 'Now Playing', space: 1, hidden: true, at: [38, 18, 40], ratio: 1400 / 904 },
    { id: 'finder-projects', app: 'finder', title: 'Projects', space: 1, minimized: true, at: [18, 24, 40], ratio: 1.4 },
    { id: 'messages', app: 'messages', title: '', space: 0, windowless: true }
  ];
  var BY_ID = {};
  WINDOWS.forEach(function (w, i) { w.order = i; w.appName = APPS[w.app].name; BY_ID[w.id] = w; });
  function pick(ids) { return ids.map(function (id) { return BY_ID[id]; }); }
  function plain(list) { return list.map(function (w) { return { w: w, title: [], app: [] }; }); }

  function icon(app) { return IMG + 'apps/' + app + '.webp'; }
  function picture(w) { return IMG + 'windows/' + w.id + '-1400.webp'; }
  function h(tag, cls, html) {
    var el = document.createElement(tag);
    if (cls) el.className = cls;
    if (html != null) el.innerHTML = html;
    return el;
  }
  function esc(s) { return String(s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }

  // ------------------------------------------------------------------ search, ranked the way Riffle ranks (website/site.js)
  function foldChar(c) {
    var f = c.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();
    if (f === 'ı') f = 'i';
    return f.length ? f[0] : '';
  }
  function prepare(text) {
    var chars = [], owners = [], starts = [];
    var prev = ' ';
    for (var i = 0; i < text.length; i++) {
      var f = foldChar(text[i]);
      if (!f) continue;
      var isWord = /[\p{L}\p{N}]/u.test(f);
      var start = isWord && (!/[\p{L}\p{N}]/u.test(prev) ||
        (/\p{Ll}/u.test(text[i - 1] || '') && /\p{Lu}/u.test(text[i])) ||
        (/\p{N}/u.test(f) !== /\p{N}/u.test(prev)));
      chars.push(f); owners.push(i); starts.push(!!start);
      prev = f;
    }
    return { s: chars.join(''), owners: owners, starts: starts, len: chars.length };
  }
  function damerau(a, b, limit) {
    var m = a.length, n = b.length;
    if (Math.abs(m - n) > limit) return limit + 1;
    var d = [];
    for (var i = 0; i <= m; i++) { d[i] = [i]; }
    for (var j = 0; j <= n; j++) d[0][j] = j;
    for (i = 1; i <= m; i++) {
      var rowMin = Infinity;
      for (j = 1; j <= n; j++) {
        var cost = a[i - 1] === b[j - 1] ? 0 : 1;
        var v = Math.min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost);
        if (i > 1 && j > 1 && a[i - 1] === b[j - 2] && a[i - 2] === b[j - 1]) v = Math.min(v, d[i - 2][j - 2] + 1);
        d[i][j] = v;
        rowMin = Math.min(rowMin, v);
      }
      if (rowMin > limit) return limit + 1;
    }
    return d[m][n];
  }
  function words(f) {
    var list = [], cur = null;
    for (var i = 0; i < f.len; i++) {
      var isWord = /[\p{L}\p{N}]/u.test(f.s[i]);
      if (isWord && (f.starts[i] || !cur)) { cur = { from: i, to: i + 1 }; list.push(cur); }
      else if (isWord && cur) cur.to = i + 1;
      else cur = null;
    }
    return list;
  }
  function range(from, n) { var r = []; for (var i = 0; i < n; i++) r.push(from + i); return r; }
  function matchWord(t, f) {
    if (!f.len) return null;
    var short = t.length <= 2;
    var best = null;
    function take(tier, score, at) { if (!best || score > best.score) best = { tier: tier, score: score, at: at }; }
    if (f.s === t) take(7, 7000, range(0, t.length));
    var wi = 0;
    for (var i = 0; i <= f.len - t.length; i++) {
      if (f.starts[i]) wi++;
      if (f.s.substr(i, t.length) !== t) continue;
      if (i === 0) take(6, 6000, range(0, t.length));
      else if (f.starts[i]) take(5, 5000 - 15 * Math.min(wi, 20), range(i, t.length));
      else if (!short) take(4, 4000 - 15 * Math.min(wi, 20), range(i, t.length));
    }
    if (best) return best;
    if (t.length >= 2) {
      var ws = words(f), at = [], k = 0;
      for (var w = 0; w < ws.length && k < t.length; w++) {
        var p = ws[w].from;
        while (k < t.length && p < ws[w].to && f.s[p] === t[k]) { at.push(p); p++; k++; }
      }
      if (k === t.length && at.length) take(3, 3000, at);
      if (best) return best;
    }
    if (short) return null;
    for (i = 0; i < f.len; i++) {
      if (!f.starts[i] || f.s[i] !== t[0]) continue;
      var pos = [i], q = 1;
      for (var j = i + 1; j < f.len && q < t.length; j++) if (f.s[j] === t[q]) { pos.push(j); q++; }
      if (q === t.length) { take(2, 2000 - (pos[pos.length - 1] - pos[0]), pos); break; }
    }
    if (best) return best;
    if (t.length >= 4) {
      var limit = t.length >= 8 ? 2 : 1;
      words(f).forEach(function (wd) {
        var word = f.s.slice(wd.from, wd.to);
        var dist = damerau(t, word, limit);
        if (dist <= limit) {
          var pz = [];
          for (var x = 0; x < word.length; x++) if (t.indexOf(word[x]) >= 0) pz.push(wd.from + x);
          take(1, 1000 + (dist === 1 ? 300 : 0), pz);
        }
      });
    }
    return best;
  }
  function rank(items, query) {
    var tokens = query.split(/\s+/).map(function (w) { return Array.from(w).map(foldChar).join(''); }).filter(Boolean);
    if (!tokens.length) return plain(items);
    var out = [];
    items.forEach(function (w) {
      var tf = prepare(w.title), af = prepare(w.appName);
      var total = 0, tAt = [], aAt = [], ok = true;
      tokens.forEach(function (t) {
        if (!ok) return;
        var a = matchWord(t, af), b = matchWord(t, tf);
        if (a) a.score += 60;
        if (!a && !b) { ok = false; return; }
        if (a && (!b || a.score >= b.score)) { total += a.score; aAt = aAt.concat(a.at.map(function (i) { return af.owners[i]; })); }
        else { total += b.score; tAt = tAt.concat(b.at.map(function (i) { return tf.owners[i]; })); }
      });
      if (ok) out.push({ w: w, score: total, title: tAt, app: aAt });
    });
    out.sort(function (x, y) { return y.score - x.score || x.w.order - y.w.order; });
    return out;
  }

  // ------------------------------------------------------------------ the switcher's cards (website/site.js)
  function marked(text, at) {
    if (!at || !at.length) return esc(text);
    var set = {}; at.forEach(function (i) { set[i] = true; });
    var out = '', open = false;
    for (var i = 0; i < text.length; i++) {
      if (set[i] && !open) { out += '<mark>'; open = true; }
      if (!set[i] && open) { out += '</mark>'; open = false; }
      out += esc(text[i]);
    }
    return out + (open ? '</mark>' : '');
  }
  var GLYPH = { min: 'i-min', hidden: 'i-hidden', full: 'i-full', space: 'i-space' };
  function glyph(name) { return '<svg aria-hidden="true"><use href="#' + (GLYPH[name] || name) + '"/></svg>'; }
  function marks(w, chips) {
    var out = [];
    if (w.minimized) out.push(glyph('min'));
    if (w.hidden) out.push(glyph('hidden'));
    if (w.fullscreen) out.push(glyph('full'));
    if (w.space > 1) out.push('<span class="sw__mark">' + glyph('space') + w.space + '</span>');
    if (!out.length) return '';
    return '<span class="sw__marks">' + out.map(function (m) { return chips ? '<span class="sw__chip">' + m + '</span>' : m; }).join('') + '</span>';
  }
  function img(src, extra) { return '<img src="' + src + '" alt="" decoding="sync"' + (extra || '') + '>'; }
  function appIcon(w) {
    var badge = APPS[w.app].badge ? '<span class="sw__badge">' + APPS[w.app].badge + '</span>' : '';
    return '<span class="sw__icon">' + img(icon(w.app), ' width="128" height="128"') + badge + '</span>';
  }
  function thumb(w, extra) {
    if (w.windowless) return '<span class="sw__thumb"><span class="sw__empty">' + img(icon(w.app)) + 'No open windows</span>' + (extra || '') + '</span>';
    return '<span class="sw__thumb">' + img(picture(w), ' width="1400" height="' + Math.round(1400 / w.ratio) + '" style="--r:' + w.ratio.toFixed(3) + '"') +
      (extra || '') + '</span>';
  }
  function item(r, i, layout) {
    var w = r.w;
    var title = marked(w.windowless ? w.appName : w.title, w.windowless ? r.app : r.title);
    var app = marked(w.appName, r.app);
    var open = '<div class="sw__item' + (w.minimized || w.hidden ? ' is-dim' : '') + '" data-id="' + w.id + '">';
    if (layout === 'deck') return open + '<span class="sw__head">' + appIcon(w) + '<span class="sw__title">' + title + '</span>' + marks(w, false) + '</span>' + thumb(w) + '</div>';
    if (layout === 'stage') return open + thumb(w, appIcon(w) + marks(w, true)) + '</div>';
    if (layout === 'icons') return open + marks(w, true) + appIcon(w) + '<span class="sw__title">' + title + '</span></div>';
    if (layout === 'titles') return open + appIcon(w) + '<span class="sw__title">' + title + '</span>' + marks(w, true) + '<span class="sw__num">' + (i + 1) + '</span></div>';
    return open + appIcon(w) + '<span class="sw__text"><span class="sw__title">' + title + '</span>' +
      (w.windowless ? '' : '<span class="sw__app">' + app + '</span>') + '</span>' + marks(w, true) + '<span class="sw__num">' + (i + 1) + '</span></div>';
  }

  // ------------------------------------------------------------------ a switcher the film can set to any state
  function stateKey(st) {
    return [st.layout, st.dark ? 1 : 0, st.font, st.searching ? 1 : 0, st.total || 0, st.most || 0, st.lockW || 0, st.lockH || 0, st.cells || 0, st.cell || 0,
      st.rows.map(function (r) { return r.w.id + ':' + r.title.join('.') + ':' + r.app.join('.'); }).join('|')].join('#');
  }
  function Sw(host) {
    this.host = host;
    this.el = h('div', 'sw');
    host.appendChild(this.el);
    this.key = '';
  }
  Sw.prototype.state = function (st) {
    var key = stateKey(st);
    if (key === this.key) return false;
    this.key = key;
    this.st = st;
    var el = this.el;
    el.className = 'sw sw--' + st.layout + (st.dark ? ' sw--dark' : '');
    el.style.fontSize = st.font + 'px';
    el.style.width = '';
    el.style.minWidth = st.lockW ? st.lockW + 'px' : '';
    el.style.minHeight = st.lockH ? st.lockH + 'px' : '';
    var stage = (st.layout === 'stage' || st.layout === 'list') ? '<div class="sw__stage"><div class="sw__big"></div><div class="sw__info"></div></div>' : '';
    var items = st.rows.map(function (r, i) { return item(r, i, st.layout); }).join('');
    var body = (st.layout === 'stage' ? stage : '') +
      '<div class="sw__items"><span class="sw__plate"></span>' + (st.rows.length ? items : '<p class="sw__none">No window matches. Try fewer letters.</p>') + '</div>' +
      (st.layout === 'list' ? stage : '');
    el.innerHTML = (st.searching ? '<div class="sw__search">' + glyph('i-search') + '<span class="q"></span><output></output></div>' : '') +
      '<div class="sw__body">' + body + '</div>';
    this.itemsEl = el.querySelector('.sw__items');
    this.plate = el.querySelector('.sw__plate');
    this.stageEl = el.querySelector('.sw__stage');
    this.q = el.querySelector('.sw__search .q');
    this.out = el.querySelector('.sw__search output');
    this.items = Array.prototype.slice.call(el.querySelectorAll('.sw__item'));
    this.flow();
    this.rects = this.items.map(function (it) { return { x: it.offsetLeft, y: it.offsetTop, w: it.offsetWidth, h: it.offsetHeight }; });
    this.byId = {};
    this.items.forEach(function (it, i) { this.byId[st.rows[i].w.id] = i; }, this);
    this.w = el.offsetWidth;
    this.h = el.offsetHeight;
    this.shown = -1;
    this.query = null;
    return true;
  };
  // Rows like the app's: as few as fit, as even as possible, earlier rows taking more, each one centered.
  Sw.prototype.flow = function () {
    var st = this.st, layout = st.layout, items = this.items, n = items.length;
    if (layout === 'stage') {
      var cells = Math.max(n, st.cells || 0, 1);
      this.itemsEl.style.gridAutoColumns = 'calc((100% - ' + (cells - 1) + ' * 0.6em) / ' + cells + ')';
      return;
    }
    if ((layout !== 'deck' && layout !== 'icons') || !n) return;
    var most = layout === 'deck' ? (n <= 4 ? n : n <= 8 ? 4 : n <= 15 ? 5 : 6) : Math.min(n, 7);
    if (st.most) most = Math.min(n, st.most);
    var rows = Math.ceil(n / most), base = Math.floor(n / rows), extra = n % rows, i = 0;
    var cell = st.cell || (layout === 'deck' ? 12.4 : 7.4), gap = layout === 'deck' ? 0.6 : 0.4;
    this.itemsEl.style.gridTemplateColumns = 'repeat(' + (2 * most) + ', ' + (cell - gap) / 2 + 'em)';
    this.itemsEl.style.columnGap = gap / 2 + 'em';
    this.el.style.width = (most * cell + 2.2) + 'em';
    for (var r = 0; r < rows; r++) {
      var k = base + (r < extra ? 1 : 0);
      for (var j = 0; j < k; j++, i++) items[i].style.gridColumn = (j === 0 && k < most ? (most - k + 1) + ' / ' : '') + 'span 2';
    }
  };
  // The selection: the plate over `rect`, and the card it belongs to marked (its title bolder in some layouts).
  Sw.prototype.select = function (index, rect, opacity) {
    if (!this.plate) return;
    if (!rect) { this.plate.style.opacity = 0; return; }
    this.plate.style.cssText = 'opacity:' + (opacity == null ? 1 : opacity) + ';width:' + rect.w + 'px;height:' + rect.h + 'px;transform:translate(' + rect.x + 'px,' + rect.y + 'px)';
    if (index !== this.shown) {
      this.items.forEach(function (it, k) { it.classList.toggle('is-selected', k === index); });
      this.shown = index;
      this.paintStage(index);
    }
  };
  // Stage and list show the selected window large.
  Sw.prototype.paintStage = function (index) {
    if (!this.stageEl) return;
    var r = this.st.rows[index];
    if (!r) { this.stageEl.querySelector('.sw__big').innerHTML = ''; this.stageEl.querySelector('.sw__info').innerHTML = ''; return; }
    var w = r.w;
    this.stageEl.querySelector('.sw__big').innerHTML = w.windowless ? '<span class="sw__empty">' + img(icon(w.app)) + 'No open windows</span>' :
      img(picture(w), ' width="1400" height="' + Math.round(1400 / w.ratio) + '" style="--r:' + w.ratio.toFixed(3) + '"');
    this.stageEl.querySelector('.sw__info').innerHTML = appIcon(w) + '<div><span class="sw__title">' + esc(w.windowless ? w.appName : w.title) +
      '</span><span class="sw__app">' + esc(w.appName) + '</span></div><span class="sw__counter">' + (index + 1) + ' / ' + this.st.rows.length + '</span>';
  };
  // The search field: what's typed so far, the caret, and how many windows match.
  Sw.prototype.typed = function (text, caret, selectedAll) {
    if (!this.q) return;
    var key = text + '|' + caret + '|' + selectedAll;
    if (key === this.query) return;
    this.query = key;
    this.q.innerHTML = text ? '<i' + (selectedAll ? ' class="sel"' : '') + '>' + esc(text) + '</i>' + (caret ? '<b class="caret"></b>' : '') :
      (caret ? '<b class="caret"></b>' : '') + '<span class="ph">Search windows</span>';
    this.out.textContent = text.trim() ? this.st.rows.length + ' of ' + this.st.total + ' windows' : '';
  };
  // Where every card of this state is, for animating from it into another.
  Sw.prototype.snapshot = function () {
    var snap = { rects: {}, html: {} };
    this.items.forEach(function (it, i) {
      var id = this.st.rows[i].w.id;
      snap.rects[id] = this.rects[i];
      var copy = it.cloneNode(true);
      copy.style.gridColumn = '';
      copy.classList.remove('is-selected');
      snap.html[id] = copy.outerHTML;
    }, this);
    return snap;
  };
  // From the cards of `prev` (a snapshot) to this state's: kept cards slide over, new ones grow in, gone ones shrink
  // away where they were. `p` runs 0 → 1. Returns where each card is drawn this frame, by index.
  Sw.prototype.morph = function (prev, p) {
    var self = this;
    Array.prototype.slice.call(this.itemsEl.querySelectorAll('.sw__ghost')).forEach(function (g) { g.remove(); });
    var e = E.out(p), drawn = [];
    this.items.forEach(function (it, i) {
      var id = self.st.rows[i].w.id, to = self.rects[i], from = prev && prev.rects[id];
      if (!prev || p >= 1) { it.style.transform = ''; it.style.opacity = ''; drawn.push(to); return; }
      if (from) {
        var dx = (from.x - to.x) * (1 - e), dy = (from.y - to.y) * (1 - e);
        it.style.transform = 'translate(' + dx + 'px,' + dy + 'px)';
        it.style.opacity = '';
        drawn.push({ x: to.x + dx, y: to.y + dy, w: to.w, h: to.h });
      } else {
        var q = E.out(seg(p, 0.2, 1));
        it.style.opacity = q;
        it.style.transform = 'scale(' + mix(0.88, 1, q) + ')';
        drawn.push(to);
      }
    });
    if (prev && p < 1) {
      Object.keys(prev.rects).forEach(function (id) {
        if (self.byId[id] != null) return;
        var r = prev.rects[id], q = E.out(seg(p, 0, 0.6));
        var g = h('div', 'sw__ghost', prev.html[id]);
        g.style.cssText = 'left:' + r.x + 'px;top:' + r.y + 'px;width:' + r.w + 'px;height:' + r.h + 'px;opacity:' + (1 - q) + ';transform:scale(' + mix(1, 0.86, q) + ')';
        self.itemsEl.appendChild(g);
      });
    }
    return drawn;
  };

  // A switcher's states are measured once, offstage, so any frame can animate between two of them.
  var snaps = {};
  function snapshotOf(sw, st) {
    var key = stateKey(st);
    if (snaps[key]) return snaps[key];
    var probe = sw.probe;
    if (!probe) {
      probe = sw.probe = new Sw(sw.host);
      probe.el.style.visibility = 'hidden';
      probe.el.style.position = 'absolute';
      probe.el.style.left = '0';
      probe.el.style.top = '0';
      probe.el.style.pointerEvents = 'none';
    }
    probe.state(st);
    snaps[key] = probe.snapshot();
    snaps[key].w = probe.el.offsetWidth;
    snaps[key].h = probe.el.offsetHeight;
    return snaps[key];
  }

  // Which of a list of timed values holds at `t`, the one before it, and how far the change has come.
  function timeline(changes, t, duration) {
    var at = 0;
    for (var i = 0; i < changes.length; i++) if (t >= changes[i][0]) at = i;
    var start = changes[at][0];
    return { i: at, value: changes[at][1], before: at > 0 ? changes[at - 1][1] : changes[at][1], p: at > 0 ? seg(t, start, start + duration) : 1, start: start };
  }

  // ------------------------------------------------------------------ the stage
  var frame = document.getElementById('frame');
  function layer(cls, parent) { var el = h('div', cls); (parent || frame).appendChild(el); return el; }
  function set(el, opacity, transform) {
    el.style.opacity = opacity;
    el.style.visibility = opacity <= 0.001 ? 'hidden' : 'visible';
    if (transform != null) el.style.transform = transform;
  }

  var bgDusk = layer('bg bg--dusk');
  var bgPaper = layer('bg bg--paper');

  // Captions: lines that rise into view from below their own baseline, and a quieter line under them.
  function caption(lines, sub, ink) {
    var el = layer('cap' + (ink ? ' cap--ink' : ''));
    var hl = h('h2');
    var spans = lines.map(function (text) {
      var line = h('span', 'line'), inner = h('span', null, text);
      line.appendChild(inner);
      hl.appendChild(line);
      return inner;
    });
    el.appendChild(hl);
    var p = sub ? h('p', null, sub) : null;
    if (p) el.appendChild(p);
    return { el: el, lines: spans, sub: p };
  }
  function showCaption(c, t, a, b) {
    var out = seg(t, b, b + 0.42);
    if (t < a || out >= 1) { set(c.el, 0); return; }
    set(c.el, 1 - E.out(out), 'translateY(' + (-16 * E.out(out)) + 'px)');
    c.lines.forEach(function (span, i) {
      var q = E.quint(seg(t, a + i * 0.09, a + 0.7 + i * 0.09));
      span.style.transform = 'translateY(' + (1 - q) * 112 + '%)';
    });
    if (c.sub) {
      var s = E.out(seg(t, a + 0.38, a + 0.95));
      c.sub.style.opacity = s;
      c.sub.style.transform = 'translateY(' + (1 - s) * 14 + 'px)';
    }
  }

  // ---- the Mac's screen: a desktop of sample windows, a menu bar, and the switcher over them
  var screen = layer('screen');
  var screenIn = layer('layer', screen);
  screenIn.style.transformOrigin = '0 0';
  var menubar = layer('menubar', screenIn);
  var MENUS = {
    Safari: ['File', 'Edit', 'View', 'History', 'Bookmarks', 'Window', 'Help'],
    Mail: ['File', 'Edit', 'View', 'Mailbox', 'Message', 'Format', 'Window', 'Help']
  };
  var menuShown = '';
  function menu(app) {
    if (app === menuShown) return;
    menuShown = app;
    menubar.innerHTML = '<b>' + app + '</b>' + MENUS[app].map(function (m) { return '<span>' + m + '</span>'; }).join('') +
      '<span class="mb-right"><span>Fri 9:41</span></span>';
  }
  var DESK_W = 1440, DESK_H = 900, BAR = 32;
  var desk = {};
  WINDOWS.forEach(function (w) {
    if (w.space !== 1 || w.minimized || w.hidden || w.windowless) return;
    var el = layer('win', screenIn);
    var width = w.at[2] / 100 * DESK_W;
    el.style.left = (w.at[0] / 100 * DESK_W) + 'px';
    el.style.top = (BAR + w.at[1] / 100 * (DESK_H - BAR)) + 'px';
    el.style.width = width + 'px';
    el.innerHTML = img(picture(w));
    desk[w.id] = el;
  });
  var deskHost = layer('desk-sw', screenIn);
  var deskSw = new Sw(deskHost);

  // Windows on the desktop, most recently used in front, `raised` coming to the very front as it pops.
  function stackDesk(order, raised, pop) {
    var z = 100;
    order.forEach(function (id) { if (desk[id]) { desk[id].style.zIndex = z; z--; } });
    Object.keys(desk).forEach(function (id) { desk[id].style.transform = ''; desk[id].style.filter = ''; });
    if (raised && desk[raised]) {
      desk[raised].style.zIndex = 200;
      var bump = Math.sin(Math.PI * pop);
      desk[raised].style.transform = 'scale(' + (1 + 0.016 * bump) + ')';
      desk[raised].style.filter = 'brightness(' + (1 + 0.06 * bump) + ')';
    }
  }

  // ---- keys
  function key(label, glyphText, wide, small) {
    return h('span', 'kc' + (wide ? ' kc--wide' : '') + (small ? ' kc--small' : ''), (glyphText ? '<small>' + glyphText + '</small>' : '') + label);
  }
  var keys1 = layer('keys');
  var kOpt = key('option', '⌥'), kTab = key('tab', '⇥', true);
  keys1.appendChild(kOpt);
  keys1.appendChild(kTab);

  // ---- five ways: the wall on paper
  var wall = layer('wall');
  var pills = layer('pills');
  var LAYOUTS = [['deck', 'Deck'], ['stage', 'Stage'], ['icons', 'App Icons'], ['titles', 'Titles'], ['list', 'List']];
  var pillMark = h('i');
  pills.appendChild(pillMark);
  var pillEls = LAYOUTS.map(function (l) { var s = h('span', null, l[1]); pills.appendChild(s); return s; });
  var wallSw = LAYOUTS.map(function () { var host = layer('wall__sw', wall); return { host: host, sw: new Sw(host) }; });

  // ---- the dark deck alone, with a camera
  var cam = layer('camera');
  var soloHost = layer('solo', cam);
  var soloSw = new Sw(soloHost);
  var legend = layer('legend');
  var LEGEND = [['W', 'close'], ['M', 'minimize'], ['F', 'full screen'], ['H', 'hide'], ['Q', 'quit']];
  var legendKeys = LEGEND.map(function (k) {
    var it = h('span', 'legend__item');
    var kc = key(k[0], null, false, true);
    it.appendChild(kc);
    it.appendChild(h('span', null, k[1]));
    legend.appendChild(it);
    return kc;
  });

  // ---- ⌘ Tab: the keys in their deck
  var deck2 = layer('deck2');
  function bigKey(cls, front, back) {
    var el = h('span', 'bk' + (cls ? ' ' + cls : ''));
    var turn = h('span', 'bk__turn');
    turn.appendChild(h('span', 'bk__face', front));
    if (back) turn.appendChild(h('span', 'bk__face bk__face--back', back));
    el.appendChild(turn);
    deck2.appendChild(el);
    return { el: el, turn: turn };
  }
  var bkMod = bigKey('', '<small>⌥</small>option', '<small>⌘</small>command');
  var bkTab = bigKey('bk--tab', '<small>⇥</small>tab');
  var chips = layer('chips');
  [['i-translate', '21 languages'], [null, 'VoiceOver'], ['i-lock', 'No account, no tracking'], [null, 'Works without Screen Recording']].forEach(function (c) {
    chips.appendChild(h('span', 'chip', (c[0] ? glyph(c[0]) : '') + c[1]));
  });
  var chipEls = Array.prototype.slice.call(chips.children);

  // ---- the close: the icon's cards riffle out, then the name
  var outro = layer('outro');
  var outroIn = h('div', 'outro__in');
  outro.appendChild(outroIn);
  var flogo = h('div', 'flogo');
  ['plate', 'card-back', 'card-middle', 'card-front', 'arrow'].forEach(function (part) {
    flogo.appendChild(h('img', part.indexOf('card') === 0 ? 'card ' + part : part));
  });
  Array.prototype.forEach.call(flogo.querySelectorAll('img'), function (el, i) {
    el.src = IMG + 'logo/' + ['plate', 'card-back', 'card-middle', 'card-front', 'arrow'][i] + '.webp';
    el.decoding = 'sync';
  });
  outroIn.appendChild(flogo);
  var word = h('div', 'word', '<span class="line"><span>Riffle</span></span>');
  var tag = h('div', 'tag', 'Riffle through every window.');
  var fine = h('div', 'fine', 'Free for macOS 26 and later&nbsp;&nbsp;·&nbsp;&nbsp;<b>appriffle.com</b>');
  outroIn.appendChild(word);
  outroIn.appendChild(tag);
  outroIn.appendChild(fine);
  var logoBack = flogo.querySelector('.card-back'), logoMiddle = flogo.querySelector('.card-middle'), logoArrow = flogo.querySelector('.arrow');
  var wordSpan = word.querySelector('.line > span');

  var vignette = layer('vignette');

  var cap1 = caption(['Every window, one shortcut.'], 'Hold <kbd>⌥</kbd> and tap <kbd>Tab</kbd>. Let go to switch.');
  var cap2 = caption(['Type to find it.'], 'Fuzzy search: initials and typos work too.');
  var cap3 = caption(['Five ways to see them.'], 'Give each of up to nine shortcuts its own.', true);
  var cap4 = caption(['Every window, on every desktop.'], 'Minimized, hidden and full-screen windows too.');
  var cap5 = caption(['One key to close, minimize or quit.'], 'Or 1–9 to jump straight to a window.');
  var cap6 = caption(['Or make it your ⌘ Tab.'], 'Riffle takes it over, and gives it back when it quits.');

  // ------------------------------------------------------------------ the windows each scene shows
  var ROWS1 = pick(['safari-lisbon', 'xcode-sketchpad', 'notes-weekend', 'mail-inbox', 'terminal-build', 'chrome-kyoto', 'finder-downloads',
    'preview-invoice', 'safari-sourdough', 'notes-books']);
  // After the switch to Mail, Mail is the most recent.
  var ROWS2 = pick(['mail-inbox', 'safari-lisbon', 'xcode-sketchpad', 'notes-weekend', 'terminal-build', 'chrome-kyoto', 'finder-downloads',
    'preview-invoice', 'safari-sourdough', 'notes-books']);
  var ROWS3 = pick(['safari-sourdough', 'mail-inbox', 'safari-lisbon', 'xcode-sketchpad', 'notes-weekend', 'terminal-build', 'chrome-kyoto', 'finder-downloads']);
  var ROWS4 = pick(['notes-weekend', 'chrome-kyoto', 'preview-invoice', 'music-now', 'finder-projects', 'terminal-build', 'safari-lisbon', 'messages']);
  var ROWS4B = ROWS4.filter(function (w) { return w.id !== 'terminal-build'; });

  var F1 = 17.4;
  var deck1 = { rows: plain(ROWS1), layout: 'deck', dark: true, font: F1, most: 5 };
  var deck2s = { rows: plain(ROWS2), layout: 'deck', dark: true, font: F1, most: 5 };
  var QUERIES = [[6.95, ''], [7.62, 'k'], [7.78, 'ky'], [7.94, 'kyo'], [9.18, 's'], [9.31, 'su'], [9.44, 'sur'], [9.57, 'surd'],
    [9.7, 'surdo'], [9.83, 'surdou'], [9.96, 'surdoug'], [10.09, 'surdough']];
  var searchLock = null;
  function searchState(q) {
    if (!searchLock) {
      var s = snapshotOf(deskSw, { rows: plain(ROWS2), layout: 'deck', dark: true, font: F1, most: 5, searching: true, total: ROWS2.length });
      searchLock = { w: s.w, h: s.h };
    }
    return { rows: rank(ROWS2, q), layout: 'deck', dark: true, font: F1, most: 5, searching: true, total: ROWS2.length, lockW: searchLock.w, lockH: searchLock.h };
  }

  var F4 = 22.5;
  var solo = { rows: plain(ROWS4), layout: 'deck', dark: true, font: F4, most: 4, cell: 15 };
  var soloB = { rows: plain(ROWS4B), layout: 'deck', dark: true, font: F4, most: 4, cell: 15 };

  // The wall: each layout sized to fill it, the way the site sizes them.
  var WALL_W = 1500 - 2 * 80, WALL_H = 744 - 2 * 70;
  function fitWall() {
    wallSw.forEach(function (s, i) {
      var layout = LAYOUTS[i][0];
      var st = { rows: plain(ROWS3), layout: layout, dark: false, font: 16, most: layout === 'icons' ? 4 : 0, cells: 0 };
      s.sw.state(st);
      var scale = Math.min(WALL_W / s.sw.w, WALL_H / s.sw.h);
      st = { rows: plain(ROWS3), layout: layout, dark: false, font: Math.min(16 * scale, 30), most: st.most, cells: 0 };
      s.sw.state(st);
      s.sw.select(1, s.sw.rects[1]);
    });
  }

  // ------------------------------------------------------------------ the film, at time t
  var S = { s1: 0, s2: 6.6, s3: 13.6, s4: 22.6, s5: 30.4, s6: 36.4 };

  function render(t) {
    // Backgrounds.
    var paperIn = seg(t, 13.3, 13.85), paperOut = seg(t, 22.35, 22.9);
    set(bgPaper, E.inOut(paperIn) * (1 - E.inOut(paperOut)));
    set(vignette, 0.75 * (1 - E.inOut(paperIn) * (1 - E.inOut(paperOut))));

    renderScreen(t);
    renderWall(t);
    renderSolo(t);
    renderKeys(t);
    renderOutro(t);

    showCaption(cap1, t, 0.35, 6.15);
    showCaption(cap2, t, 6.85, 13.15);
    showCaption(cap3, t, 13.85, 22.2);
    showCaption(cap4, t, 22.95, 26.25);
    showCaption(cap5, t, 26.6, 30.0);
    showCaption(cap6, t, 30.65, 35.95);
  }

  // Scenes one and two: the desktop, ⌥ Tab over it, then a search.
  function renderScreen(t) {
    if (t > 13.95) { set(screen, 0); set(keys1, 0); return; }
    // There from the first frame (it's the picture people see before playing), settling into place.
    var enter = E.out(seg(t, 0, 1.3)), leave = E.inOut(seg(t, 13.3, 13.85));
    set(screen, 1 - leave, 'translateY(' + ((1 - enter) * 36 + leave * -30) + 'px) scale(' + (0.975 + 0.025 * enter - 0.03 * leave) + ')');

    // The camera inside the screen: a slow push, then in close on the search field and back.
    var push = 1 + 0.025 * E.inOut(seg(t, 1.1, 6.6));
    var zin = E.inOut(seg(t, 7.2, 8.05)), zout = E.inOut(seg(t, 10.95, 11.8));
    var zoom = t <= 6.6 ? push : mix(1.025, 1.2, zin) * (1 - zout) + zout;
    // Toward the switcher's middle, never past the screen's edges.
    var fy = mix(DESK_H / 2, BAR + (DESK_H - BAR) / 2, zin * (1 - zout));
    var tx = clamp(DESK_W / 2 - DESK_W / 2 * zoom, DESK_W - DESK_W * zoom, 0), ty = clamp(DESK_H / 2 - fy * zoom, DESK_H - DESK_H * zoom, 0);
    screenIn.style.transform = 'translate(' + tx + 'px,' + ty + 'px) scale(' + zoom + ')';

    // The desktop: Safari in front, then Mail once it's chosen, then Safari's sourdough window.
    var order1 = ['safari-lisbon', 'xcode-sketchpad', 'mail-inbox', 'terminal-build', 'finder-downloads', 'safari-sourdough', 'notes-books'];
    var order2 = ['mail-inbox', 'safari-lisbon', 'xcode-sketchpad', 'terminal-build', 'finder-downloads', 'safari-sourdough', 'notes-books'];
    if (t < 4.28) { stackDesk(order1); menu('Safari'); }
    else if (t < 11.0) { stackDesk(order2, 'mail-inbox', seg(t, 4.28, 4.85)); menu('Mail'); }
    else { stackDesk(['safari-sourdough'].concat(order2), 'safari-sourdough', seg(t, 11.0, 11.6)); menu('Safari'); }

    // Scene one: ⌥ Tab, three taps, let go.
    if (t < 6.6) {
      deskSw.state(deck1);
      var show = E.out(seg(t, 1.9, 2.07)), hide = seg(t, 4.25, 4.4);
      var o = show * (1 - hide);
      set(deskHost, o, 'scale(' + (0.965 + 0.035 * show) + ')');
      if (o > 0) {
        var sel = timeline([[1.9, 1], [2.6, 2], [3.3, 3]], t, 0.26);
        var a = deskSw.rects[sel.before], b = deskSw.rects[sel.value], p = E.glide(sel.p);
        deskSw.select(p < 0.5 ? sel.before : sel.value, lerpRect(a, b, p));
      }
      return;
    }

    // Scene two: a search shortcut opens straight into search, two searches, Enter.
    var q = timeline(QUERIES, t, 0.2);
    var st = searchState(q.value);
    var fresh = deskSw.state(st);
    var open = E.out(seg(t, 6.95, 7.12)), close = seg(t, 10.95, 11.1);
    var ov = open * (1 - close);
    set(deskHost, ov, 'scale(' + (0.965 + 0.035 * open) + ')');
    if (ov <= 0) return;
    var prev = q.i > 0 ? snapshotOf(deskSw, searchState(q.before)) : null;
    var drawn = deskSw.morph(prev, q.p);
    void fresh;
    // While typing, the best match stays selected; the plate follows it as the cards move.
    deskSw.select(0, drawn[0]);
    var caretOn = Math.floor((t - 6.95) / 0.53) % 2 === 0 || (t - q.start < 0.5 && q.i > 0);
    var all = t > 8.95 && t < 9.18;
    deskSw.typed(q.value, caretOn && !all, all);
  }

  function lerpRect(a, b, p) {
    if (!a) return b;
    if (!b) return a;
    return { x: mix(a.x, b.x, p), y: mix(a.y, b.y, p), w: mix(a.w, b.w, p), h: mix(a.h, b.h, p) };
  }

  // Scene three: the five layouts in turn on the wall.
  var WALL_AT = [14.1, 15.8, 17.5, 19.2, 20.9, 22.6];
  var wallReady = false;
  function renderWall(t) {
    var inP = E.out(seg(t, 13.7, 14.35)), outP = E.inOut(seg(t, 22.25, 22.75));
    if (t < 13.6 || outP >= 1) { set(wall, 0); set(pills, 0); return; }
    if (!wallReady) { fitWall(); wallReady = true; }
    set(wall, inP * (1 - outP), 'translateY(' + ((1 - inP) * 40 - outP * 20) + 'px) scale(' + (0.975 + 0.025 * inP) + ')');
    var pin = E.out(seg(t, 14.0, 14.5));
    set(pills, pin * (1 - outP), 'translateX(-50%) translateY(' + (1 - pin) * 18 + 'px)');

    // Which layout: each one cross-fades into the next.
    var current = 0;
    for (var i = 0; i < LAYOUTS.length; i++) if (t >= WALL_AT[i] - 0.06) current = i;
    wallSw.forEach(function (s, i) {
      var a = WALL_AT[i], b = WALL_AT[i + 1];
      var fin = i === 0 ? 1 : E.out(seg(t, a - 0.02, a + 0.3)), fout = i === LAYOUTS.length - 1 ? 0 : E.inOut(seg(t, b - 0.2, b + 0.02));
      var o = fin * (1 - fout);
      set(s.host, o, 'scale(' + ((1.02 - 0.02 * fin) - 0.015 * fout) + ')');
      if (o <= 0) return;
      var sel = timeline([[a - 1, 1], [a + 0.72, 2], [a + 1.22, 3]], t, 0.26);
      var p = E.glide(sel.p);
      s.sw.select(p < 0.5 ? sel.before : sel.value, lerpRect(s.sw.rects[sel.before], s.sw.rects[sel.value], p));
    });

    // The pill under the wall follows the layout.
    var moveFrom = 0, moveTo = 0, mp = 1;
    for (i = 1; i < LAYOUTS.length; i++) if (t >= WALL_AT[i] - 0.06) { moveFrom = i - 1; moveTo = i; mp = E.glide(seg(t, WALL_AT[i] - 0.06, WALL_AT[i] + 0.3)); }
    var fromEl = pillEls[moveFrom], toEl = pillEls[moveTo];
    pillMark.style.width = mix(fromEl.offsetWidth, toEl.offsetWidth, mp) + 'px';
    pillMark.style.transform = 'translateX(' + mix(fromEl.offsetLeft, toEl.offsetLeft, mp) + 'px)';
    pillEls.forEach(function (el, k) { el.classList.toggle('is-on', k === (mp < 0.5 ? moveFrom : moveTo)); });
    void current;
  }

  // Scene four: the dark deck alone. The camera reads the marks along the top row, pulls back, and W closes a window.
  function renderSolo(t) {
    var inP = E.out(seg(t, 22.7, 23.25)), outP = E.inOut(seg(t, 30.0, 30.45));
    if (t < 22.6 || outP >= 1) { set(cam, 0); set(legend, 0); return; }
    var closed = t >= 27.62;
    soloSw.state(closed ? soloB : solo);
    set(cam, inP * (1 - outP));
    set(soloHost, 1, 'translateY(' + (1 - inP) * 30 + 'px)');

    // The camera: in on the first card's header, along the row to the fourth, back out.
    var rects = soloSw.rects, panelW = soloSw.w, panelH = soloSw.h;
    var left = 960 - panelW / 2, top = 590 - panelH / 2;
    var pad = parseFloat(getComputedStyle(soloSw.el).paddingLeft) || 0;
    function head(i) { var r = snapshotOf(soloSw, solo).rects[ROWS4[i].id]; return { x: left + pad + r.x + r.w * 0.5, y: top + pad + r.y + r.h * 0.12 }; }
    var zin = E.inOut(seg(t, 23.15, 24.0)), pan = E.inOut(seg(t, 24.0, 25.7)), zout = E.inOut(seg(t, 25.75, 26.6));
    var a = head(0), b = head(3);
    var focus = { x: mix(a.x, b.x, pan), y: mix(a.y, b.y, pan) };
    var center = { x: 960, y: 590 };
    var amount = zin * (1 - zout);
    var zoom = 1 + 0.85 * amount;
    var fx = mix(center.x, focus.x, amount), fy = mix(center.y, focus.y, amount);
    cam.style.transform = 'translate(' + (960 - fx * zoom) + 'px,' + (590 - fy * zoom) + 'px) scale(' + zoom + ')';
    void rects;

    // W: the selected window (Build log) closes; the cards close the gap and the selection moves to the next one.
    var lin = E.out(seg(t, 26.65, 27.15));
    set(legend, lin * (1 - outP), 'translateX(-50%) translateY(' + (1 - lin) * 20 + 'px)');
    legendKeys[0].classList.toggle('is-down', t >= 27.5 && t < 27.68);
    if (!closed) {
      soloSw.morph(null, 1);
      soloSw.select(5, soloSw.rects[5]);
    } else {
      var prev = snapshotOf(soloSw, solo);
      var p = seg(t, 27.62, 28.1);
      var drawn = soloSw.morph(prev, p);
      var g = E.glide(seg(t, 27.66, 27.98));
      soloSw.select(5, lerpRect(prev.rects['terminal-build'], drawn[5], g));
    }
  }

  // The keys: ⌥ Tab in scene one, ⌘ Tab in scene five.
  function renderKeys(t) {
    // Scene one: the keys appear under the screen; ⌥ goes down, Tab three times, then ⌥ lets go.
    var kin = E.out(seg(t, 1.25, 1.6)), kout = E.inOut(seg(t, 4.8, 5.25));
    set(keys1, kin * (1 - kout), 'translateX(-50%) translateY(' + ((1 - kin) * 24 + kout * 12) + 'px)');
    keys1.style.bottom = '58px';
    kOpt.classList.toggle('is-down', t >= 1.7 && t < 4.25);
    kTab.classList.toggle('is-down', [1.9, 2.6, 3.3].some(function (d) { return t >= d && t < d + 0.13; }));

    // Scene five: the option key turns over to command, then ⌘ Tab is pressed.
    var din = E.out(seg(t, 30.65, 31.2)), dout = E.inOut(seg(t, 35.95, 36.35));
    if (t < 30.4 || dout >= 1) { set(deck2, 0); set(chips, 0); return; }
    set(deck2, din * (1 - dout), 'translateX(-50%) translateY(' + ((1 - din) * 40 - dout * 16) + 'px) scale(' + (0.97 + 0.03 * din) + ')');
    var turn = E.inOut(seg(t, 32.0, 32.75));
    bkMod.turn.style.transform = 'rotateX(' + (turn * 180) + 'deg)';
    bkMod.el.classList.toggle('is-down', t >= 33.15 && t < 34.6);
    bkTab.el.classList.toggle('is-down', [33.4, 33.85].some(function (d) { return t >= d && t < d + 0.14; }));
    var cin = seg(t, 34.25, 35.1);
    set(chips, (cin > 0 ? 1 : 0) * (1 - dout), 'translateX(-50%)');
    chipEls.forEach(function (el, i) {
      var q = E.out(seg(t, 34.25 + i * 0.12, 34.75 + i * 0.12));
      el.style.opacity = q;
      el.style.transform = 'translateY(' + (1 - q) * 16 + 'px)';
    });
  }

  // The close: the icon's cards riffle out (as on the site), the name rises, then where to get it.
  function renderOutro(t) {
    if (t < 36.4) { set(outro, 0); return; }
    var inP = E.out(seg(t, 36.5, 37.05));
    set(outro, inP);
    outroIn.style.transform = 'scale(' + (0.94 + 0.06 * inP + 0.018 * E.inOut(seg(t, 37, DURATION))) + ')';
    var back = E.glide(seg(t, 37.0, 37.76)), middle = E.glide(seg(t, 37.07, 37.83));
    logoBack.style.transform = 'rotate(' + 31 * (1 - back) + 'deg)';
    logoMiddle.style.transform = 'rotate(' + 17 * (1 - middle) + 'deg)';
    var arrow = E.inOut(seg(t, 37.42, 38.04));
    logoArrow.style.clipPath = 'inset(0 ' + (100 - 100 * arrow) + '% 0 0)';
    var w = E.quint(seg(t, 37.7, 38.4));
    wordSpan.style.transform = 'translateY(' + (1 - w) * 112 + '%)';
    var tg = E.out(seg(t, 38.05, 38.65));
    tag.style.opacity = tg;
    tag.style.transform = 'translateY(' + (1 - tg) * 14 + 'px)';
    var fn = E.out(seg(t, 38.45, 39.05));
    fine.style.opacity = fn;
    fine.style.transform = 'translateY(' + (1 - fn) * 12 + 'px)';
  }

  // ------------------------------------------------------------------ ready: fonts in, every picture decoded
  function settle() {
    var imgs = Array.prototype.slice.call(document.images);
    return Promise.all(imgs.map(function (el) {
      if (el.complete && el.naturalWidth) return el.decode ? el.decode().catch(function () {}) : null;
      return new Promise(function (done) { el.onload = el.onerror = function () { (el.decode ? el.decode() : Promise.resolve()).catch(function () {}).then(done); }; });
    }));
  }
  // Every picture the film shows, kept decoded off stage.
  var cache = layer('layer');
  cache.style.visibility = 'hidden';
  cache.style.left = '-99999px';
  WINDOWS.forEach(function (w) { if (!w.windowless) cache.insertAdjacentHTML('beforeend', img(picture(w))); });
  Object.keys(APPS).forEach(function (a) { cache.insertAdjacentHTML('beforeend', img(icon(a))); });

  var ready = document.fonts.ready.then(function () {
    return settle();
  }).then(function () {
    // Measure what needs fonts and pictures: every state the film animates between.
    fitWall();
    wallReady = true;
    QUERIES.forEach(function (q) { snapshotOf(deskSw, searchState(q[1])); });
    snapshotOf(soloSw, solo);
    render(0);
    return settle();
  });

  window.film = {
    duration: DURATION,
    ready: ready,
    render: function (t) {
      render(t);
      return settle();
    },
    rank: rank
  };
})();
