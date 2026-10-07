// Renders the LAST15 campaign into out/.
//
//   node social/promo/last15/render.mjs
//
// out/post.png, out/story.png          exactly Instagram's sizes (1080x1350, 1080x1920)
// out/post@3x.png, out/story@3x.png    3x masters (3240x4050, 3240x5760)
// out/layers/<frame>/<layer>.png       each layer alone on transparency, at 3x
// out/overview.png                     the post and the story side by side
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
fs.mkdirSync(out, { recursive: true });
const SIZES = { post: [1080, 1350], story: [1080, 1920] };
const LAYERS = ['background', 'perforations', 'mount', 'photo-hero', 'copy', '15', 'code', 'handwriting', 'printed', 'grain'];

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

// the overview: Version A beside Version B's storyboard
{
  const page = await browser.newPage({ viewport: { width: 2100, height: 1500 }, deviceScaleFactor: 1 });
  const img = p => pathToFileURL(path.join(out, p)).href;
  const html = `<!doctype html><html><head><meta charset="utf-8"><style>
    @font-face { font-family: 'Archivo'; src: url(${pathToFileURL(path.join(here, 'fonts/archivo-wdth.woff2')).href}); font-weight: 100 900; font-stretch: 62% 125%; }
    @font-face { font-family: 'DM Mono'; src: url(${pathToFileURL(path.join(here, 'fonts/dm-mono-500.woff2')).href}); }
    body { margin: 0; background: #050403; color: #f4efe7; font-family: 'Archivo'; padding: 56px 64px; width: 2100px; box-sizing: border-box; }
    h1 { font: 700 22px 'Archivo'; font-stretch: 118%; letter-spacing: .26em; text-transform: uppercase; color: #a79c8e; margin: 0 0 36px; }
    .a { display: flex; gap: 40px; align-items: flex-end; } .a img { display: block; border-radius: 8px; box-shadow: 0 20px 60px rgba(0,0,0,.6); }
    h2 { font: 500 17px 'DM Mono'; letter-spacing: .14em; text-transform: uppercase; color: #a79c8e; margin: 0 0 16px; }
  </style></head><body><h1>FLIM · LAST15 · from the team at FLIM</h1>
    <h2>Photo post · 1080 x 1350 &nbsp;&nbsp;&nbsp;&nbsp; Story · 1080 x 1920</h2><div class="a"><img src="${img('post.png')}" style="width:1080px"><img src="${img('story.png')}" style="width:768px"></div>
  </body></html>`;
  fs.writeFileSync(path.join(out, '_overview.html'), html);
  await page.goto(pathToFileURL(path.join(out, '_overview.html')).href);
  await page.evaluate(() => document.fonts.ready);
  await page.waitForFunction(() => [...document.images].every(i => i.complete));
  const h = await page.evaluate(() => document.body.scrollHeight);
  await page.setViewportSize({ width: 2100, height: h });
  await page.screenshot({ path: path.join(out, 'overview.png') });
  fs.unlinkSync(path.join(out, '_overview.html'));
  await page.close();
}
console.log('stills, layers and overview in', out);

await browser.close();
