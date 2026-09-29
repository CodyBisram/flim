// Renders reel.html to an Instagram Reel MP4 (1080x1920, 30 fps, H.264, yuv420p).
//
//   node social/promo/spotlight-reel/render.mjs [--fps 30] [--out spotlight-reel.mp4] [--from 0 --to 20]
//
// The page draws every frame from a clock it is handed (window.reel.seek(t)), so the output is
// frame-exact and does not depend on how fast this machine is. Needs Playwright's Chromium and
// ffmpeg (FFMPEG env var, else `ffmpeg` on PATH, else the imageio-ffmpeg binary).
import { spawn, execSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';
import fs from 'node:fs';

// Playwright from this folder's node_modules if installed there, else the global install.
let chromium;
try { ({ chromium } = await import('playwright')); } catch {
  const globalRoot = execSync('npm root -g').toString().trim();
  ({ chromium } = createRequire(path.join(globalRoot, 'noop.js'))('playwright'));
}

const here = path.dirname(fileURLToPath(import.meta.url));
const arg = (name, fallback) => {
  const i = process.argv.indexOf(`--${name}`);
  return i > -1 ? process.argv[i + 1] : fallback;
};
const fps = Number(arg('fps', 30));
const out = path.resolve(arg('out', path.join(here, 'spotlight-reel.mp4')));
const stills = arg('stills', null); // comma-separated seconds: write PNGs instead of a video
// Frames are drawn at this multiple of 1080x1920 and scaled down with Lanczos: supersampling,
// so type, hairlines and photographs come out sharper than a 1x capture.
const scale = Number(arg('scale', 2));

function findFfmpeg() {
  if (process.env.FFMPEG) return process.env.FFMPEG;
  try { execSync('ffmpeg -version', { stdio: 'ignore' }); return 'ffmpeg'; } catch {}
  return execSync(`python3 -c "import imageio_ffmpeg;print(imageio_ffmpeg.get_ffmpeg_exe())"`).toString().trim();
}

// --accent violet renders with another of the app's accents (or a hex) without editing config.js.
const accent = arg('accent', null);
let browser, page;
// A fresh browser and page, ready to seek. Called at the start, every RECYCLE frames (a long
// 2x capture otherwise slows down and can crash as Chromium's memory grows), and after a crash.
async function open() {
  if (browser) await browser.close().catch(() => {});
  browser = await chromium.launch({
    // Full Chromium in new headless mode: the old headless shell skips backdrop-filter, and the
    // Liquid Glass bars need it.
    channel: 'chromium',
    args: ['--font-render-hinting=none', '--disable-lcd-text', '--force-color-profile=srgb'],
  });
  page = await browser.newPage({ viewport: { width: 1080, height: 1920 }, deviceScaleFactor: scale });
  await page.goto(pathToFileURL(path.join(here, 'reel.html')).href + '?render=1' + (accent ? '&accent=' + encodeURIComponent(accent) : ''));
  await page.waitForFunction(() => window.reel && window.reel.ready === true, null, { timeout: 60000 });
}
const RECYCLE = 150;
await open();
const duration = await page.evaluate(() => window.reel.duration);
const audioRel = await page.evaluate(() => (window.REEL_CONFIG || {}).audio || null);
const audioFile = audioRel && fs.existsSync(path.join(here, audioRel)) ? path.join(here, audioRel) : null;
const from = Number(arg('from', 0));
const to = Math.min(Number(arg('to', duration)), duration);

if (stills) {
  for (const s of stills.split(',').map(Number)) {
    await page.evaluate((t) => window.reel.seek(t), s);
    const file = path.join(here, `still-${String(s).replace('.', '_')}.png`);
    await page.screenshot({ path: file });
    console.log(file);
  }
  await browser.close();
  process.exit(0);
}

const ffmpeg = spawn(findFfmpeg(), [
  '-y', '-loglevel', 'error',
  '-f', 'image2pipe', '-framerate', String(fps), '-c:v', 'mjpeg', '-i', '-',
  // The soundtrack from config.js; silence if there is none, since Instagram wants a track.
  ...(audioFile ? ['-i', audioFile] : ['-f', 'lavfi', '-i', 'anullsrc=channel_layout=stereo:sample_rate=48000']),
  '-map', '0:v', '-map', '1:a',
  '-vf', 'scale=1080:1920:flags=lanczos+accurate_rnd+full_chroma_int',
  '-c:v', 'libx264', '-preset', 'slow', '-crf', String(arg('crf', 16)), '-tune', 'film', '-pix_fmt', 'yuv420p',
  '-profile:v', 'high', '-r', String(fps),
  '-c:a', 'aac', '-b:a', '320k', '-ar', '48000', '-shortest', '-movflags', '+faststart',
  out,
], { stdio: ['pipe', 'inherit', 'inherit'] });

const frames = Math.ceil((to - from) * fps);
for (let i = 0; i < frames; i++) {
  const t = from + i / fps;
  if (i > 0 && i % RECYCLE === 0) await open();
  let buf;
  for (let attempt = 0; ; attempt++) {
    try {
      await page.evaluate((t) => window.reel.seek(t), t);
      buf = await page.screenshot({ type: 'jpeg', quality: 100 });
      break;
    } catch (err) {
      if (attempt >= 3) throw err;
      console.warn(`\nframe ${i} (${t.toFixed(2)} s): ${err.message.split('\n')[0]}; restarting the browser`);
      await open();
    }
  }
  if (!ffmpeg.stdin.write(buf)) await new Promise((r) => ffmpeg.stdin.once('drain', r));
  if (i % fps === 0) process.stdout.write(`\r${t.toFixed(1)}s / ${to}s`);
}
ffmpeg.stdin.end();
await new Promise((r) => ffmpeg.on('close', r));
await browser.close();
console.log(`\nwrote ${out}`);
