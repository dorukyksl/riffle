// Riffle's site. www goes to the bare domain. With INVITE_SHA256 empty (wrangler.jsonc) the site is public; with the
// SHA-256 of an invite code in it (several, comma-separated, for more than one link), it's shared by invitation:
// every page, picture and the download need the invite, the link https://appriffle.com/?invite=<code> opens the site
// and leaves a cookie for 90 days, a visitor without it gets one small page saying so, and nothing is indexed.
// Change the hash and every link and cookie made with the old code stops working.

const COOKIE = 'riffle_invite';
const MAX_AGE = 90 * 24 * 60 * 60;
// What that small page and a link preview need before there's a cookie: the icons, the preview picture, the fonts.
// And under /updates/, the update feed and the image it lists: installed copies of Riffle check them with no cookie.
const OPEN_FOLDER = '/updates/';
const OPEN = new Set([
  '/img/icon-64.png',
  '/img/icon-256.png',
  '/img/social.jpg',
  '/fonts/bricolage-latin.woff2',
  '/fonts/geist-latin.woff2'
]);

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.hostname.startsWith('www.')) {
      url.hostname = url.hostname.slice(4);
      return Response.redirect(url.toString(), 301);
    }
    const gated = String(env.INVITE_SHA256 || '').trim() !== '';
    if (url.pathname === '/robots.txt') {
      return new Response(gated ? 'User-agent: *\nDisallow: /\n' : 'User-agent: *\nAllow: /\n',
        { headers: { 'Content-Type': 'text/plain; charset=utf-8' } });
    }
    if (!gated || OPEN.has(url.pathname) || url.pathname.startsWith(OPEN_FOLDER)) return env.ASSETS.fetch(request);

    const offered = url.searchParams.get('invite');
    const kept = readCookie(request.headers.get('Cookie'));
    let code = null;
    if (offered && await isInvite(offered, env)) code = offered;
    else if (kept && await isInvite(kept, env)) code = kept;
    if (!code) return invitationOnly();

    const asset = await env.ASSETS.fetch(request);
    let response = new Response(asset.body, asset);
    response.headers.set('X-Robots-Tag', 'noindex, nofollow');
    response.headers.set('Cache-Control', 'private, no-cache');
    if (code !== kept) {
      response.headers.append('Set-Cookie', `${COOKIE}=${encodeURIComponent(code)}; Max-Age=${MAX_AGE}; Path=/; Secure; HttpOnly; SameSite=Lax`);
    }
    // The page answers the link with a 200 rather than a redirect, so link previews work; then the code leaves the
    // address bar, since the cookie carries it from here on.
    if (offered && (response.headers.get('Content-Type') || '').startsWith('text/html')) {
      response = new HTMLRewriter().on('head', {
        element(head) {
          head.append('<script>history.replaceState(null, "", location.pathname + location.hash)</script>', { html: true });
        }
      }).transform(response);
    }
    return response;
  }
};

function readCookie(header) {
  if (!header) return null;
  for (const part of header.split(';')) {
    const [name, ...value] = part.trim().split('=');
    if (name === COOKIE) {
      try { return decodeURIComponent(value.join('=')); } catch { return null; }
    }
  }
  return null;
}

async function isInvite(code, env) {
  if (code.length > 64) return false;
  const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(code)));
  for (const hex of String(env.INVITE_SHA256 || '').split(',')) {
    const wanted = fromHex(hex.trim());
    if (wanted && wanted.length === digest.length && crypto.subtle.timingSafeEqual(wanted, digest)) return true;
  }
  return false;
}

function fromHex(hex) {
  if (!/^[0-9a-f]{64}$/i.test(hex)) return null;
  return new Uint8Array(hex.match(/../g).map(byte => parseInt(byte, 16)));
}

function invitationOnly() {
  return new Response(PAGE, {
    status: 403,
    headers: {
      'Content-Type': 'text/html; charset=utf-8',
      'Cache-Control': 'no-store',
      'X-Robots-Tag': 'noindex, nofollow'
    }
  });
}

const PAGE = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>Riffle</title>
<link rel="icon" href="/img/icon-64.png" type="image/png">
<style>
  @font-face { font-family: "Bricolage Grotesque"; src: url("/fonts/bricolage-latin.woff2") format("woff2"); font-weight: 200 800; font-display: swap; }
  @font-face { font-family: "Geist"; src: url("/fonts/geist-latin.woff2") format("woff2"); font-weight: 100 900; font-display: swap; }
  :root { color-scheme: light; }
  * { box-sizing: border-box; margin: 0; }
  body {
    min-height: 100vh; min-height: 100svh; display: grid; place-items: center; padding: 32px 20px; text-align: center;
    color: #2a1238; font: 400 1.06rem/1.55 "Geist", system-ui, sans-serif;
    background: radial-gradient(90% 70% at 10% 0%, #ffe1d2, transparent 70%), radial-gradient(90% 80% at 100% 100%, #ecdcf7, transparent 70%), #fbebf0;
  }
  main { display: grid; justify-items: center; gap: 18px; max-width: 34rem; }
  img { width: 112px; height: 112px; margin-bottom: 6px; filter: drop-shadow(0 16px 22px rgb(60 20 80 / 0.28)); }
  h1 { font: 800 clamp(2rem, 1.4rem + 2.6vw, 2.9rem)/1.04 "Bricolage Grotesque", system-ui, sans-serif; letter-spacing: -0.035em; text-wrap: balance; }
  p { max-width: 30rem; color: #6b5677; text-wrap: pretty; }
</style>
</head>
<body>
<main>
  <img src="/img/icon-256.png" alt="" width="112" height="112">
  <h1>Riffle is invite-only for now.</h1>
  <p>A few friends are trying it first. If someone sent you a link, open that link to come in.</p>
</main>
</body>
</html>
`;
