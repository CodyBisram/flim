// Renders the LAST15 campaign into out/.
//
//   node social/promo/last15/render.mjs            stills, layers, storyboard, overview
//   node social/promo/last15/render.mjs --reel     also the 15 s reel MP4
//
// out/post.png, out/story.png          exactly Instagram's sizes (1080x1350, 1080x1920)
// out/post@3x.png, out/story@3x.png    3x masters (3240x4050, 3240x5760)
// out/layers/<frame>/<layer>.png       each layer alone on transparency, at 3x
// out/storyboard/reel-<t>.png          the reel's key moments
// out/overview.png                     both versions side by side
// out/reel.mp4                         1080x1920, 30 fps, drawn at 2x and scaled down
import { spawn, execSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';
import fs from 'node:fs';

let chromium;
try { ({ chromium } = await import('playwright')); } catch {
  const globalRoot = execSync('npm root -g').toString().trim();
  ({ chromium } = createRequire(path.join(globalRoot, 'noop.js'))('playwright'));
}
const here = path.dirname(fileURLToPath(import.meta.url));
const out = path.join(here, 'out');
fs.mkdirSync(path.join(out, 'storyboard'), { recursive: true });
const SIZES = { post: [1080, 1350], story: [1080, 1920], reel: [1080, 1920] };
const LAYERS = ['background', 'perforations', 'mount', 'photo-hero', 'photo-second', 'photo-third', 'handwriting', '15', 'code', 'printed', 'grain'];
const STORY_BEATS = [2.4, 5.0, 8.4, 11.3, 14.6];

const browser = await chromium.launch({ channel: 'chromium', args: ['--font-render-hinting=none', '--disable-lcd-text', '--force-color-profile=srgb'] });
async function shot(frame, scale, file, { layer, t, omitBackground } = {}) {
  const [w, h] = SIZES[frame];
  const page = await browser.newPage({ viewport: { width: w, height: h }, deviceScaleFactor: scale });
  const q = new URLSearchParams({ frame, ...(layer ? { layer } : {}), ...(t !== undefined ? { t: String(t) } : {}) });
  await page.goto(pathToFileURL(path.join(here, 'campaign.html')).href + '?' + q);
  await page.waitForFunction(() => window.campaign && window.campaign.ready, null, { timeout: 60000 });
  const buf = await page.screenshot({ path: file, omitBackground: !!omitBackground, clip: { x: 0, y: 0, width: w, height: h } });
  await page.close();
  return buf;
}

for (const f of ['post', 'story']) {
  await shot(f, 1, path.join(out, `${f}.png`));
  await shot(f, 3, path.join(out, `${f}@3x.png`));
  fs.mkdirSync(path.join(out, 'layers', f), { recursive: true });
  for (const l of LAYERS) await shot(f, 3, path.join(out, 'layers', f, `${l}.png`), { layer: l, omitBackground: true });
  console.log(f, 'done');
}
for (const t of STORY_BEATS) await shot('reel', 1, path.join(out, 'storyboard', `reel-${String(t).replace('.', '_')}.png`), { t });

// the overview: Version A beside Version B's storyboard
{
  const page = await browser.newPage({ viewport: { width: 3240, height: 1500 }, deviceScaleFactor: 1 });
  const img = p => pathToFileURL(path.join(out, p)).href;
  const html = `<!doctype html><html><head><meta charset="utf-8"><style>
    @font-face { font-family: 'Archivo'; src: url(${pathToFileURL(path.join(here, 'fonts/archivo-wdth.woff2')).href}); font-weight: 100 900; font-stretch: 62% 125%; }
    @font-face { font-family: 'DM Mono'; src: url(${pathToFileURL(path.join(here, 'fonts/dm-mono-500.woff2')).href}); }
    body { margin: 0; background: #050403; color: #f4efe7; font-family: 'Archivo'; padding: 56px 64px; width: 3240px; box-sizing: border-box; }
    h1 { font: 700 22px 'Archivo'; font-stretch: 118%; letter-spacing: .26em; text-transform: uppercase; color: #a79c8e; margin: 0 0 36px; }
    .row { display: flex; gap: 72px; align-items: flex-start; }
    h2 { font: 500 17px 'DM Mono'; letter-spacing: .14em; text-transform: uppercase; color: #a79c8e; margin: 0 0 16px; }
    .a { display: flex; gap: 28px; align-items: flex-end; } .a img { display: block; border-radius: 8px; box-shadow: 0 20px 60px rgba(0,0,0,.6); }
    .b { display: flex; gap: 18px; } .b figure { margin: 0; } .b img { width: 300px; display: block; border-radius: 8px; }
    figcaption { font: 500 14px 'DM Mono'; color: #a79c8e; margin-top: 10px; letter-spacing: .06em; }
    .div { width: 1px; align-self: stretch; background: #2a221b; }
  </style></head><body><h1>FLIM · LAST15 · from the team at FLIM</h1><div class="row">
    <div><h2>Version A · Photo post + story</h2><div class="a"><img src="${img('post.png')}" style="width:880px"><img src="${img('story.png')}" style="width:440px"></div></div>
    <div class="div"></div>
    <div><h2>Version B · Reel · 15 s</h2><div class="b">${STORY_BEATS.map((t, i) => `<figure><img src="${img(`storyboard/reel-${String(t).replace('.', '_')}.png`)}"><figcaption>${['0 to 3 s · the note', '3 to 6 s · 15 more', '6 to 9 s · Founding 100', '9 to 12 s · the code', '12 to 15 s · link in bio'][i]}</figcaption></figure>`).join('')}</div></div>
  </div></body></html>`;
  fs.writeFileSync(path.join(out, '_overview.html'), html);
  await page.goto(pathToFileURL(path.join(out, '_overview.html')).href);
  await page.evaluate(() => document.fonts.ready);
  await page.waitForFunction(() => [...document.images].every(i => i.complete));
  const h = await page.evaluate(() => document.body.scrollHeight);
  await page.setViewportSize({ width: 3240, height: h });
  await page.screenshot({ path: path.join(out, 'overview.png') });
  fs.unlinkSync(path.join(out, '_overview.html'));
  await page.close();
}
console.log('stills, layers, storyboard and overview in', out);

if (process.argv.includes('--reel')) {
  const fps = 30, scale = 2;
  const ff = (() => { try { execSync('ffmpeg -version', { stdio: 'ignore' }); return 'ffmpeg'; } catch { return execSync(`python3 -c "import imageio_ffmpeg;print(imageio_ffmpeg.get_ffmpeg_exe())"`).toString().trim(); } })();
  const enc = spawn(ff, ['-y', '-loglevel', 'error', '-f', 'image2pipe', '-framerate', String(fps), '-c:v', 'mjpeg', '-i', '-',
    '-f', 'lavfi', '-i', 'anullsrc=channel_layout=stereo:sample_rate=48000', '-map', '0:v', '-map', '1:a',
    '-vf', 'scale=1080:1920:flags=lanczos+accurate_rnd+full_chroma_int', '-c:v', 'libx264', '-preset', 'slow', '-crf', '16', '-tune', 'film',
    '-pix_fmt', 'yuv420p', '-profile:v', 'high', '-r', String(fps), '-c:a', 'aac', '-b:a', '128k', '-shortest', '-movflags', '+faststart',
    path.join(out, 'reel.mp4')], { stdio: ['pipe', 'inherit', 'inherit'] });
  let page;
  const open = async () => {
    if (page) await page.close().catch(() => {});
    page = await browser.newPage({ viewport: { width: 1080, height: 1920 }, deviceScaleFactor: scale });
    await page.goto(pathToFileURL(path.join(here, 'campaign.html')).href + '?frame=reel&t=0');
    await page.waitForFunction(() => window.campaign && window.campaign.ready, null, { timeout: 60000 });
  };
  await open();
  const frames = Math.ceil(15 * fps);
  for (let i = 0; i < frames; i++) {
    if (i && i % 150 === 0) await open();
    await page.evaluate(t => window.campaign.seek(t), i / fps);
    const buf = await page.screenshot({ type: 'jpeg', quality: 100 });
    if (!enc.stdin.write(buf)) await new Promise(r => enc.stdin.once('drain', r));
    if (i % fps === 0) process.stdout.write(`\r${(i / fps).toFixed(0)} s / 15 s`);
  }
  enc.stdin.end();
  await new Promise(r => enc.on('close', r));
  console.log('\nreel.mp4 written');
}
await browser.close();
