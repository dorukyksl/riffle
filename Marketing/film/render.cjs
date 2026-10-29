#!/usr/bin/env node
/* Draws the film (index.html + film.js) frame by frame in headless Chrome and encodes it.

     node Marketing/film/render.cjs --stills 2.5,8,15      → PNG stills at those seconds, to check a frame quickly
     node Marketing/film/render.cjs                        → the whole film, 1080p60: master and web versions + poster

   Frames are photographed at twice the size and scaled down, so edges and text come out smooth. Several pages draw
   different stretches of the film at once; each stretch is encoded on the fly and the stretches are joined. Nothing
   big is written into the project (an iCloud folder): work files go to ~/Library/Caches/Riffle/film.

   Needs Google Chrome, ffmpeg, and playwright-core in ~/Library/Caches/Riffle/film-tools
   (npm install playwright-core there), or PLAYWRIGHT_CORE pointing at it. */
'use strict';
const fs = require('fs');
const path = require('path');
const http = require('http');
const os = require('os');
const { spawn, execFileSync } = require('child_process');

const PW = process.env.PLAYWRIGHT_CORE || path.join(os.homedir(), 'Library/Caches/Riffle/film-tools/node_modules/playwright-core');
const { chromium } = require(PW);

const ROOT = path.resolve(__dirname, '../..');
const WORK = path.join(os.homedir(), 'Library/Caches/Riffle/film');
const OUT = path.join(__dirname, 'out');
const FPS = 60;
const SCALE = 2;
// BT.709 tags, in the stream itself too (x264's VUI), or players are left to guess.
const COLOR = ['-colorspace', 'bt709', '-color_primaries', 'bt709', '-color_trc', 'bt709', '-color_range', 'tv'];
const VUI = 'colorprim=bt709:transfer=bt709:colormatrix=bt709:range=tv';

const args = process.argv.slice(2);
function arg(name, fallback) { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : fallback; }

// The project over http, so the fonts load (Chrome won't take them from file://).
const TYPES = { '.html': 'text/html', '.css': 'text/css', '.js': 'text/javascript', '.webp': 'image/webp', '.png': 'image/png',
  '.jpg': 'image/jpeg', '.svg': 'image/svg+xml', '.woff2': 'font/woff2', '.json': 'application/json' };
function serve() {
  const server = http.createServer((req, res) => {
    const file = path.join(ROOT, decodeURIComponent(new URL(req.url, 'http://x').pathname));
    if (!file.startsWith(ROOT)) { res.writeHead(403); res.end(); return; }
    fs.readFile(file, (err, data) => {
      if (err) { res.writeHead(404); res.end(); return; }
      res.writeHead(200, { 'Content-Type': TYPES[path.extname(file)] || 'application/octet-stream' });
      res.end(data);
    });
  });
  return new Promise(done => server.listen(0, '127.0.0.1', () => done(server)));
}

async function openPage(browser, url) {
  const page = await browser.newPage({ viewport: { width: 1920, height: 1080 }, deviceScaleFactor: SCALE });
  const problems = [];
  page.on('pageerror', e => problems.push(e.message));
  page.on('console', m => { if (m.type() === 'error' && !/status of 404/.test(m.text())) problems.push(m.text()); });
  page.on('response', r => { if (r.status() >= 400 && !r.url().endsWith('/favicon.ico')) problems.push(r.status() + ' ' + r.url()); });
  await page.goto(url, { waitUntil: 'load' });
  await page.evaluate(() => window.film.ready);
  if (problems.length) throw new Error('the film page reported:\n  ' + problems.join('\n  '));
  return page;
}

async function frameAt(page, t, type) {
  await page.evaluate(t => window.film.render(t), t);
  return page.screenshot({ type, quality: type === 'jpeg' ? 100 : undefined, animations: 'disabled', caret: 'initial' });
}

function ffmpeg(argv) {
  const child = spawn('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', ...argv], { stdio: ['pipe', 'inherit', 'inherit'] });
  child.done = new Promise((ok, fail) => child.on('close', code => code === 0 ? ok() : fail(new Error('ffmpeg exited ' + code))));
  return child;
}

async function main() {
  fs.mkdirSync(WORK, { recursive: true });
  fs.mkdirSync(OUT, { recursive: true });
  const server = await serve();
  const url = `http://127.0.0.1:${server.address().port}/Marketing/film/index.html`;
  const browser = await chromium.launch({ channel: 'chrome', headless: true,
    args: ['--force-color-profile=srgb', '--hide-scrollbars', '--disable-lcd-text'] });
  try {
    const stills = arg('--stills');
    if (stills) {
      const page = await openPage(browser, url);
      const dir = arg('--dir', path.join(WORK, 'stills'));
      fs.mkdirSync(dir, { recursive: true });
      for (const s of stills.split(',').map(Number)) {
        const file = path.join(dir, `still-${s.toFixed(2)}.png`);
        fs.writeFileSync(file, await frameAt(page, s, 'png'));
        console.log(file);
      }
      return;
    }

    const probe = await openPage(browser, url);
    const duration = Number(arg('--duration', await probe.evaluate(() => window.film.duration)));
    await probe.close();
    const total = Math.round(duration * FPS);
    const workers = Number(arg('--workers', Math.max(2, Math.min(6, os.cpus().length - 2))));
    const per = Math.ceil(total / workers);
    const started = Date.now();
    let drawn = 0;
    const segments = [];
    await Promise.all(Array.from({ length: workers }, async (_, w) => {
      const from = w * per, to = Math.min(total, from + per);
      if (from >= to) return;
      const file = path.join(WORK, `segment-${String(w).padStart(2, '0')}.mp4`);
      segments[w] = file;
      const page = await openPage(browser, url);
      // Each stretch: JPEG frames at full quality in (PNG at this size is ten times slower), scaled to 1080p and turned
      // from JPEG's colour (BT.601, full range) into video colour (BT.709, limited range, the way players expect it),
      // encoded near-losslessly.
      const enc = ffmpeg(['-f', 'image2pipe', '-framerate', String(FPS), '-c:v', 'mjpeg', '-i', '-',
        '-vf', 'scale=1920:1080:flags=lanczos+accurate_rnd+full_chroma_int:in_color_matrix=bt601:in_range=pc:out_color_matrix=bt709:out_range=tv,format=yuv420p',
        ...COLOR, '-c:v', 'libx264', '-preset', 'medium', '-crf', '10', '-x264-params', 'keyint=60:min-keyint=60:' + VUI, file]);
      for (let f = from; f < to; f++) {
        const buffer = await frameAt(page, f / FPS, 'jpeg');
        if (!enc.stdin.write(buffer)) await new Promise(ok => enc.stdin.once('drain', ok));
        drawn++;
        if (drawn % 120 === 0) {
          const rate = drawn / ((Date.now() - started) / 1000);
          console.log(`${drawn}/${total} frames, ${rate.toFixed(1)}/s, ~${Math.round((total - drawn) / rate)}s left`);
        }
      }
      enc.stdin.end();
      await enc.done;
      await page.close();
    }));

    // Join the stretches, then make the two versions: a master to keep, and one small enough for the website.
    const list = path.join(WORK, 'segments.txt');
    fs.writeFileSync(list, segments.filter(Boolean).map(f => `file '${f}'`).join('\n'));
    const master = path.join(OUT, 'riffle-demo-master.mp4');
    await ffmpeg(['-f', 'concat', '-safe', '0', '-i', list, '-c', 'copy', '-movflags', '+faststart', master]).done;
    const web = path.join(OUT, 'riffle-demo.mp4');
    const crf = arg('--crf', '20');
    // A faint, still grain over the dark gradients keeps them from breaking into bands at this bitrate.
    await ffmpeg(['-i', master, '-vf', 'noise=c0s=2:c0f=u', '-c:v', 'libx264', '-preset', 'slow', '-crf', crf, '-profile:v', 'high',
      '-level', '4.2', '-pix_fmt', 'yuv420p', '-x264-params', 'aq-mode=3:aq-strength=1.0:' + VUI, ...COLOR, '-movflags', '+faststart',
      '-an', web]).done;
    const poster = path.join(OUT, 'riffle-demo-poster.jpg');
    await ffmpeg(['-ss', arg('--poster', '3.0'), '-i', master, '-frames:v', '1', '-q:v', '2', poster]).done;
    for (const f of [master, web, poster]) console.log(`${f}: ${(fs.statSync(f).size / 1048576).toFixed(1)} MB`);
    console.log(`drawn in ${Math.round((Date.now() - started) / 1000)}s`);
  } finally {
    await browser.close();
    server.close();
  }
}

main().catch(e => { console.error(e.stack || e.message); process.exit(1); });
