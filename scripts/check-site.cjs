// Run with node scripts/check-site.cjs. No packages or browser required.
// Drag geometry of the hero demo (site/pippaDrag.js), then the content gate for the homepage:
// German and English stay in step, promises stay honest, nothing external is loaded.
const assert = require('node:assert/strict');
const { sample } = require('../site/pippaDrag.js');
const target = { left: 300, right: 450, top: 250, bottom: 314 };
const item = (x, y, pointerX = x, pointerY = y, width = 120, height = 100) => ({ centerX: x, centerY: y, pointerX, pointerY, width, height });

// Approaching and leaving use the same continuous force, with no sticky state.
for (let x = 100; x <= 650; x += .5) {
  const a = sample(item(x, 210), target);
  const b = sample(item(x + .01, 210), target);
  assert.ok(Math.hypot(a.pullX, a.pullY) <= 36 + 1e-8);
  assert.ok(Math.hypot(a.pullX - b.pullX, a.pullY - b.pullY) < .01);
  assert.deepEqual(a, sample(item(x, 210), target));
}
assert.equal(sample(item(90, 80), target).strength, 0);
assert.equal(sample(item(90, 80), target).ready, false);
assert.deepEqual([sample(item(375, 282), target).pullX, sample(item(375, 282), target).pullY], [0, 0]);
// The inner snap is noticeable, but leaves most of the distance under control.
const near = sample(item(305, 282), target);
assert.ok(near.pullX > 25 && near.pullX < 35);
assert.ok(305 + near.pullX < 375);
const outside = sample(item(90, 80), target);
assert.deepEqual([outside.pullX, outside.pullY, outside.dock], [0, 0, 0]);
const reduced = sample(item(305, 282), target, { maxPull: 0 });
assert.deepEqual([reduced.pullX, reduced.pullY], [0, 0]);

// Grabbing a sheet at its edge must work as well as grabbing its center.
assert.equal(sample(item(260, 220, 330, 275), target).ready, true);
assert.equal(sample(item(370, 280, 520, 400), target).ready, true);
assert.equal(sample(item(490, 280, 570, 280, 180, 120), target).ready, true);
assert.equal(sample(item(100, 100, 200, 180), target).ready, false);

// An oversized sheet barely brushing the target is not a drop.
assert.equal(sample(item(50, 50, 20, 20, 510, 410), target).ready, false);
const small = sample(item(375, 282, 375, 282, 0, 0), target);
assert.ok(Number.isFinite(small.pullX) && Number.isFinite(small.pullY));
console.log('Drag checks passed: continuous partial snap, 36px cap, release, reduced motion, edge grabs, overlap and misses.');

const fs = require('node:fs');
const path = require('node:path');
const site = path.join(__dirname, '../site');
const pages = { de: fs.readFileSync(path.join(site, 'index.html'), 'utf8'), en: fs.readFileSync(path.join(site, 'en/index.html'), 'utf8') };
const text = html => html.replace(/<script[\s\S]*?<\/script>|<style[\s\S]*?<\/style>/g, ' ').replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ');
const count = (html, re) => (html.match(re) || []).length;

// Same structure in both languages.
for (const re of [/<section\b/g, /<h2\b/g, /<h3\b/g, /<li class="sit"/g, /<details\b/g, /role="img"/g, /class="btn[^"]*dl/g, /<dt>/g]) {
  assert.equal(count(pages.de, re), count(pages.en, re), `DE and EN differ in ${re}`);
}
const ids = html => [...html.matchAll(/\sid="([^"]+)"/g)].map(m => m[1]).filter(id => id !== 'language').sort();
assert.deepEqual(ids(pages.de), ids(pages.en), 'DE and EN use different ids');

for (const [lang, html] of Object.entries(pages)) {
  const t = text(html);
  // Headings in order: one h1, no level skipped.
  const levels = [...html.matchAll(/<h([1-6])\b/g)].map(m => +m[1]);
  assert.equal(levels.filter(l => l === 1).length, 1, `${lang}: exactly one h1`);
  levels.reduce((prev, l) => { assert.ok(l <= prev + 1, `${lang}: heading level skipped (h${prev} → h${l})`); return l; }, 1);
  // Every illustration has a description.
  for (const m of html.matchAll(/<figure[^>]*>/g)) assert.match(m[0], /role="img" aria-label="[^"]{20,}"/, `${lang}: figure without description`);
  // Nothing is loaded from elsewhere; only links point outward.
  assert.doesNotMatch(html, /\bsrc="(https?:)?\/\//, `${lang}: external script or image`);
  for (const m of html.matchAll(/<link\b[^>]*href="(https?:)?\/\/[^>]*>/g)) {
    assert.match(m[0], /rel="(canonical|alternate)"/, `${lang}: external resource ${m[0]}`);
  }
  // Promises the product cannot keep.
  const banned = [
    /löscht (keine|nie)|never deletes|doesn’t delete files/i, /App-Sandbox\b(?![^.]*könnte)|in the App Sandbox\b(?![^.]*couldn)/i,
    /ganz auf deinem Mac|entirely on your Mac/i, /nichts verlässt|nothing (ever )?leaves/i,
    /Programmierwerkzeuge sind abgeschaltet|coding tools are switched off/i,
    /\bbeta\b|Version 0\.|version 0\.|noch holpern|still be bumpy/i,
    /revolution|nahtlos|seamless|mühelos|effortless/i, /DuckDuckGo/,
  ];
  for (const re of banned) assert.doesNotMatch(t, re, `${lang}: banned phrase ${re}`);
  // Language toggle in the header pointing to the other language, with the stored-choice hook.
  const head = html.match(/<header[\s\S]*?<\/header>/)[0];
  const other = lang === 'de' ? ['en/', 'en'] : ['../', 'de'];
  assert.ok(head.includes(`<a class="langsw" href="${other[0]}" hreflang="${other[1]}" lang="${other[1]}" data-lang="${other[1]}">`), `${lang}: header language toggle missing`);
  assert.match(html, /localStorage\.getItem\('pippa-lang'\)/, `${lang}: first-visit language choice missing`);
  assert.match(html, /<ol class="steps">(?:<li>[\s\S]*?<\/li>){3}<\/ol>/, `${lang}: getting-started steps missing`);
  // No emoji in the copy.
  assert.doesNotMatch(t, /\p{Extended_Pictographic}/u, `${lang}: emoji in copy`);
}
console.log('Site checks passed: DE/EN in step, headings, figure descriptions, no external resources, no banned promises or emoji.');

// Legal pages: toggle in the header, and the placeholder sentence is gone.
for (const f of ['datenschutz.html', 'impressum.html']) {
  const html = fs.readFileSync(path.join(site, f), 'utf8');
  assert.match(html.match(/<header[\s\S]*?<\/header>/)[0], /class="langsw" href="en\/" hreflang="en" lang="en" data-lang="en"/, `${f}: header language toggle missing`);
  assert.doesNotMatch(html, /getrennt zu beschreiben|Name oder Firma/, `${f}: working note or form label left`);
}
console.log('Legal pages: language toggle present, no working notes.');
