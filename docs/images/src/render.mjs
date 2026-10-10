// Renders the README pictures in docs/images from demo.html and gallery.html.
// Needs Playwright with Chromium and ffmpeg: node docs/images/src/render.mjs
// The pictures are design renderings of the pill, not screenshots of the app.
import { chromium } from 'playwright';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const images = join(here, '..');
const work = mkdtempSync(join(tmpdir(), 'pippa-readme-'));
const page = (file, query) => pathToFileURL(join(here, file)).href + '?' + new URLSearchParams(query);

const states = {
  idle: 'hush(); S.idle()',
  work: "S.work('Reading the letter · page 2 of 2', 1)",
  done: "S.done('pay by 31 Oct')",
  failed: 'S.failed()',
  fotos: 'S.resultFotos()',
  copy: 'S.resultCopy()',
  pasteshot: 'S.pasteShot()',
  pastefiles: 'S.pasteFiles()',
  'pasteshot-de': 'S.pasteShot(true)',
  'pastefiles-de': 'S.pasteFiles(true)',
};

const browser = await chromium.launch();
for (const theme of ['light', 'dark']) {
  // 1. Each pill state on a transparent background, with room for its shadow.
  const p = await browser.newPage({ viewport: { width: 960, height: 540 }, deviceScaleFactor: 2 });
  await p.goto(page('demo.html', { mode: 'static', bare: 1, theme }));
  await p.evaluate(() => document.fonts.ready);
  for (const [name, js] of Object.entries(states)) {
    await p.evaluate(js);
    await p.waitForTimeout(1600);
    const r = await p.evaluate(() => { const a = document.querySelector('#pill').getBoundingClientRect(); return { x: a.left, y: a.top, w: a.width, h: a.height }; });
    const pad = 64;
    await p.screenshot({ path: join(work, `${theme}-crop-${name}.png`), omitBackground: true, clip: { x: r.x - pad, y: r.y - pad, width: r.w + 2 * pad, height: r.h + 2 * pad + 16 } });
  }
  await p.close();

  // 2. The two galleries with captions.
  const g = await browser.newPage({ viewport: { width: 960, height: 400 }, deviceScaleFactor: 2 });
  for (const kind of ['moods', 'moments']) {
    await g.goto(page('gallery.html', { theme, kind, dir: pathToFileURL(work).href }));
    await g.evaluate(() => document.fonts.ready);
    await g.waitForTimeout(400);
    await g.locator('#g').screenshot({ path: join(images, `pill-${kind}-${theme}.png`) });
  }
  // Pasting with ⌘V: README in both themes, the website (light only) in German and English.
  await g.goto(page('gallery.html', { theme, kind: 'paste', dir: pathToFileURL(work).href }));
  await g.evaluate(() => document.fonts.ready);
  await g.waitForTimeout(400);
  await g.locator('#g').screenshot({ path: join(images, `pill-paste-${theme}.png`) });
  if (theme === 'light') {
    for (const [lang, narrow] of [['de', ''], ['en', ''], ['de', '1'], ['en', '1']]) {
      await g.goto(page('gallery.html', { theme, kind: 'paste', lang, narrow, dir: pathToFileURL(work).href }));
      await g.evaluate(() => document.fonts.ready);
      await g.waitForTimeout(400);
      const name = `einfuegen-${lang}${narrow ? '-schmal' : ''}`;
      const shot = join(work, `${name}.png`);
      await g.locator('#g').screenshot({ path: shot });
      execFileSync('ffmpeg', ['-v', 'error', '-y', '-i', shot, '-c:v', 'libwebp', '-quality', '86',
        join(here, '..', '..', '..', 'site', 'images', `${name}.webp`)]);
    }
  }
  await g.close();

  // 3. The animated walk-through, recorded at 1.5x and turned into a GIF.
  const dir = join(work, 'video-' + theme);
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 810 }, recordVideo: { dir, size: { width: 1440, height: 810 } } });
  const v = await ctx.newPage();
  await v.goto(page('demo.html', { z: 1.5, theme }));
  await v.waitForFunction(() => window.demoDone === true, null, { timeout: 60000 });
  await ctx.close();
  const video = join(dir, readdirSync(dir)[0]);
  execFileSync('ffmpeg', ['-v', 'error', '-y', '-i', video, '-vf',
    'crop=1440:630:0:0,setpts=0.85*PTS,fps=10,scale=960:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle',
    join(images, `pippa-demo-${theme}.gif`)]);
}
await browser.close();
