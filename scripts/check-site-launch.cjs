// Publication gate: detects missing technical files and unfinished legal pages.
// This is not a legal-compliance certification.
const fs = require('node:fs');
const path = require('node:path');
const site = path.join(__dirname, '../site');
const errors = [];
const read = name => {
  try { return fs.readFileSync(path.join(site, name), 'utf8'); }
  catch { errors.push(`Missing ${name}`); return ''; }
};
const legalPages = ['impressum.html', 'datenschutz.html'];
for (const link of legalPages) {
  const legal = read(link);
  if (/data-legal-draft|class="pending"/.test(legal)) errors.push(`${link}: legal draft or required information is unfinished`);
}
// German homepage at / and English translation at /en/ (legal pages stay German).
const pages = [
  { file: 'index.html', url: 'https://heypippa.app/', legalPrefix: '' },
  { file: 'en/index.html', url: 'https://heypippa.app/en/', legalPrefix: '../' },
];
for (const { file, url, legalPrefix } of pages) {
  const html = read(file);
  if (!html) continue;
  for (const link of legalPages) {
    if (!html.includes(`href="${legalPrefix}${link}"`)) errors.push(`${file}: missing footer link ${legalPrefix}${link}`);
  }
  if (!html.includes(`<link rel="canonical" href="${url}">`)) errors.push(`${file}: missing production canonical ${url}`);
  for (const [lang, href] of [['de', 'https://heypippa.app/'], ['en', 'https://heypippa.app/en/'], ['x-default', 'https://heypippa.app/']]) {
    if (!html.includes(`<link rel="alternate" hreflang="${lang}" href="${href}">`)) errors.push(`${file}: missing hreflang ${lang}`);
  }
  const json = html.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/);
  try {
    if (!json) throw new Error('missing JSON-LD');
    const data = JSON.parse(json[1]);
    if (!data['@graph']?.some(n => n['@type'] === 'SoftwareApplication')) throw new Error('missing app schema');
  } catch (e) { errors.push(`${file}: ${e.message}`); }
}
const robots = read('robots.txt');
if (!robots.includes('Sitemap: https://heypippa.app/sitemap.xml')) errors.push('Missing sitemap reference');
const sitemap = read('sitemap.xml');
for (const loc of ['https://heypippa.app/', 'https://heypippa.app/en/']) {
  if (!sitemap.includes(`<loc>${loc}</loc>`)) errors.push(`Missing ${loc} in sitemap`);
}
for (const asset of ['og.jpg', 'og-en.jpg', 'favicon.ico', 'favicon.svg', 'apple-touch-icon.png', 'pippaMark.js', 'legal.css', 'fonts/bagel-fat-one.ttf']) {
  if (!fs.existsSync(path.join(site, asset))) errors.push(`Missing ${asset}`);
}
if (errors.length) {
  console.error('Not ready to publish:\n' + errors.map(e => `- ${e}`).join('\n'));
  process.exitCode = 1;
} else console.log('Technical launch checks passed. Confirm actual hosting, privacy disclosures and release behavior before publication.');
