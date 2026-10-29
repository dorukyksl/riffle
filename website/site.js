/* Riffle's site. The switcher on this page is a copy of the app's, running the app's rules on sample windows: the
   order, the badges, the search ranking and the five layouts. One copy runs a MacBook you can switch windows on;
   the other shows the five layouts. */
(function () {
  'use strict';

  var reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
  var fine = matchMedia('(hover: hover) and (pointer: fine)').matches;

  // ------------------------------------------------------------------ the sample Mac
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
  // Most recently used first, as Riffle lists them. `space` is the desktop a window is on and `at` its place there:
  // left, top and width, in percent of the screen. `ratio` is the picture's width over its height.
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
  WINDOWS.forEach(function (w, i) { w.order = i; w.appName = APPS[w.app].name; });

  // ------------------------------------------------------------------ the logo riffles its cards out once it has loaded
  var logo = document.querySelector('[data-logo]');
  if (logo) {
    var parts = Array.prototype.slice.call(logo.querySelectorAll('img'));
    Promise.all(parts.map(function (img) { return img.decode ? img.decode().catch(function () {}) : Promise.resolve(); })).then(function () {
      requestAnimationFrame(function () { requestAnimationFrame(function () { logo.classList.remove('is-stacked'); }); });
    });
  }

  function icon(app) { return 'img/apps/' + app + '.webp'; }
  function picture(w, big) { return 'img/windows/' + w.id + (big ? '-1400' : '-640') + '.webp'; }
  function h(tag, cls, html) {
    var el = document.createElement(tag);
    if (cls) el.className = cls;
    if (html != null) el.innerHTML = html;
    return el;
  }
  function esc(s) { return String(s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }

  // ------------------------------------------------------------------ search, ranked the way Riffle ranks
  function foldChar(c) {
    var f = c.normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase();
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

  // The best way one query word matches one field: { tier, score, at: [char offsets] } or null.
  function matchWord(t, f) {
    if (!f.len) return null;
    var short = t.length <= 2;
    var idx = f.s.indexOf(t);
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
    // Initials: pieces that each begin a word, in order ("io" for "Invoice October").
    if (t.length >= 2) {
      var ws = words(f), at = [], k = 0;
      for (var w = 0; w < ws.length && k < t.length; w++) {
        var p = ws[w].from, took = 0;
        while (k < t.length && p < ws[w].to && f.s[p] === t[k]) { at.push(p); p++; k++; took++; }
      }
      if (k === t.length && at.length) take(3, 3000, at);
      if (best) return best;
    }
    if (short) return null;
    // In order, starting on a word.
    for (i = 0; i < f.len; i++) {
      if (!f.starts[i] || f.s[i] !== t[0]) continue;
      var pos = [i], q = 1;
      for (var j = i + 1; j < f.len && q < t.length; j++) if (f.s[j] === t[q]) { pos.push(j); q++; }
      if (q === t.length) { take(2, 2000 - (pos[pos.length - 1] - pos[0]), pos); break; }
    }
    if (best) return best;
    // A typo: one edit from four letters, two from eight, against a whole word.
    if (t.length >= 4) {
      var limit = t.length >= 8 ? 2 : 1;
      words(f).forEach(function (wd) {
        var word = f.s.slice(wd.from, wd.to);
        var dist = damerau(t, word, limit);
        if (dist <= limit) {
          var pos = [];
          for (var x = 0; x < word.length; x++) if (t.indexOf(word[x]) >= 0) pos.push(wd.from + x);
          take(1, 1000 + (dist === 1 ? 300 : 0), pos);
        }
      });
    }
    return best;
  }
  function rank(items, query) {
    var tokens = query.split(/\s+/).map(function (w) { return Array.from(w).map(foldChar).join(''); }).filter(Boolean);
    if (!tokens.length) return items.map(function (w) { return { w: w, title: [], app: [] }; });
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
    // Equal scores keep the most recently used first.
    out.sort(function (x, y) { return y.score - x.score || x.w.order - y.w.order; });
    return out;
  }

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

  // ------------------------------------------------------------------ the switcher
  var LAYOUTS = ['deck', 'stage', 'icons', 'titles', 'list'];
  var GLYPH = { min: 'i-min', hidden: 'i-hidden', full: 'i-full', space: 'i-space' };
  function glyph(name) { return '<svg aria-hidden="true"><use href="#' + GLYPH[name] + '"/></svg>'; }

  // What a card says to VoiceOver, as the app's cards do.
  function spoken(w) {
    var parts = [w.windowless ? w.appName : w.title, w.windowless ? 'no open windows' : w.appName];
    if (w.minimized) parts.push('minimized');
    if (w.hidden) parts.push('hidden');
    if (w.fullscreen) parts.push('full screen');
    if (w.space > 1) parts.push('on desktop ' + w.space);
    if (APPS[w.app].badge) parts.push(APPS[w.app].badge + ' unread');
    return parts.join(', ');
  }
  // The state marks: plain glyphs in the deck's header, small chips everywhere else, as in the app.
  function marks(w, chips) {
    var out = [];
    if (w.minimized) out.push(glyph('min'));
    if (w.hidden) out.push(glyph('hidden'));
    if (w.fullscreen) out.push(glyph('full'));
    if (w.space > 1) out.push('<span class="sw__mark">' + glyph('space') + w.space + '</span>');
    if (!out.length) return '';
    return '<span class="sw__marks" aria-hidden="true">' +
      out.map(function (m) { return chips ? '<span class="sw__chip">' + m + '</span>' : m; }).join('') + '</span>';
  }
  function appIcon(w) {
    var badge = APPS[w.app].badge ? '<span class="sw__badge">' + APPS[w.app].badge + '</span>' : '';
    return '<span class="sw__icon"><img src="' + icon(w.app) + '" alt="" width="128" height="128">' + badge + '</span>';
  }
  function thumb(w, extra) {
    if (w.windowless) return '<span class="sw__thumb"><span class="sw__empty"><img src="' + icon(w.app) + '" alt="">No open windows</span>' + (extra || '') + '</span>';
    return '<span class="sw__thumb"><img src="' + picture(w) + '" alt="" loading="lazy" width="640" height="' + Math.round(640 / w.ratio) +
      '" style="--r:' + w.ratio.toFixed(3) + '">' + (extra || '') + '</span>';
  }

  function Switcher(host, opts) {
    Switcher.all.push(this);
    this.opts = opts || {};
    this.el = h('div', 'sw');
    this.el.setAttribute('role', 'listbox');
    this.el.setAttribute('aria-label', this.opts.label || 'Windows');
    host.appendChild(this.el);
    this.rows = [];
    this.index = 0;
    this.searching = false;
    this.query = '';
    var self = this;
    this.el.addEventListener('click', function (e) {
      var item = e.target.closest('.sw__item');
      if (!item) return;
      self.select(+item.dataset.i, true);
      var act = e.target.closest('[data-act]');
      if (act && self.opts.onAction) { self.opts.onAction(act.dataset.act, self.current()); return; }
      if (self.opts.onCommit) self.opts.onCommit(self.current());
    });
    if (fine) {
      this.el.addEventListener('mousemove', function (e) {
        if (self.opts.hoverable && !self.opts.hoverable()) return;
        var item = e.target.closest('.sw__item');
        // Focus follows the pointer's pick when it's in the switcher, so only one window is ever marked.
        if (item && +item.dataset.i !== self.index) self.select(+item.dataset.i, self.el.contains(document.activeElement));
      });
    }
    this.el.addEventListener('keydown', function (e) {
      if (e.defaultPrevented) return;
      var dir = { ArrowRight: 'right', ArrowLeft: 'left', ArrowDown: 'down', ArrowUp: 'up' }[e.key];
      if (dir && !(e.target.tagName === 'INPUT' && (dir === 'left' || dir === 'right'))) {
        e.preventDefault();
        self.move(dir);
        if (e.target.tagName !== 'INPUT') self.focus();
      } else if (e.key === 'Enter') {
        e.preventDefault();
        if (self.opts.onCommit) self.opts.onCommit(self.current());
      } else if (e.target.tagName !== 'INPUT' && !e.metaKey && !e.ctrlKey) {
        // The app's one-key commands, with ⌥ still held or not: W closes the selected window, M minimizes it, S or /
        // searches.
        var act = { KeyW: 'close', KeyM: 'min' }[e.code];
        if (act && self.opts.onAction) { e.preventDefault(); self.opts.onAction(act, self.current()); }
        else if ((e.code === 'KeyS' || e.code === 'Slash') && self.opts.onSearch) { e.preventDefault(); self.opts.onSearch(); }
      }
    });
    addEventListener('resize', function () { self.flow(); self.place(false); });
  }
  Switcher.all = [];
  Switcher.prototype.current = function () { return this.rows[this.index]; };
  // While searching, the panel keeps the size it had when the search began: the field stays where it was and never
  // sticks out of a panel narrowed to one card, and nothing jumps as the results thin out.
  Switcher.prototype.lock = function () {
    // Never past the panel's own limit (the MacBook's screen), even if the page is resized while searching.
    var max = getComputedStyle(this.el).maxWidth;
    this.el.style.minWidth = 'min(' + this.el.offsetWidth + 'px, ' + (max === 'none' ? '100%' : max) + ')';
    this.el.style.minHeight = this.el.offsetHeight + 'px';
  };
  Switcher.prototype.unlock = function () { this.el.style.minWidth = this.el.style.minHeight = ''; };

  Switcher.prototype.render = function (rows, layout, selected) {
    this.rows = rows;
    this.layout = layout;
    this.el.className = 'sw sw--' + layout + (this.opts.dark ? ' sw--dark' : '');
    // The search field is made once and kept while the results under it change.
    if (this.searching && !this.searchEl) {
      this.searchEl = h('label', 'sw__search', '<svg aria-hidden="true"><use href="#i-search"/></svg>' +
        '<input type="text" spellcheck="false" autocomplete="off" aria-label="Search windows" placeholder="Search windows"><output></output>');
      this.el.prepend(this.searchEl);
      this.input = this.searchEl.querySelector('input');
    } else if (!this.searching && this.searchEl) {
      this.searchEl.remove();
      this.searchEl = this.input = null;
    }
    if (this.searchEl) this.searchEl.querySelector('output').textContent = this.query.trim() ? rows.length + ' of ' + this.total + ' windows' : '';
    var parts = [];
    var stage = (layout === 'stage' || layout === 'list') ? '<div class="sw__stage" aria-hidden="true"></div>' : '';
    if (layout === 'stage') parts.push(stage);
    var items = rows.map(function (w, i) { return this.item(w, i, layout); }, this).join('');
    parts.push('<div class="sw__items"><span class="sw__plate" aria-hidden="true"></span>' +
      (rows.length ? items : '<p class="sw__none">No window matches. Try fewer letters.</p>') + '</div>');
    if (layout === 'list') parts.push(stage);
    if (stage) rows.forEach(function (w) { if (!w.windowless) preload(picture(w, true)); });
    if (!this.bodyEl) { this.bodyEl = h('div', 'sw__body'); this.el.appendChild(this.bodyEl); }
    this.bodyEl.innerHTML = parts.join('');
    this.itemsEl = this.el.querySelector('.sw__items');
    this.plate = this.el.querySelector('.sw__plate');
    this.stageEl = this.el.querySelector('.sw__stage');
    this.flow();
    this.select(Math.max(0, Math.min(selected || 0, rows.length - 1)), false, true);
  };

  Switcher.prototype.item = function (w, i, layout) {
    var t = w.windowless ? w.appName : w.title;
    var title = marked(t, w.windowless ? w.matchApp : w.matchTitle);
    var app = marked(w.appName, w.matchApp);
    var open = '<button type="button" class="sw__item' + (w.minimized || w.hidden ? ' is-dim' : '') + '" role="option" data-i="' + i +
      '" tabindex="-1" aria-label="' + esc(spoken(w)) + '">';
    if (layout === 'deck') {
      // Pointing at a card shows its quick actions, as in the app.
      var acts = this.opts.actions && !w.windowless ? '<span class="sw__acts" aria-hidden="true">' +
        '<span class="sw__act sw__act--close" data-act="close" title="Close (W)"></span>' +
        '<span class="sw__act sw__act--min" data-act="min" title="Minimize (M)"></span></span>' : '';
      return open + '<span class="sw__head">' + appIcon(w) + '<span class="sw__title">' + title + '</span>' + marks(w, false) + '</span>' +
        thumb(w, acts) + '</button>';
    }
    if (layout === 'stage') return open + thumb(w, appIcon(w) + marks(w, true)) + '</button>';
    if (layout === 'icons') return open + marks(w, true) + appIcon(w) + '<span class="sw__title">' + title + '</span></button>';
    if (layout === 'titles') {
      return open + appIcon(w) + '<span class="sw__title">' + title + '</span>' + marks(w, true) + '<span class="sw__num">' + (i + 1) + '</span></button>';
    }
    return open + appIcon(w) + '<span class="sw__text"><span class="sw__title">' + title + '</span>' +
      (w.windowless ? '' : '<span class="sw__app">' + app + '</span>') + '</span>' + marks(w, true) +
      '<span class="sw__num">' + (i + 1) + '</span></button>';
  };

  // Rows like the app's: as few as fit, as even as possible, earlier rows taking more, each one centered.
  Switcher.prototype.flow = function () {
    if (!this.itemsEl) return;
    var items = this.itemsEl.querySelectorAll('.sw__item');
    var layout = this.layout, n = items.length;
    var grid = layout === 'deck' || layout === 'icons';
    this.itemsEl.style.gridTemplateColumns = '';
    this.el.style.width = '';
    items.forEach(function (el) { el.style.gridColumn = ''; });
    if (layout === 'stage') {
      // The filmstrip keeps the cell size it had for every window, so a search that leaves one doesn't blow it up.
      var cells = Math.max(n, this.searching && this.total || 0, 1);
      this.itemsEl.style.gridAutoColumns = 'calc((100% - ' + (cells - 1) + ' * 0.6em) / ' + cells + ')';
      return;
    }
    if (!grid || !n) return;
    var most = layout === 'deck' ? (n <= 4 ? n : n <= 8 ? 4 : n <= 15 ? 5 : 6) : Math.min(n, 7);
    if (this.opts.most) most = Math.min(n, this.opts.most);
    var rows = Math.ceil(n / most), base = Math.floor(n / rows), extra = n % rows, i = 0;
    var cell = layout === 'deck' ? 12.4 : 7.4, gap = layout === 'deck' ? 0.6 : 0.4;
    this.itemsEl.style.gridTemplateColumns = 'repeat(' + (2 * most) + ', ' + (cell - gap) / 2 + 'em)';
    this.itemsEl.style.columnGap = gap / 2 + 'em';
    this.el.style.width = (most * cell + 2.2) + 'em';
    for (var r = 0; r < rows; r++) {
      var k = base + (r < extra ? 1 : 0);
      for (var j = 0; j < k; j++, i++) items[i].style.gridColumn = (j === 0 && k < most ? (most - k + 1) + ' / ' : '') + 'span 2';
    }
  };

  Switcher.prototype.select = function (i, focus, instant) {
    if (!this.rows.length) { if (this.plate) this.plate.style.opacity = 0; this.index = 0; return; }
    this.index = i;
    var items = this.itemsEl.querySelectorAll('.sw__item');
    items.forEach(function (el, k) {
      var on = k === i;
      el.classList.toggle('is-selected', on);
      el.setAttribute('aria-selected', String(on));
      el.tabIndex = on && !this.opts.passive ? 0 : -1;
    }, this);
    if (this.stageEl) this.paintStage();
    this.place(!instant && !reduce);
    if (focus) this.focus();
    if (this.opts.onSelect) this.opts.onSelect(this.current());
  };
  Switcher.prototype.focus = function () {
    if (this.opts.passive) return;
    var el = this.itemsEl && this.itemsEl.querySelectorAll('.sw__item')[this.index];
    if (el) el.focus({ preventScroll: true });
  };
  // The large picture is one img kept from pick to pick. Its next picture goes in once it's decoded, so the stage never
  // shows an empty box while you move along, and nothing but the picture and the words under it changes.
  Switcher.prototype.paintStage = function () {
    var w = this.current();
    if (!w) { this.stageEl.innerHTML = ''; this.bigImg = null; return; }
    var big = this.stageEl.querySelector('.sw__big');
    if (!big) {
      this.stageEl.innerHTML = '<div class="sw__big"></div><div class="sw__info"></div>';
      big = this.stageEl.firstChild;
      this.bigImg = null;
    }
    this.stageEl.lastChild.innerHTML = appIcon(w) + '<div><span class="sw__title">' + esc(w.windowless ? w.appName : w.title) + '</span><span class="sw__app">' +
      esc(w.appName) + '</span></div><span class="sw__counter">' + (this.index + 1) + ' / ' + this.rows.length + '</span>';
    if (w.windowless) {
      big.innerHTML = '<span class="sw__empty"><img src="' + icon(w.app) + '" alt="">No open windows</span>';
      this.bigImg = null;
      return;
    }
    var img = this.bigImg;
    if (!img) {
      big.innerHTML = '';
      img = this.bigImg = document.createElement('img');
      img.alt = '';
      big.appendChild(img);
    }
    var src = picture(w, true), ratio = w.ratio;
    if (img.dataset.want === src) return;
    img.dataset.want = src;
    function show() {
      if (img.dataset.want !== src) return;
      img.width = 1400;
      img.height = Math.round(1400 / ratio);
      img.style.setProperty('--r', ratio.toFixed(3));
      img.src = src;
    }
    var next = preload(src);
    if (next.decode) next.decode().then(show, show); else show();
  };
  Switcher.prototype.place = function (animate) {
    var el = this.itemsEl && this.itemsEl.querySelectorAll('.sw__item')[this.index];
    if (!el) { if (this.plate) this.plate.style.opacity = 0; return; }
    this.el.classList.toggle('no-glide', !animate);
    this.plate.style.width = el.offsetWidth + 'px';
    this.plate.style.height = el.offsetHeight + 'px';
    this.plate.style.transform = 'translate(' + el.offsetLeft + 'px,' + el.offsetTop + 'px)';
    this.plate.style.opacity = 1;
    // A switcher that scrolls (on a phone's small screen) keeps its selection in view, without moving the page.
    if (this.el.scrollHeight > this.el.clientHeight + 1) {
      var er = el.getBoundingClientRect(), cr = this.el.getBoundingClientRect();
      if (er.top < cr.top) this.el.scrollTop -= cr.top - er.top + 6;
      else if (er.bottom > cr.bottom) this.el.scrollTop += er.bottom - cr.bottom + 6;
    }
  };
  // Tab and ⇧ Tab wrap around; the arrows follow the layout's own geometry.
  Switcher.prototype.step = function (d) {
    var n = this.rows.length;
    if (n) this.select((this.index + d + n) % n, false);
  };
  Switcher.prototype.move = function (dir) {
    var n = this.rows.length;
    if (!n) return;
    var vertical = this.layout === 'deck' || this.layout === 'icons';
    if (dir === 'left' || dir === 'right' || !vertical) { this.step(dir === 'left' || dir === 'up' ? -1 : 1); return; }
    var items = Array.prototype.slice.call(this.itemsEl.querySelectorAll('.sw__item'));
    var me = items[this.index], x = me.offsetLeft + me.offsetWidth / 2;
    var tops = items.map(function (el) { return el.offsetTop; }).filter(function (t, k, a) { return a.indexOf(t) === k; });
    var row = tops.indexOf(me.offsetTop) + (dir === 'down' ? 1 : -1);
    if (row < 0 || row >= tops.length) return;
    var best = -1, gap = Infinity;
    items.forEach(function (el, k) {
      if (el.offsetTop !== tops[row]) return;
      var d = Math.abs(el.offsetLeft + el.offsetWidth / 2 - x);
      if (d < gap) { gap = d; best = k; }
    });
    if (best >= 0) this.select(best, false);
  };

  // The switcher's list: windows most recent first, then apps without windows.
  function listed(order) {
    return order.filter(function (w) { return !w.windowless; }).concat(order.filter(function (w) { return w.windowless; }));
  }
  function plain(list) { return list.map(function (w) { w.matchTitle = w.matchApp = null; return w; }); }

  var preloaded = {};
  function preload(src) {
    if (!preloaded[src]) { preloaded[src] = new Image(); preloaded[src].src = src; }
    return preloaded[src];
  }

  // ------------------------------------------------------------------ the MacBook's keyboard
  // Drawn row by row with the real keys' widths (in key units, every row 14.5 wide); the legends are left off, since at
  // this size they would only be a blur. The function row is half height; the arrows sit low, up and down stacked.
  var keyboard = document.querySelector('[data-keyboard]');
  if (keyboard) {
    var ROWS = [
      [1.5, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1],
      [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1.5],
      [1.5, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1],
      [1.8, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1.7],
      [2.3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2.2],
      [1, 1, 1, 1.25, 5, 1.25, 1, 'low', 'updown', 'low']
    ];
    keyboard.innerHTML = ROWS.map(function (row) {
      return '<div>' + row.map(function (w) {
        if (w === 'low') return '<i class="is-low"></i>';
        if (w === 'updown') return '<b class="updown"><i></i><i></i></b>';
        return '<i style="flex-grow:' + w + '"></i>';
      }).join('') + '</div>';
    }).join('');
  }

  // ------------------------------------------------------------------ boxes that scale
  // The MacBook's screen, the hero's switcher, the layouts' wall and the search scale with their box: --u is 1% of the box's
  // width, as a container unit would be. It's measured here rather than by container queries, which made every change
  // inside a switcher lay it all out again, slowly enough to stall pointing along the stage and list layouts.
  var sized = Array.prototype.slice.call(document.querySelectorAll('.mac, .hero__show, .stage-demo__wall, .find__stage'));
  function setUnit(el, width) {
    var u = (width / 100).toFixed(3) + 'px';
    if (el.style.getPropertyValue('--u') === u) return;
    el.style.setProperty('--u', u);
    Switcher.all.forEach(function (sw) { if (el.contains(sw.el)) { sw.flow(); sw.place(false); } });
  }
  sized.forEach(function (el) {
    var cs = getComputedStyle(el);
    setUnit(el, el.clientWidth - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight));
  });
  if ('ResizeObserver' in window) {
    var resized = new ResizeObserver(function (entries) { entries.forEach(function (e) { setUnit(e.target, e.contentRect.width); }); });
    sized.forEach(function (el) { resized.observe(el); });
  }

  // ------------------------------------------------------------------ the real keys
  // The visitor holds the real ⌥ and clicks the tab key on screen: a page never gets ⌘ Tab (macOS keeps it), and gets
  // ⌥ Tab only where nothing on the Mac owns it already (another switcher, or Riffle itself, takes it first, and no page
  // can change that). ⌥ on its own always arrives and is nobody's shortcut, so the switchers hear it (the MacBook lights
  // its option key), and a click stands in for Tab. A real Tab still works where it arrives: ⌥ Tab opens, Tab moves on,
  // ⇧ Tab goes back, the arrows follow the layout, and letting go of ⌥ switches. Only while one of the page's switchers
  // is in view; anywhere else ⌥ Tab keeps its usual meaning. The first in view takes it: the MacBook before the one at
  // the top. A visitor whose ⌥ Tab went to their own switcher, or who tries ⌘ Tab, is told what to do instead.
  var holders = [], holding = null;
  var MODIFIERS = { Alt: 1, Meta: 1, Shift: 1, Control: 1, CapsLock: 1, Fn: 1, FnLock: 1, OS: 1 };
  // ⌥ and ⌘: when each went down and up, whether another key came meanwhile, and whether a switcher was in view.
  var mods = { Alt: { down: false, at: 0, up: 0, used: true, aimed: false }, Meta: { down: false, at: 0, up: 0, used: true, aimed: false } };
  function holderInView() { for (var i = 0; i < holders.length; i++) if (holders[i].inView()) return holders[i]; return null; }
  // 'option': ⌥ Tab went to the visitor's own switcher. 'command': the visitor tried ⌘ Tab.
  function wentElsewhere(kind) {
    holders.forEach(function (h) { if (h.inView() && h.elsewhere) h.elsewhere(kind); });
  }
  function typing(el) { return /^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName) || el.isContentEditable; }
  var ARROWS = { ArrowRight: 'right', ArrowLeft: 'left', ArrowDown: 'down', ArrowUp: 'up' };
  document.addEventListener('keydown', function (e) {
    var m = mods[e.key];
    if (m) {
      if (!m.down) {
        m.down = true; m.at = Date.now(); m.used = false; m.aimed = !!holderInView();
        if (e.key === 'Alt') holders.forEach(function (h) { if (h.option) h.option(true); });
      }
      return;
    }
    if (!MODIFIERS[e.key]) {
      if (mods.Alt.down) mods.Alt.used = true;
      if (mods.Meta.down) mods.Meta.used = true;
    }
    if (!e.altKey || e.metaKey || e.ctrlKey) return;
    var dir = ARROWS[e.key];
    if (e.key !== 'Tab' && !dir) return;
    // Only Tab opens Riffle; the arrows steer it once it's open (and move the caret in a text field).
    if (dir && (!holding || typing(e.target))) return;
    var target = holding || holderInView();
    if (!target) return;
    e.preventDefault();
    holding = target;
    if (dir) target.move(dir); else target.tab(e.shiftKey ? -1 : 1);
  }, true);
  document.addEventListener('keyup', function (e) {
    var m = mods[e.key];
    if (!m) return;
    m.down = false;
    m.up = Date.now();
    if (e.key !== 'Alt') return;
    if (holding) { var target = holding; holding = null; target.release(); }
    holders.forEach(function (h) { if (h.option) h.option(false); });
  }, true);
  addEventListener('blur', function () {
    var target = holding;
    holding = null;
    if (target) target.cancel();
    // ⌥ or ⌘ down with no key that reached the page, or let go of a moment ago: what took the keys took the window too.
    var now = Date.now();
    function took(m) { return m.aimed && !m.used && (m.down || now - m.up < 400); }
    var optionWasDown = mods.Alt.down;
    // ⌥ let go while the window was gone: what was open is put away, not switched to.
    if (optionWasDown) holders.forEach(function (h) { if (h.option) h.option(false, true); });
    if (took(mods.Meta)) wentElsewhere('command');
    else if (took(mods.Alt)) wentElsewhere('option');
    mods.Alt.down = mods.Meta.down = false;
    mods.Alt.used = mods.Meta.used = true;
  });
  function watchView(el, ratio) {
    var seen = { now: false };
    if ('IntersectionObserver' in window) new IntersectionObserver(function (entries) { seen.now = entries[0].intersectionRatio >= ratio; }, { threshold: [0, ratio, 1] }).observe(el);
    return function () { return seen.now; };
  }

  // ------------------------------------------------------------------ the top of the page
  // Riffle open on the dusk, its selection riffling through the windows on its own. Point at it and the selection follows
  // the pointer, as in the app; move away and it riffles on from there. The menu bar turns to paper once the dusk has
  // scrolled away.
  var heroShow = document.querySelector('[data-hero-show]');
  if (heroShow) (function () {
    // Three to a row, as the app balances six windows on a narrower screen.
    var hero = new Switcher(heroShow, { dark: true, most: 3, passive: true });
    hero.render(plain(WINDOWS.slice(0, 6)), 'deck', 1);
    var seen = true, pointing = false, keyed = false, rest = 0;
    new IntersectionObserver(function (entries) { seen = entries[0].isIntersecting; }).observe(heroShow);
    heroShow.addEventListener('pointerenter', function (e) { if (e.pointerType === 'mouse') pointing = true; });
    heroShow.addEventListener('pointerleave', function () { pointing = false; });
    if (!reduce) setInterval(function () { if (seen && !pointing && !keyed && Date.now() > rest && !document.hidden) hero.step(1); }, 1600);
    // The words next to it say "hold ⌥ and press Tab"; doing it moves the selection here.
    var heroInView = watchView(heroShow, 0.5);
    holders.push({
      inView: heroInView,
      tab: function (d) { keyed = true; hero.step(d); },
      move: function (dir) { keyed = true; hero.move(dir); },
      release: function () { keyed = false; rest = Date.now() + 2400; },
      cancel: function () { keyed = false; }
    });
  })();
  var nav = document.querySelector('.nav');
  var top = document.getElementById('top');
  if (nav && top) {
    new IntersectionObserver(function (entries) { nav.classList.toggle('is-paper', !entries[0].isIntersecting); },
      { rootMargin: '-64px 0px 0px 0px' }).observe(top);
  }

  // ------------------------------------------------------------------ the MacBook
  // Riffle on a MacBook with windows on three desktops, one in full screen and one in the Dock. The line under it says
  // what just happened. The first time its lid is open (or, where the lid doesn't move, it comes into view) it shows
  // itself once: to another desktop, then by search to the Dock. Anything the visitor does in the section stops that at
  // once and hands it over.
  var mac = document.querySelector('[data-mac]');
  var chosenLayout = 'deck';
  if (mac) (function () {
    var section = mac.closest('section');
    // Where the lid opens with the scroll, the demo wakes once it's open and sleeps again if you scroll back above it.
    var lidMoves = !reduce && window.CSS && CSS.supports('animation-timeline: view()');
    var laptopOpen = !lidMoves;
    section.classList.toggle('is-open', laptopOpen);
    var spaces = mac.querySelector('[data-spaces]');
    var screen = mac.querySelector('[data-screen]');
    var overlay = mac.querySelector('[data-overlay]');
    var dock = mac.querySelector('[data-dock]');
    var frontApp = mac.querySelector('[data-front-app]');
    var extra = mac.querySelector('[data-open-switcher]');
    var keysEl = document.querySelector('[data-keys]');
    var modKey = keysEl.querySelector('[data-key="mod"]');
    var tabKey = keysEl.querySelector('[data-key="tab"]');
    var sayEl = keysEl.querySelector('[data-say]');
    // Closed, the laptop and its keys can't be reached by Tab either: nothing in them is there to use yet.
    var laptopEl = mac.closest('[data-laptop]');
    function wake(open) { if (laptopEl) laptopEl.inert = !open; keysEl.inert = !open; }
    wake(laptopOpen);
    // The words: hold the real ⌥ and click tab on screen; without a keyboard, the option key on screen stays down when
    // tapped, and a second tap lets go.
    var touch = !matchMedia('(hover: hover) and (pointer: fine)').matches;
    var HINT = touch ? 'Tap <kbd>option</kbd>, then <kbd>tab</kbd>.' : 'Hold <kbd>⌥</kbd> on your keyboard and click <kbd>tab</kbd> below.';
    var READY_HINT = 'Keep holding <kbd>⌥</kbd> and click <kbd>tab</kbd>.';
    var LATCHED_HINT = 'Option is held. Now ' + (touch ? 'tap' : 'click') + ' <kbd>tab</kbd>.';
    var NEED_OPTION = touch ? 'Tap <kbd>option</kbd> first: it stays down. Then <kbd>tab</kbd>.' : 'Hold <kbd>⌥</kbd> while you click <kbd>tab</kbd>.';
    var OPEN_HINT = 'Click a window to switch to it. <kbd>S</kbd> searches, <kbd>W</kbd> closes, <kbd>M</kbd> minimizes.';
    var TAKEN_HINT = 'If your Mac opened its own switcher, it already uses <kbd>⌥</kbd> <kbd>Tab</kbd>. Here, hold <kbd>⌥</kbd> and click <kbd>tab</kbd> below instead.';
    var COMMAND_HINT = '<kbd>⌘</kbd> <kbd>Tab</kbd> always goes to your Mac. Here, hold <kbd>⌥</kbd> and click <kbd>tab</kbd> below.';
    function heldHint() {
      return latched
        ? (touch ? 'Tap <kbd>tab</kbd> to move on, or a window to switch to it. Tap <kbd>option</kbd> again to switch.' : 'Click <kbd>tab</kbd> to move on, or point at a window. Click <kbd>option</kbd> again to switch.')
        : 'Click <kbd>tab</kbd> to move on, or point at a window. Let go of <kbd>⌥</kbd> to switch.';
    }
    // ⌥ held on the keyboard, or the option key on screen left down.
    var optionKey = false, latched = false;
    function held() { return optionKey || latched; }
    function paintKeys() {
      var down = held() || (state.open && (state.held || state.touring));
      modKey.classList.toggle('is-down', down);
      modKey.setAttribute('aria-pressed', String(held()));
      keysEl.classList.toggle('is-ready', held() && !state.open);
    }
    function nudge(key) {
      key.classList.remove('is-nudged');
      void key.offsetWidth;
      key.classList.add('is-nudged');
    }

    // The desktop as it starts, so "Start over" can put it back.
    var initial = WINDOWS.map(function (w) { return { w: w, minimized: !!w.minimized, hidden: !!w.hidden }; });
    var state = { order: WINDOWS.slice(), space: 1, front: WINDOWS[0], open: false, touring: false, held: false };
    var winEls = {};

    WINDOWS.forEach(function (w) {
      if (w.windowless) return;
      var el = h('div', 'win' + (w.fullscreen ? ' win--full' : ''));
      el.innerHTML = '<img src="' + picture(w, w.fullscreen || (w.at && w.at[2] > 45)) + '" alt="" width="1400" height="' + Math.round(1400 / w.ratio) + '">';
      if (!w.fullscreen) {
        el.style.left = w.at[0] + '%';
        el.style.top = w.at[1] + '%';
        el.style.width = w.at[2] + '%';
      }
      mac.querySelector('[data-space="' + w.space + '"]').appendChild(el);
      winEls[w.id] = el;
    });
    var dockApps = ['finder', 'safari', 'chrome', 'mail', 'messages', 'notes', 'music', 'xcode', 'terminal', 'preview'];
    dock.innerHTML = dockApps.map(function (a) { return '<img src="' + icon(a) + '" alt="" data-dock-app="' + a + '">'; }).join('') +
      '<span class="dock__sep"></span><img src="img/icon-64.png" alt="" class="dock__riffle"><span class="dock__mins" data-dock-mins></span>';
    var mins = dock.querySelector('[data-dock-mins]');

    function paint() {
      state.order.forEach(function (w, i) {
        var el = winEls[w.id];
        if (!el) return;
        el.style.zIndex = String(100 - i);
        el.hidden = !!(w.minimized || w.hidden || w.closed);
      });
      mins.innerHTML = state.order.filter(function (w) { return w.minimized && !w.closed; }).map(function (w) {
        return '<span class="dock__min" data-min="' + w.id + '"><img src="' + picture(w) + '" alt=""></span>';
      }).join('');
      frontApp.textContent = state.front.appName;
      spaces.style.transform = 'translateX(' + (-(state.space - 1) * 100) + '%)';
      screen.classList.toggle('is-fullscreen', state.space === 3);
    }
    var said = '';
    function say(html) { said = html; sayEl.innerHTML = html; }

    var sw = new Switcher(overlay, {
      label: 'Riffle',
      actions: true,
      // While it shows itself, the pointer resting on it doesn't steer it.
      hoverable: function () { return !state.touring; },
      onCommit: function () { commit(); },
      onAction: function (act, w) { act === 'close' ? closeWindow(w) : minimize(w); },
      onSearch: function () { search(); }
    });

    // On a phone the deck's cards would be too small to read on the laptop's screen: it shows the titles instead.
    var phone = matchMedia('(max-width: 760px)');
    function layoutNow() { return phone.matches && chosenLayout === 'deck' ? 'titles' : chosenLayout; }
    function rows() { return plain(listed(state.order.filter(function (w) { return !w.closed; }))); }
    function open() {
      if (state.open) return;
      state.open = true;
      overlay.hidden = false;
      sw.searching = false;
      sw.query = '';
      if (sw.searchEl) { sw.searchEl.remove(); sw.searchEl = sw.input = null; }
      sw.unlock();
      var list = rows();
      sw.total = list.length;
      sw.render(list, layoutNow(), Math.min(1, list.length - 1));
      if (!state.touring) { sw.focus(); say(state.held ? heldHint() : OPEN_HINT); }
      paintKeys();
      extra.setAttribute('aria-expanded', 'true');
    }
    function close() {
      if (!state.open) return;
      state.open = false;
      if (overlay.contains(document.activeElement)) tabKey.focus({ preventScroll: true });
      overlay.hidden = true;
      paintKeys();
      extra.setAttribute('aria-expanded', 'false');
    }
    function commit() {
      if (!state.open) return;
      var w = sw.current();
      close();
      if (w) activate(w);
      if (!state.touring) tabKey.focus({ preventScroll: true });
    }
    function step() {
      if (!state.open) { open(); return; }
      sw.step(1);
      if (!state.touring) sw.focus();
    }
    function search() {
      // Searching keeps Riffle open after ⌥ is let go, as in the app.
      state.held = false;
      latched = false;
      paintKeys();
      sw.searching = true;
      sw.query = '';
      sw.render(rows(), layoutNow(), 0);
      sw.lock();
      sw.input.addEventListener('input', function () {
        sw.query = sw.input.value;
        var list = rank(listed(state.order.filter(function (w) { return !w.closed; })), sw.query.trim()).map(function (r) {
          r.w.matchTitle = r.title;
          r.w.matchApp = r.app;
          return r.w;
        });
        sw.render(list, layoutNow(), 0);
      });
      sw.input.addEventListener('keydown', function (e) { if (e.key === 'Enter') { e.preventDefault(); commit(); } });
      if (!state.touring) sw.input.focus({ preventScroll: true });
    }

    function bringForward(w, from) {
      var el = winEls[w.id];
      if (!el || reduce) return;
      if (from) {
        var to = el.getBoundingClientRect();
        el.animate([
          { transformOrigin: '0 0', transform: 'translate(' + (from.left - to.left) + 'px,' + (from.top - to.top) + 'px) scale(' + from.width / to.width + ')', opacity: 0.5 },
          { transformOrigin: '0 0', transform: 'none', opacity: 1 }
        ], { duration: 520, easing: 'cubic-bezier(0.2, 0.8, 0.2, 1)' });
      } else {
        el.classList.remove('is-raised');
        void el.offsetWidth;
        el.classList.add('is-raised');
      }
    }
    function dockSlot(w) { var m = mins.querySelector('[data-min="' + w.id + '"]'); return m ? m.getBoundingClientRect() : null; }

    // Exactly the window picked, from wherever it was, and a line saying where that was.
    function activate(w) {
      var from = w.minimized ? dockSlot(w) : null;
      var was = { minimized: !!w.minimized, hidden: !!w.hidden, space: state.space };
      state.order.splice(state.order.indexOf(w), 1);
      state.order.unshift(w);
      state.front = w;
      if (w.windowless) { paint(); say(esc(w.appName) + ' has no open windows, so Riffle brings the app forward.'); return; }
      w.minimized = false;
      w.hidden = false;
      state.space = w.space;
      paint();
      bringForward(w, from);
      if (was.minimized) say('<strong>' + esc(w.title) + '</strong> was minimized. Riffle brought it back.');
      else if (was.hidden) say(esc(w.appName) + ' was hidden. Riffle showed <strong>' + esc(w.title) + '</strong> again.');
      else if (w.fullscreen) say('<strong>' + esc(w.title) + '</strong> is in full screen, on a desktop of its own.');
      else if (w.space !== was.space) say('<strong>' + esc(w.title) + '</strong> was on Desktop ' + w.space + '. Riffle took you there.');
      else say('<strong>' + esc(w.title) + '</strong> came to the front.');
    }
    // Riffle's quick actions, from the switcher.
    function closeWindow(w) {
      if (!w || w.windowless) return;
      var el = winEls[w.id];
      w.closed = true;
      var keep = Math.min(sw.index, sw.rows.length - 2);
      if (el && !reduce && !el.hidden) {
        el.animate([{ opacity: 1, scale: 1 }, { opacity: 0, scale: 0.96 }], { duration: 220, easing: 'ease-in' }).onfinish = paint;
      } else paint();
      sw.render(rows(), layoutNow(), Math.max(0, keep));
      sw.focus();
      say('Closed <strong>' + esc(w.title) + '</strong> without leaving the switcher.');
    }
    function minimize(w) {
      if (!w || w.windowless || w.minimized) return;
      var el = winEls[w.id];
      var from = el && !el.hidden ? el.getBoundingClientRect() : null;
      w.minimized = true;
      var index = sw.index;
      paint();
      var slot = dockSlot(w);
      if (from && slot && !reduce) {
        var ghost = el.cloneNode(true);
        ghost.hidden = false;
        ghost.style.cssText += ';position:fixed;left:' + from.left + 'px;top:' + from.top + 'px;width:' + from.width + 'px;z-index:200;margin:0';
        document.body.appendChild(ghost);
        ghost.animate([
          { transformOrigin: '0 0', transform: 'none', opacity: 1 },
          { transformOrigin: '0 0', transform: 'translate(' + (slot.left - from.left) + 'px,' + (slot.top - from.top) + 'px) scale(' + slot.width / from.width + ')', opacity: 0.4 }
        ], { duration: 460, easing: 'cubic-bezier(0.5, 0, 0.75, 0)' }).onfinish = function () { ghost.remove(); };
      }
      sw.render(rows(), layoutNow(), index);
      sw.focus();
      say('Minimized <strong>' + esc(w.title) + '</strong>. Riffle still lists it.');
    }

    // The tour: once, the first time the lid is open (or the Mac mostly in view), never with reduced motion.
    var timers = [];
    function later(ms, fn) { timers.push(setTimeout(fn, ms)); }
    function stopTour() {
      if (!state.touring) return;
      timers.forEach(clearTimeout);
      timers = [];
      state.touring = false;
      say(state.open ? OPEN_HINT : HINT);
    }
    function flash(key) {
      key.classList.add('is-down');
      setTimeout(function () { key.classList.remove('is-down'); }, 150);
    }
    function tour() {
      state.touring = true;
      var t = 500;
      later(t, function () { open(); say('Hold <kbd>⌥</kbd> and click <kbd>tab</kbd>: every window, from every desktop.'); });
      t += 1200; later(t, function () { flash(tabKey); step(); });
      t += 1100; later(t, function () { commit(); });
      t += 3200; later(t, function () { open(); say('Or press <kbd>S</kbd> and type a few letters.'); });
      t += 1000; later(t, function () { search(); });
      'proj'.split('').forEach(function (c, i) {
        later(t + 400 + i * 170, function () {
          if (!sw.input) return;
          sw.input.value += c;
          sw.input.dispatchEvent(new Event('input'));
        });
      });
      t += 400 + 4 * 170 + 900; later(t, function () { commit(); });
      t += 3400; later(t, function () {
        timers = [];
        state.touring = false;
        say('Your turn: ' + (touch ? 'tap <kbd>option</kbd>, then <kbd>tab</kbd>.' : 'hold <kbd>⌥</kbd> and click <kbd>tab</kbd>.'));
        paintKeys();
        keysEl.classList.add('is-inviting');
      });
    }
    var toured = false;
    function setOpen(open) {
      if (open === laptopOpen) return;
      laptopOpen = open;
      section.classList.toggle('is-open', open);
      wake(open);
      if (open && !toured) { toured = true; tour(); }
      if (!open) { stopTour(); close(); }
    }
    var openedMark = section.querySelector('[data-opened]');
    if (lidMoves && openedMark && 'IntersectionObserver' in window) {
      new IntersectionObserver(function (entries) {
        var e = entries[0];
        setOpen(e.isIntersecting || e.boundingClientRect.top < 0);
      }).observe(openedMark);
    } else if (!reduce && 'IntersectionObserver' in window) {
      var watch = new IntersectionObserver(function (entries) {
        if (!entries[0].isIntersecting) return;
        watch.disconnect();
        toured = true;
        tour();
      }, { threshold: 0.55 });
      watch.observe(mac);
    }
    ['pointerdown', 'keydown', 'focusin'].forEach(function (type) { section.addEventListener(type, stopTour, true); });

    function reset() {
      stopTour();
      close();
      initial.forEach(function (s) { s.w.minimized = s.minimized; s.w.hidden = s.hidden; s.w.closed = false; });
      state.order = WINDOWS.slice();
      state.space = 1;
      state.front = WINDOWS[0];
      paint();
      latched = false;
      paintKeys();
      keysEl.classList.remove('is-inviting');
      say(HINT);
    }

    // The real keys. ⌥ down lights the option key on screen and makes the tab key ready; with it held, each click on
    // tab is a press of Tab (the first opens Riffle on the second window, as the app does), the pointer picks a window,
    // and letting go of ⌥ switches. A real Tab or the arrows, where they arrive, do the same as the clicks.
    var macInView = watchView(mac, 0.35);
    function grab(key) {
      stopTour();
      keysEl.classList.remove('is-inviting');
      if (key) flash(key);
      state.held = true;
      if (state.open) return true;
      open();
      return false;
    }
    holders.unshift({
      inView: function () { return laptopOpen && macInView(); },
      option: function (down, lost) {
        optionKey = down;
        if (down) {
          if (laptopOpen && macInView()) {
            stopTour();
            keysEl.classList.remove('is-inviting');
            // Riffle already open (the tour, the menu bar): ⌥ takes it over, and letting go will switch. Not while
            // searching, where ⌥ types.
            if (!state.open) say(READY_HINT);
            else if (!sw.searching) { state.held = true; say(heldHint()); }
          }
        } else if (state.open && state.held && !latched) {
          state.held = false;
          if (lost) { close(); say(HINT); } else commit();
        } else if (said === READY_HINT) {
          say(HINT);
        }
        paintKeys();
      },
      tab: function (d) { if (grab(tabKey)) { sw.step(d); sw.focus(); } },
      move: function (dir) { if (grab(null)) { sw.move(dir); sw.focus(); } },
      release: function () { if (state.held && state.open && !latched) { state.held = false; commit(); } },
      cancel: function () { if (state.held) { state.held = false; close(); say(HINT); } },
      elsewhere: function (kind) { if (!state.open) say(kind === 'command' ? COMMAND_HINT : TAKEN_HINT); }
    });
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && state.open && !state.touring) {
        e.preventDefault(); state.held = false; latched = false; holding = null; close(); say(HINT);
      }
    });

    // The tab key on screen: with ⌥ held (or the option key left down), a press of Tab.
    tabKey.addEventListener('click', function () {
      keysEl.classList.remove('is-inviting');
      if (!state.open && !held()) { say(NEED_OPTION); nudge(modKey); return; }
      if (held()) state.held = true;
      step();
      flash(tabKey);
      paintKeys();
    });
    // The option key on screen, for a visitor without a keyboard: tapped, it stays down; tapped again, it lets go, and
    // that switches, as letting go of ⌥ does. When Riffle was opened another way (the menu bar, a search), it switches.
    modKey.addEventListener('click', function () {
      keysEl.classList.remove('is-inviting');
      if (latched) {
        latched = false;
        if (state.open && state.held) { state.held = false; commit(); } else say(HINT);
      } else if (state.open && !state.held) {
        commit();
      } else {
        latched = true;
        if (state.open) state.held = true;
        say(state.open ? heldHint() : LATCHED_HINT);
      }
      paintKeys();
    });
    extra.addEventListener('click', function () { if (state.open) close(); else open(); });
    document.querySelector('[data-reset]').addEventListener('click', reset);
    overlay.addEventListener('click', function (e) { if (e.target === overlay) close(); });
    document.addEventListener('click', function (e) {
      if (state.open && !state.touring && !mac.contains(e.target) && !e.target.closest('[data-keys]')) close();
    });

    paint();
    paintKeys();
    if (touch) say(HINT);
  })();

  // ------------------------------------------------------------------ five layouts, side by side
  var CAPTIONS = {
    deck: 'Big cards with a live preview of every window. The default.',
    stage: 'The selected window large, the rest on a filmstrip.',
    icons: 'App icons only, like the Dock. Quick to scan.',
    titles: 'A compact list of titles. It needs no previews at all.',
    list: 'Titles on the left, the selected window large on the right.'
  };
  var demoHost = document.querySelector('[data-layout-demo]');
  var tabs = document.querySelector('[data-tabs]');
  if (demoHost && tabs) (function () {
    var caption = document.querySelector('[data-layout-caption]');
    var sample = plain(WINDOWS.slice(0, 7));
    var demo = new Switcher(demoHost, {
      label: 'Sample windows in the chosen layout',
      onCommit: function (w) { if (w) caption.textContent = 'Let go, and “' + (w.title || w.appName) + '” comes to the front.'; }
    });
    var buttons = Array.prototype.slice.call(tabs.querySelectorAll('[role="tab"]'));
    function pick(button, focus) {
      var layout = button.dataset.layout;
      buttons.forEach(function (b) {
        var on = b === button;
        b.setAttribute('aria-selected', String(on));
        b.tabIndex = on ? 0 : -1;
      });
      chosenLayout = layout;
      demo.render(sample, layout, demo.rows.length ? demo.index : 1);
      caption.textContent = CAPTIONS[layout];
      if (focus) button.focus();
    }
    tabs.addEventListener('click', function (e) { var b = e.target.closest('[role="tab"]'); if (b) pick(b, false); });
    tabs.addEventListener('keydown', function (e) {
      var d = { ArrowRight: 1, ArrowLeft: -1 }[e.key];
      if (!d) return;
      e.preventDefault();
      pick(buttons[(buttons.indexOf(document.activeElement) + d + buttons.length) % buttons.length], true);
    });
    demo.render(sample, 'deck', 1);
  })();

  // ------------------------------------------------------------------ search, with the visitor's own keyboard
  // The switcher's search on a few sample windows, one of them with accents in its title, ranked the way the app ranks.
  // Copies of the windows, so its marks never show up in the other switchers.
  function copy(w) { var c = {}; for (var k in w) c[k] = w[k]; c.matchTitle = c.matchApp = null; return c; }
  function byId(id) { return WINDOWS.filter(function (w) { return w.id === id; })[0]; }
  var findHost = document.querySelector('[data-find]');
  var findChips = document.querySelector('[data-find-chips]');
  if (findHost && findChips) (function () {
    var findSay = document.querySelector('[data-find-say]');
    var pool = ['safari-lisbon', 'xcode-sketchpad', 'notes-weekend', 'mail-inbox', 'terminal-build', 'preview-invoice'].map(function (id) { return copy(byId(id)); });
    pool.push({ id: 'preview-resume', app: 'preview', appName: 'Preview', title: 'Résumé, final.pdf', space: 1 });
    pool.forEach(function (w, i) { w.order = i; });
    var finder = new Switcher(findHost, {
      label: 'Windows found',
      onCommit: function (w) { if (w) findSay.innerHTML = 'Let go, and <strong>' + esc(w.title) + '</strong> comes to the front.'; }
    });
    finder.searching = true;
    finder.total = pool.length;
    function run(q) {
      finder.query = q;
      var list = rank(pool, q.trim()).map(function (r) { r.w.matchTitle = r.title; r.w.matchApp = r.app; return r.w; });
      finder.render(list, 'titles', 0);
      findChips.querySelectorAll('[data-q]').forEach(function (b) { b.setAttribute('aria-pressed', String(b.dataset.q === q.trim().toLowerCase())); });
      findSay.textContent = '';
    }
    run('');
    finder.input.addEventListener('input', function () { run(finder.input.value); });
    findChips.addEventListener('click', function (e) {
      var b = e.target.closest('[data-q]');
      if (!b) return;
      finder.input.value = b.dataset.q;
      run(b.dataset.q);
    });
  })();

  // ------------------------------------------------------------------ your shortcut
  // ⌥ Tab or ⌘ Tab: the big key turns over to the one picked, in one half turn that never runs backwards. It speeds up
  // until it's edge on, where nothing of it shows and its legend changes, and comes down the other side to settle. A pick
  // made while it turns is taken at the edge, or by one more turn once it has landed.
  var yours = document.querySelector('[data-yours]');
  var bigKey = document.querySelector('[data-bigkey]');
  if (yours && bigKey) (function () {
    var buttons = Array.prototype.slice.call(yours.querySelectorAll('[role="radio"]'));
    var symbol = bigKey.querySelector('[data-bigkey-symbol]'), name = bigKey.querySelector('[data-bigkey-name]');
    var wanted = 'option', shown = 'option', turning = false;
    function show(mod) {
      shown = mod;
      symbol.textContent = mod === 'command' ? '⌘' : '⌥';
      name.textContent = mod;
    }
    function turnOver() {
      turning = true;
      bigKey.animate([{ transform: 'perspective(560px) rotateX(0deg)' }, { transform: 'perspective(560px) rotateX(90deg)' }],
        { duration: 200, easing: 'cubic-bezier(0.55, 0, 1, 0.45)' }).onfinish = function () {
        show(wanted);
        bigKey.animate([{ transform: 'perspective(560px) rotateX(-90deg)' }, { transform: 'perspective(560px) rotateX(0deg)' }],
          { duration: 460, easing: 'cubic-bezier(0.25, 1.35, 0.45, 1)' }).onfinish = function () {
          turning = false;
          if (shown !== wanted) turnOver();
        };
      };
    }
    function pick(button, focus) {
      if (focus) button.focus();
      if (button.getAttribute('aria-checked') === 'true') return;
      buttons.forEach(function (b) {
        var on = b === button;
        b.setAttribute('aria-checked', String(on));
        b.tabIndex = on ? 0 : -1;
      });
      wanted = button.dataset.mod;
      if (reduce || !bigKey.animate) { show(wanted); return; }
      if (!turning) turnOver();
    }
    yours.addEventListener('click', function (e) { var b = e.target.closest('[role="radio"]'); if (b) pick(b, false); });
    yours.addEventListener('keydown', function (e) {
      var d = { ArrowRight: 1, ArrowLeft: -1, ArrowDown: 1, ArrowUp: -1 }[e.key];
      if (!d) return;
      e.preventDefault();
      pick(buttons[(buttons.indexOf(document.activeElement) + d + buttons.length) % buttons.length], true);
    });
  })();
})();
