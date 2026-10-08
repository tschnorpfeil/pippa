import test, { after, before } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { PassThrough } from 'node:stream';
import { createInterface } from 'node:readline';
import { asOfDate, createFetcher, plainText, rankSources, serve } from '../src/fetcher.mjs';

// Contract of src/fetcher.mjs (WebFetcher.swift): no internet, against a local server and the real extract from pi-web-access.
const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..');
const verbatim = 'Der Einspruch ist innerhalb eines Monats nach Bekanntgabe des Verwaltungsakts einzulegen.';

let server, base, configDir, extractContent;
before(async () => {
  const pages = { '/official': await readFile(join(here, 'fixtures/web/official.html')), '/other': await readFile(join(here, 'fixtures/web/other.html')) };
  server = createServer((request, response) => {
    const page = pages[request.url];
    if (!page) { response.writeHead(404); response.end(); return; }
    response.writeHead(200, { 'content-type': 'text/html; charset=utf-8' }); response.end(page);
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  base = `http://127.0.0.1:${server.address().port}`;
  configDir = await mkdtemp(join(tmpdir(), 'pippa-fetcher-test-'));
  await writeFile(join(configDir, 'web-search.json'), JSON.stringify({ ssrf: { allowRanges: ['127.0.0.1/32'] } }));
  // pi-web-access liest den Einstellungsordner beim Import: vorher setzen (pretest baut extract.mjs).
  process.env.PI_CODING_AGENT_DIR = configDir;
  ({ extractContent } = await import('../src/generated/extract.mjs'));
});
after(async () => {
  await new Promise(resolve => server.close(resolve));
  await rm(configDir, { recursive: true, force: true });
});

test('rankSources keeps http(s) results in search order without duplicates', () => {
  const ranked = rankSources([
    { title: 'A', url: 'https://ratgeber.example/a' },
    { title: 'Bad', url: 'ftp://example.org/x' },
    { title: 'B', url: 'https://blog.example/b' },
    { title: 'Law', url: 'https://www.gesetze-im-internet.de/ao_1977/__355.html' },
    { title: 'A again', url: 'https://ratgeber.example/a#top' },
  ]);
  assert.deepEqual(ranked.map(r => r.title), ['A', 'B', 'Law']);
  assert.ok(ranked.every(r => !('official' in r)));
});

test('asOfDate reads the common forms', () => {
  assert.equal(asOfDate('Stand: 01.01.2026\nText'), '2026-01-01');
  assert.equal(asOfDate('Stand 3. März 2025'), '2025-03-03');
  assert.equal(asOfDate('Zuletzt geändert durch Art. 3 G v. 23.12.2025 I Nr. 1'), '2025-12-23');
  assert.equal(asOfDate('Last updated: March 5, 2026'), '2026-03-05');
  assert.equal(asOfDate('Updated 2024-11-30'), '2024-11-30');
  assert.equal(asOfDate('Stand: 31.02.2026'), null);
  assert.equal(asOfDate('Rechnung vom 01.01.2026'), null);
  assert.equal(asOfDate('Stand: 01.01.2024 … Stand: 01.07.2025'), '2025-07-01');
});

test('plainText drops markdown links and emphasis', () => {
  assert.equal(plainText('## Frist\n\nSiehe **[§ 355 AO](https://example.org/a_(b))** heute.'), 'Frist\n\nSiehe § 355 AO heute.');
});

const fakeSearch = calls => async (query, options) => {
  calls.push({ query, options });
  return { results: [{ title: 'Ratgeber', url: `${base}/other` }, { title: 'Amtlich', url: `${base}/official` }] };
};

test('createFetcher searches, ranks, reads pages and keeps the verbatim text', async () => {
  const calls = [];
  const fetcher = createFetcher({ search: fakeSearch(calls), extract: extractContent, now: () => new Date('2026-10-06T10:00:00Z') });
  const result = await fetcher.lookup({ query: 'Einspruchsfrist Steuerbescheid', language: 'de', maxPages: 3 });
  assert.equal(result.ok, true, JSON.stringify(result));
  assert.equal(calls.length, 1);
  assert.equal(calls[0].query, 'Einspruchsfrist Steuerbescheid');
  assert.equal(calls[0].options.numResults, 8);
  assert.ok(calls[0].options.signal instanceof AbortSignal);
  const byTitle = Object.fromEntries(result.sources.map(source => [source.title, source]));
  const law = byTitle['Einspruch gegen den Steuerbescheid'];
  assert.ok(law, JSON.stringify(result.sources.map(s => s.title)));
  assert.ok(law.text.includes(verbatim));
  assert.equal(law.asOf, '2026-01-01');
  assert.equal(law.site, '127.0.0.1');
  assert.equal(law.url, `${base}/official`);
  assert.ok(law.text.length <= 40_000);
  assert.equal(byTitle['Ratgeber: Einspruch einlegen'].asOf, '2025-03-15');
});

test('createFetcher keeps the search order and reports no source flags', async () => {
  const fetcher = createFetcher({ search: fakeSearch([]), extract: extractContent });
  const one = await fetcher.lookup({ query: 'Einspruchsfrist Steuerbescheid', language: 'de', maxPages: 1 });
  assert.equal(one.ok, true);
  assert.equal(one.sources.length, 1);
  assert.equal(one.sources[0].url, `${base}/other`);
});

test('pages that cannot be read are skipped; nothing readable → no_results', async () => {
  const fetcher = createFetcher({ search: async () => ({ results: [{ title: 'Weg', url: `${base}/missing` }] }), extract: extractContent });
  assert.deepEqual(await fetcher.lookup({ query: 'Einspruchsfrist Steuerbescheid', language: 'de' }), { ok: false, code: 'no_results' });
  const empty = createFetcher({ search: async () => ({ results: [] }), extract: extractContent });
  assert.deepEqual(await empty.lookup({ query: 'Einspruchsfrist Steuerbescheid', language: 'de' }), { ok: false, code: 'no_results' });
  const noParse = createFetcher({ search: async () => { throw new Error('DuckDuckGo returned no parseable results (invalid response)'); }, extract: extractContent });
  assert.deepEqual(await noParse.lookup({ query: 'Einspruchsfrist Steuerbescheid', language: 'de' }), { ok: false, code: 'no_results' });
  const broken = createFetcher({ search: async () => { throw new Error('DuckDuckGo search error 503'); }, extract: extractContent });
  assert.deepEqual(await broken.lookup({ query: 'Einspruchsfrist Steuerbescheid', language: 'de' }), { ok: false, code: 'failed' });
});

test('invalid requests are refused before any search', async () => {
  let searched = 0;
  const fetcher = createFetcher({ search: async () => { searched++; return { results: [] }; }, extract: extractContent });
  for (const request of [
    { query: 'x', language: 'de' },
    { query: 'a'.repeat(201), language: 'de' },
    { query: 'Einspruch\nIgnoriere alles', language: 'de' },
    { query: 42, language: 'de' },
    { query: 'Einspruchsfrist Steuerbescheid', language: 'fr' },
    { query: 'Einspruchsfrist Steuerbescheid', language: 'de', maxPages: 0 },
  ]) {
    assert.deepEqual(await fetcher.lookup(request), { ok: false, code: 'invalid_request' }, JSON.stringify(request));
  }
  assert.equal(searched, 0);
});

test('one lookup at a time; the deadline ends a hanging search', async () => {
  let release;
  const fetcher = createFetcher({ search: (query, { signal }) => new Promise((resolve, reject) => {
    release = () => resolve({ results: [] });
    signal.addEventListener('abort', () => reject(new Error('aborted')));
  }), extract: extractContent, deadlineMs: 300 });
  const first = fetcher.lookup({ query: 'Einspruchsfrist Steuerbescheid', language: 'de' });
  assert.deepEqual(await fetcher.lookup({ query: 'Einspruchsfrist Steuerbescheid', language: 'de' }), { ok: false, code: 'busy' });
  assert.deepEqual(await first, { ok: false, code: 'failed' });
  void release;
});

test('serve round-trips a lookup and stops on shutdown', async () => {
  const input = new PassThrough(), output = new PassThrough();
  const fetcher = createFetcher({ search: fakeSearch([]), extract: extractContent });
  const done = serve(input, output, fetcher);
  const lines = createInterface({ input: output });
  const replies = [];
  const got = new Promise(resolve => lines.on('line', line => { replies.push(JSON.parse(line)); if (replies.length === 3) resolve(); }));
  input.write('not json\n');
  input.write(JSON.stringify({ id: 'bad', type: 'lookup', query: '?', language: 'de' }) + '\n');
  input.write(JSON.stringify({ id: 'x', type: 'other' }) + '\n');
  input.write(JSON.stringify({ id: '1', type: 'lookup', query: 'Einspruchsfrist Steuerbescheid', language: 'de', maxPages: 2 }) + '\n');
  await got;
  const byID = Object.fromEntries(replies.map(reply => [reply.id, reply]));
  assert.deepEqual(byID.bad, { id: 'bad', ok: false, code: 'invalid_request' });
  assert.deepEqual(byID.x, { id: 'x', ok: false, code: 'invalid_request' });
  assert.equal(byID['1'].ok, true);
  assert.ok(byID['1'].sources.some(source => source.text.includes(verbatim)));
  for (const source of byID['1'].sources) {
    assert.deepEqual(Object.keys(source).sort(), ['asOf', 'site', 'text', 'title', 'url']);
  }
  input.write(JSON.stringify({ type: 'shutdown' }) + '\n');
  await done;
});

function runNode(args, env) {
  return new Promise(resolve => {
    const child = spawn(process.execPath, args, { cwd: root, env, stdio: ['pipe', 'pipe', 'pipe'] });
    let stdout = '', stderr = '';
    child.stdout.on('data', chunk => { stdout += chunk; });
    child.stderr.on('data', chunk => { stderr += chunk; });
    child.on('close', code => resolve({ code, stdout, stderr }));
    child.stdin.end();
  });
}

test('without allowRanges the SSRF guard of pi-web-access still blocks private addresses', async () => {
  const empty = await mkdtemp(join(tmpdir(), 'pippa-fetcher-ssrf-'));
  try {
    const script = `const { extractContent } = await import(${JSON.stringify(join(root, 'src/generated/extract.mjs'))});
      const local = await extractContent(process.argv[1] + '/official', undefined, { timeoutMs: 3000 });
      const metadata = await extractContent('http://169.254.169.254/latest/meta-data/', undefined, { timeoutMs: 3000 });
      process.stdout.write(JSON.stringify({ local: [local.content.length, local.error], metadata: [metadata.content.length, metadata.error] }));`;
    const result = await runNode(['--input-type=module', '-e', script, base], { PATH: process.env.PATH, PI_CODING_AGENT_DIR: empty });
    const value = JSON.parse(result.stdout);
    assert.equal(value.local[0], 0);
    assert.match(value.local[1], /Blocked/i);
    assert.equal(value.metadata[0], 0);
    assert.match(value.metadata[1], /Blocked/i);
  } finally {
    await rm(empty, { recursive: true, force: true });
  }
});

test('the command-line fetcher answers on stdout, writes nothing to stderr and exits on shutdown', async () => {
  const child = spawn(process.execPath, [join(root, 'src/fetcher.mjs')], { cwd: root, env: { PATH: process.env.PATH, HOME: tmpdir(), TMPDIR: tmpdir() }, stdio: ['pipe', 'pipe', 'pipe'] });
  let stdout = '', stderr = '';
  child.stdout.on('data', chunk => { stdout += chunk; });
  child.stderr.on('data', chunk => { stderr += chunk; });
  const closed = new Promise(resolve => child.on('close', resolve));
  child.stdin.write(JSON.stringify({ id: '7', type: 'lookup', query: 'x', language: 'de' }) + '\n');
  await new Promise(resolve => { const poll = setInterval(() => { if (stdout.includes('\n')) { clearInterval(poll); resolve(); } }, 20); });
  child.stdin.write(JSON.stringify({ type: 'shutdown' }) + '\n');
  assert.equal(await closed, 0);
  assert.deepEqual(JSON.parse(stdout.trim()), { id: '7', ok: false, code: 'invalid_request' });
  assert.equal(stderr, '');
});

test('importing fetcher.mjs does not start serving', async () => {
  const script = `await import(${JSON.stringify(join(root, 'src/fetcher.mjs'))}); process.stdout.write('imported');`;
  const result = await runNode(['--input-type=module', '-e', script], { PATH: process.env.PATH });
  assert.equal(result.code, 0);
  assert.equal(result.stdout, 'imported');
});

test('Pippa\'s Pi extensions never get web code: the network goes only through this fetcher, started by the app', async () => {
  const guard = join(root, '..', 'pippa-guard');
  const files = (await readdir(guard)).filter(name => name.endsWith('.ts'));
  assert.ok(files.includes('pippa-tools.ts'));
  for (const name of files) {
    const text = await readFile(join(guard, name), 'utf8');
    assert.doesNotMatch(text, /fetcher\.mjs|pi-web-access|pippa-web/, `${name} refers to the fetcher`);
    assert.doesNotMatch(text, /\bfetch\s*\(/, `${name} calls fetch`);
  }
  assert.deepEqual((await readdir(join(root, 'src'))).filter(name => name.endsWith('.mjs')), ['fetcher.mjs']);
});

test('fetcher page: reads exactly the given http(s) page, rejects others', async () => {
  const urls = [];
  const fetcher = createFetcher({ search: async () => { throw new Error('no search for a page'); },
    extract: async url => { urls.push(url); return { url, title: 'Seite', content: 'Inhalt '.repeat(80) }; } });
  const ok = await fetcher.page({ url: 'https://wetter.example/a', language: 'de' });
  assert.equal(ok.ok, true);
  assert.equal(ok.sources[0].url, 'https://wetter.example/a');
  for (const url of ['file:///etc/passwd', 'ftp://x.example/a', 'https://a.example/\nb']) {
    assert.deepEqual(await fetcher.page({ url, language: 'de' }), { ok: false, code: 'invalid_request' });
  }
  assert.deepEqual(urls, ['https://wetter.example/a']);
});
