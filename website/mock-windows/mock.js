// Mock windows: picks the variant from ?v=<name> and adds the shared glyph sprite.
// A page lists its variants on <html data-variants="a b c"> (the first one is the default) and marks the parts that
// belong to some variants only with data-v="a" (or several names: data-v="a b"). The other variants' parts are removed,
// not hidden, so sibling selectors and SVG ids only ever see one window. <meta name="window-title" data-v="a"> names
// the window. Loaded with `defer`, so it runs before the page's load event (and before headless Chrome's screenshot).
(function () {
  var root = document.documentElement;
  var names = (root.getAttribute('data-variants') || '').split(/\s+/).filter(Boolean);
  var asked = new URLSearchParams(location.search).get('v');
  var variant = names.indexOf(asked) >= 0 ? asked : names[0];
  if (variant) {
    root.setAttribute('data-v', variant);
    document.querySelectorAll('[data-v]').forEach(function (el) {
      if (el !== root && el.getAttribute('data-v').split(/\s+/).indexOf(variant) < 0) el.remove();
    });
  }
  var title = document.querySelector('meta[name="window-title"]');
  if (title) document.title = title.content;

  // 16×16 line glyphs in the spirit of SF Symbols. Use: <svg class="g"><use href="#g-name"/></svg>
  var glyphs = {
    'chev-l': '<path d="M10 3.5 5.5 8l4.5 4.5"/>',
    'chev-r': '<path d="M6 3.5 10.5 8 6 12.5"/>',
    'chev-d': '<path d="m4.5 6.25 3.5 3.5 3.5-3.5"/>',
    'chev-ud': '<path d="m5 6 3-3 3 3M5 10l3 3 3-3"/>',
    'sidebar': '<rect x="1.75" y="2.75" width="12.5" height="10.5" rx="2.5"/><path d="M6.25 2.75v10.5"/>',
    'inspector': '<rect x="1.75" y="2.75" width="12.5" height="10.5" rx="2.5"/><path d="M9.75 2.75v10.5"/>',
    'share': '<path d="M8 1.75v8M5.25 4.5 8 1.75l2.75 2.75M5.25 6.75H4.5A1.5 1.5 0 0 0 3 8.25v4.25A1.5 1.5 0 0 0 4.5 14h7a1.5 1.5 0 0 0 1.5-1.5V8.25a1.5 1.5 0 0 0-1.5-1.5h-.75"/>',
    'plus': '<path d="M8 3v10M3 8h10"/>',
    'minus': '<path d="M3 8h10"/>',
    'search': '<circle cx="7" cy="7" r="4.5"/><path d="m10.4 10.4 3.6 3.6"/>',
    'zoom-in': '<circle cx="7" cy="7" r="4.75"/><path d="m10.5 10.5 3.5 3.5M7 4.75v4.5M4.75 7h4.5"/>',
    'zoom-out': '<circle cx="7" cy="7" r="4.75"/><path d="m10.5 10.5 3.5 3.5M4.75 7h4.5"/>',
    'grid4': '<rect x="2" y="2" width="5" height="5" rx="1.3"/><rect x="9" y="2" width="5" height="5" rx="1.3"/><rect x="2" y="9" width="5" height="5" rx="1.3"/><rect x="9" y="9" width="5" height="5" rx="1.3"/>',
    'list': '<path d="M5.5 4h8.5M5.5 8h8.5M5.5 12h8.5"/><circle cx="2.5" cy="4" r=".6"/><circle cx="2.5" cy="8" r=".6"/><circle cx="2.5" cy="12" r=".6"/>',
    'reload': '<path d="M13 8a5 5 0 1 1-1.5-3.6"/><path d="M12 1.75v3h-3"/>',
    'page': '<rect x="2" y="2.75" width="12" height="10.5" rx="2"/><path d="M5 6.5h6M5 9.5h4"/>',
    'compose': '<path d="M13.25 9v3.5a1.5 1.5 0 0 1-1.5 1.5h-8.25A1.5 1.5 0 0 1 2 12.5V4.25a1.5 1.5 0 0 1 1.5-1.5H7"/><path d="m11.5 1.75 2.75 2.75L8.5 10.25 5.5 11l.75-3z"/>',
    'trash': '<path d="M2.5 4.25h11M6 4.25V2.5h4v1.75M3.75 4.25l.7 9a1.25 1.25 0 0 0 1.25 1.15h4.6a1.25 1.25 0 0 0 1.25-1.15l.7-9"/>',
    'archive': '<rect x="1.75" y="2.5" width="12.5" height="3.5" rx="1"/><path d="M2.75 6v6.25a1.25 1.25 0 0 0 1.25 1.25h8a1.25 1.25 0 0 0 1.25-1.25V6M6.5 8.75h3"/>',
    'reply': '<path d="M6.5 3.25 2.5 7.25l4 4M2.5 7.25h6.25a4.75 4.75 0 0 1 4.75 4.75v1"/>',
    'reply-all': '<path d="M5 3.25 1 7.25l4 4M8.5 3.25l-4 4 4 4M4.5 7.25h4.75a4.75 4.75 0 0 1 4.75 4.75v1"/>',
    'forward': '<path d="m9.5 3.25 4 4-4 4M13.5 7.25H7.25A4.75 4.75 0 0 0 2.5 12v1"/>',
    'flag': '<path d="M3.5 14.25V2.25M3.5 2.75h8.75l-2.25 3.5 2.25 3.5H3.5"/>',
    'junk': '<rect x="1.75" y="3.25" width="12.5" height="9.5" rx="1.75"/><path d="m5.5 6 5 4M10.5 6l-5 4"/>',
    'envelope': '<rect x="1.75" y="3.25" width="12.5" height="9.5" rx="1.75"/><path d="m2.25 4.25 5.75 4.5 5.75-4.5"/>',
    'tray': '<path d="M1.75 9.25 3.4 3.6a1.1 1.1 0 0 1 1.05-.85h7.1a1.1 1.1 0 0 1 1.05.85l1.65 5.65V12.5a1.25 1.25 0 0 1-1.25 1.25H3a1.25 1.25 0 0 1-1.25-1.25z"/><path d="M1.75 9.25h3.5l.9 1.5h3.7l.9-1.5h3.5"/>',
    'sent': '<path d="M14.25 1.75 1.75 7.1l4.9 2.25 2.25 4.9z"/><path d="m6.65 9.35 3.6-3.6"/>',
    'doc': '<path d="M4 1.75h5.25l3.25 3.25v8.25a1 1 0 0 1-1 1h-7.5a1 1 0 0 1-1-1V2.75a1 1 0 0 1 1-1z"/><path d="M9.25 1.75V5h3.25"/>',
    'folder': '<path d="M1.75 4.25a1.25 1.25 0 0 1 1.25-1.25h3.2l1.5 1.5H13a1.25 1.25 0 0 1 1.25 1.25v6.5A1.25 1.25 0 0 1 13 13.5H3a1.25 1.25 0 0 1-1.25-1.25z"/><path d="M1.75 6.5h12.5"/>',
    'clock': '<circle cx="8" cy="8" r="6.25"/><path d="M8 4.5V8l2.5 1.6"/>',
    'airdrop': '<circle cx="8" cy="9.75" r="1.1" fill="currentColor"/><path d="M5.3 12.45a3.8 3.8 0 1 1 5.4 0M3.4 14.3a6.4 6.4 0 1 1 9.2 0"/>',
    'apps': '<path d="M8 2.25 3.25 13.75M8 2.25l4.75 11.5M4.9 9.75h6.2"/>',
    'desktop': '<rect x="1.75" y="2.25" width="12.5" height="8.75" rx="1.5"/><path d="M5.75 14h4.5M8 11v3"/>',
    'download': '<circle cx="8" cy="8" r="6.25"/><path d="M8 4.75v6M5.5 8.6 8 11l2.5-2.4"/>',
    'cloud': '<path d="M4.6 12.75h7.1a2.8 2.8 0 0 0 .35-5.58A4.1 4.1 0 0 0 4.2 6.2a3.3 3.3 0 0 0 .4 6.55z"/>',
    'shared': '<path d="M1.75 4.25a1.25 1.25 0 0 1 1.25-1.25h3.2l1.5 1.5H13a1.25 1.25 0 0 1 1.25 1.25v6.5A1.25 1.25 0 0 1 13 13.5H3a1.25 1.25 0 0 1-1.25-1.25z"/><circle cx="8" cy="8" r="1.4"/><path d="M5.5 12.5a2.6 2.6 0 0 1 5 0"/>',
    'tag': '<path d="M1.75 8.25V2.75a1 1 0 0 1 1-1h5.5l6 6-6.5 6.5z"/><circle cx="5" cy="5" r="1"/>',
    'more': '<circle cx="3.5" cy="8" r="1.15" fill="currentColor" stroke="none"/><circle cx="8" cy="8" r="1.15" fill="currentColor" stroke="none"/><circle cx="12.5" cy="8" r="1.15" fill="currentColor" stroke="none"/>',
    'more-c': '<circle cx="8" cy="8" r="6.25"/><circle cx="5.2" cy="8" r=".8" fill="currentColor" stroke="none"/><circle cx="8" cy="8" r=".8" fill="currentColor" stroke="none"/><circle cx="10.8" cy="8" r=".8" fill="currentColor" stroke="none"/>',
    'group': '<rect x="1.75" y="2.25" width="12.5" height="4.5" rx="1.25"/><rect x="1.75" y="9.25" width="12.5" height="4.5" rx="1.25"/>',
    'house': '<path d="M2.25 7.4 8 2.5l5.75 4.9v5.85a1 1 0 0 1-1 1H10V10.5H6v3.75H3.25a1 1 0 0 1-1-1z"/>',
    'radio': '<circle cx="8" cy="8" r="1.5"/><path d="M5.2 5.2a4 4 0 0 0 0 5.6M10.8 5.2a4 4 0 0 1 0 5.6M3.2 3.2a6.8 6.8 0 0 0 0 9.6M12.8 3.2a6.8 6.8 0 0 1 0 9.6"/>',
    'albums': '<rect x="1.75" y="4.25" width="10" height="10" rx="1.5"/><circle cx="6.75" cy="9.25" r="1.6"/><path d="M4.5 1.75h8.25a1.5 1.5 0 0 1 1.5 1.5v8.25"/>',
    'mic': '<rect x="5.75" y="1.75" width="4.5" height="7.75" rx="2.25"/><path d="M3.5 7.75a4.5 4.5 0 0 0 9 0M8 12.25v2"/>',
    'note': '<path d="M6 12.25V3.4l7.25-1.65v8.85"/><circle cx="4.25" cy="12.25" r="1.85"/><circle cx="11.4" cy="10.6" r="1.85"/>',
    'playlist': '<path d="M2 3.75h8.5M2 7.25h8.5M2 10.75h5"/><path d="M12.25 13.75V6.5l2.25-.6"/><circle cx="10.9" cy="13.6" r="1.4"/>',
    'recent': '<rect x="1.75" y="1.75" width="12.5" height="12.5" rx="2.5"/><path d="M8 4.75V8l2.25 1.5"/>',
    'shuffle': '<path d="M1.75 4.5h2.5c3.5 0 4 7 7.5 7h2.5M1.75 11.5h2.5c1.5 0 2.4-1.3 3.1-2.8M9.4 6.2c.7-1 1.4-1.7 2.35-1.7h2.5M12.25 2.75l2 1.75-2 1.75M12.25 9.75l2 1.75-2 1.75"/>',
    'repeat': '<path d="M2.25 8.5V7a2.5 2.5 0 0 1 2.5-2.5h9M11.75 2.5l2 2-2 2M13.75 7.5V9a2.5 2.5 0 0 1-2.5 2.5h-9M4.25 13.5l-2-2 2-2"/>',
    'prev': '<path d="M7.6 4.2v7.6L2.4 8z M13.6 4.2v7.6L8.4 8z" fill="currentColor" stroke="none"/>',
    'next': '<path d="M8.4 4.2v7.6L13.6 8z M2.4 4.2v7.6L7.6 8z" fill="currentColor" stroke="none"/>',
    'pause': '<rect x="3.75" y="2.75" width="3" height="10.5" rx="1" fill="currentColor" stroke="none"/><rect x="9.25" y="2.75" width="3" height="10.5" rx="1" fill="currentColor" stroke="none"/>',
    'play': '<path d="M4.5 2.75v10.5L13.25 8z" fill="currentColor" stroke="none"/>',
    'stop': '<rect x="3.5" y="3.5" width="9" height="9" rx="1.5" fill="currentColor" stroke="none"/>',
    'volume': '<path d="M2 6.25h2.25L7.5 3.5v9L4.25 9.75H2z" fill="currentColor" stroke="none"/><path d="M10 5.5a3.5 3.5 0 0 1 0 5M12 3.75a6 6 0 0 1 0 8.5"/>',
    'lyrics': '<path d="M2.25 3.75a1.5 1.5 0 0 1 1.5-1.5h8.5a1.5 1.5 0 0 1 1.5 1.5v6a1.5 1.5 0 0 1-1.5 1.5H7l-3 2.5v-2.5h-.25a1.5 1.5 0 0 1-1.5-1.5z"/><path d="M6 6.5h.01M10 6.5h.01" stroke-width="2"/>',
    'queue': '<path d="M2 3.75h12M2 7.5h12M2 11.25h7.5"/><path d="M11.75 10v3.5l2.5-1.75z" fill="currentColor" stroke="none"/>',
    'checklist': '<circle cx="3.75" cy="4.5" r="1.9"/><circle cx="3.75" cy="11.5" r="1.9"/><path d="M7.75 4.5h6.5M7.75 11.5h6.5"/>',
    'table': '<rect x="1.75" y="2.75" width="12.5" height="10.5" rx="1.75"/><path d="M1.75 6.4h12.5M1.75 9.9h12.5M6.25 2.75v10.5"/>',
    'photo': '<rect x="1.75" y="2.75" width="12.5" height="10.5" rx="1.75"/><circle cx="5.5" cy="6.25" r="1.25"/><path d="m2.25 12.25 3.9-3.9 3 3 1.6-1.6 3.25 3.25"/>',
    'lock': '<rect x="3" y="7" width="10" height="7" rx="1.75"/><path d="M5.25 7V5a2.75 2.75 0 0 1 5.5 0v2"/>',
    'markup': '<circle cx="8" cy="8" r="6.25"/><path d="M5.6 10.4 6 8.6l3.9-3.9 1.4 1.4-3.9 3.9z"/>',
    'hammer': '<path d="m9.5 6.5-6.75 6.75a1.06 1.06 0 0 0 1.5 1.5L11 8"/><path d="m7.5 4.5 3-2.75 4 4L11.75 8.5l-1.5-1.5L9.5 7.75 7.75 6l.75-.75z"/>',
    'warn': '<path d="M8 2.25 14.25 13.5H1.75z"/><path d="M8 6.5v3.25M8 11.75h.01"/>',
    'checkmark': '<path d="m3.5 8.5 3 3 6-7"/>',
    'branch': '<circle cx="4.5" cy="3.5" r="1.6"/><circle cx="4.5" cy="12.5" r="1.6"/><circle cx="11.5" cy="5" r="1.6"/><path d="M4.5 5.1v5.8M11.5 6.6c0 3-7 2.2-7 4.3"/>',
    'diamond': '<path d="M8 1.75 14.25 8 8 14.25 1.75 8z"/>',
    'bubble': '<path d="M2.25 4a1.75 1.75 0 0 1 1.75-1.75h8A1.75 1.75 0 0 1 13.75 4v5.5A1.75 1.75 0 0 1 12 11.25H6.5l-3 2.5v-2.5H4A1.75 1.75 0 0 1 2.25 9.5z"/>',
    'test': '<path d="M8 1.75 14.25 8 8 14.25 1.75 8z"/><path d="m5.4 8 1.8 1.8L10.6 6.4"/>',
    'breakpoint': '<path d="M2.25 3.25h8.5l3.25 4.75-3.25 4.75h-8.5z"/>',
    'report': '<path d="M3.25 2.25h9.5v11.5h-9.5z"/><path d="M5.5 5.25h5M5.5 8h5M5.5 10.75h3"/>',
    'symbols': '<rect x="1.75" y="1.75" width="12.5" height="12.5" rx="2.5"/><path d="M5 5.25h6M5 8h6M5 10.75h3.5"/>',
    'aa': '<path d="M1.75 12.5 5.25 3.5l3.5 9M3 9.5h4.5M10.5 8.25a2 2 0 0 1 3.5 1.1v3.15M14 10.4h-2.1a1.15 1.15 0 0 0 0 2.3 2.1 2.1 0 0 0 2.1-2.1"/>',
    'clip': '<path d="m13 7.25-5.4 5.4a3.2 3.2 0 0 1-4.5-4.5l5.6-5.6a2.1 2.1 0 0 1 3 3L6.1 11.1a1 1 0 0 1-1.45-1.45l5.1-5.1"/>',
    'filter': '<circle cx="8" cy="8" r="6.25"/><path d="M5 6.25h6M6.1 8.25h3.8M7.1 10.25h1.8"/>',
    'pin': '<path d="M8 14.5s4.75-4.5 4.75-8.25a4.75 4.75 0 0 0-9.5 0C3.25 10 8 14.5 8 14.5z"/><circle cx="8" cy="6.25" r="1.6"/>',
    'arrow-l': '<path d="M13.5 8h-11M6.75 3.75 2.5 8l4.25 4.25"/>',
    'arrow-r': '<path d="M2.5 8h11M9.25 3.75 13.5 8l-4.25 4.25"/>',
    'star': '<path d="m8 1.9 1.85 3.78 4.15.6-3 2.93.7 4.14L8 11.4l-3.7 1.95.7-4.14-3-2.93 4.15-.6z"/>',
    'puzzle': '<path d="M2.75 5.25h2.6a1.65 1.65 0 1 1 3.3 0h2.6v2.6a1.65 1.65 0 1 1 0 3.3v2.6H2.75z"/>',
    'kebab': '<circle cx="8" cy="3.5" r="1.15" fill="currentColor" stroke="none"/><circle cx="8" cy="8" r="1.15" fill="currentColor" stroke="none"/><circle cx="8" cy="12.5" r="1.15" fill="currentColor" stroke="none"/>',
    'tune': '<path d="M2.25 5h6.25M11.75 5h2M2.25 11h2M7.5 11h6.25"/><circle cx="10.1" cy="5" r="1.6"/><circle cx="5.9" cy="11" r="1.6"/>',
    'close': '<path d="m4.5 4.5 7 7M11.5 4.5l-7 7"/>',
    'swap': '<path d="M2.5 5.25h10.5M10.5 2.75 13 5.25l-2.5 2.5M13.5 10.75H3M5.5 8.25 3 10.75l2.5 2.5"/>',
    'calendar': '<rect x="2" y="3" width="12" height="11" rx="2"/><path d="M2 6.75h12M5.25 1.75v2.5M10.75 1.75v2.5"/>',
    'person': '<circle cx="8" cy="5.25" r="2.75"/><path d="M2.75 14a5.25 5.25 0 0 1 10.5 0"/>',
    'plane': '<path d="M14.6 8c0-.62-.5-1.1-1.12-1.1H10.1L6.75 1.75H5.2l1.65 5.15H3.7L2.45 5.3h-.95L2.25 8l-.75 2.7h.95L3.7 9.1h3.15L5.2 14.25h1.55L10.1 9.1h3.38c.62 0 1.12-.48 1.12-1.1z" fill="currentColor" stroke="none"/>',
    'heart': '<path d="M8 13.3C5 11.25 2 8.95 2 5.95 2 4.25 3.3 2.95 4.95 2.95c1.25 0 2.4.75 3.05 1.9.65-1.15 1.8-1.9 3.05-1.9 1.65 0 2.95 1.3 2.95 3 0 3-3 5.3-6 7.35z"/>',
    'bell': '<path d="M4 11.5V7.25a4 4 0 0 1 8 0v4.25l1.25 1.25H2.75zM6.5 14.25h3"/>',
    'info': '<circle cx="8" cy="8" r="6.25"/><path d="M8 7.25v4M8 4.9h.01" stroke-width="1.7"/>',
    'tray-down': '<path d="M2 9.75v2.5a1.5 1.5 0 0 0 1.5 1.5h9a1.5 1.5 0 0 0 1.5-1.5v-2.5M8 2v8M5 7l3 3 3-3"/>'
  };

  var symbols = '';
  for (var name in glyphs) {
    symbols += '<symbol id="g-' + name + '" viewBox="0 0 16 16">' + glyphs[name] + '</symbol>';
  }
  document.body.insertAdjacentHTML('afterbegin',
    '<svg width="0" height="0" style="position:absolute" aria-hidden="true">' + symbols + '</svg>');
})();
