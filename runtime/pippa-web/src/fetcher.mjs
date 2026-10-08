// Pippa's own fetch process for "look up online" and "check online". Only the app starts it (WebFetcher.swift), never
// Pi: the model only proposes a search query or page; the app checks it in code (QueryGuard, WebAccessGate), asks the
// person and sends it here. This process searches (pi-web-access, DuckDuckGo HTML) and reads pages (pi-web-access
// extract).
//
// Protocol (JSON lines over stdio):
//   in   {"id":"1","type":"lookup","query":"Einspruchsfrist Steuerbescheid","language":"de","maxPages":3}
//        {"id":"2","type":"page","url":"https://…","language":"de"}   (one page the host already allowed)
//        {"type":"shutdown"}
//   out  {"id":"1","ok":true,"sources":[{"url","site","title","asOf":"yyyy-mm-dd"|null,"text"}]}
//        {"id":"1","ok":false,"code":"no_results"|"failed"|"invalid_request"|"busy"}
//
// Rules: nothing on stderr (no query, no page content); one request at a time; at most 25 s.
// Own package (runtime/pippa-web, in the bundle at Contents/Resources/pippa-web); reads no files except what
// pi-web-access itself needs.
// The search provider is DuckDuckGo HTML via pi-web-access; replaceable via `search` in createFetcher.
// Latency budget: search 10 s, each page 10 s in parallel, 25 s overall.
import { createInterface } from 'node:readline';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

export const limits = Object.freeze({ queryMin: 2, queryMax: 200, maxPages: 3, numResults: 8, searchMs: 10_000, pageMs: 10_000,
  deadlineMs: 25_000, textMax: 40_000, minContent: 200 });

/** Hostname without "www.", lower-cased. */
export function siteOf(url) {
  try { return new URL(url).hostname.toLowerCase().replace(/^www\./, ''); } catch { return ''; }
}

function isWebURL(url) {
  try { const parsed = new URL(url); return parsed.protocol === 'http:' || parsed.protocol === 'https:'; } catch { return false; }
}

/** Search results: http(s) only, no duplicates, in search order. Judging source quality is left to the model (no host lists). */
export function rankSources(results) {
  const seen = new Set();
  const list = [];
  for (const result of Array.isArray(results) ? results : []) {
    const url = typeof result?.url === 'string' ? result.url : '';
    if (!isWebURL(url)) continue;
    const key = url.replace(/#.*$/, '');
    if (seen.has(key)) continue;
    seen.add(key);
    list.push({ title: typeof result.title === 'string' ? result.title : '', url, snippet: typeof result.snippet === 'string' ? result.snippet : '' });
  }
  return list;
}

const monthNumbers = {
  januar: 1, jänner: 1, februar: 2, märz: 3, maerz: 3, april: 4, mai: 5, juni: 6, juli: 7, august: 8, september: 9, oktober: 10,
  november: 11, dezember: 12,
  january: 1, february: 2, march: 3, may: 5, june: 6, july: 7, october: 10, december: 12,
};
const germanMonths = 'Januar|Jänner|Februar|März|Maerz|April|Mai|Juni|Juli|August|September|Oktober|November|Dezember';
const englishMonths = 'January|February|March|April|May|June|July|August|September|October|November|December';

function isoDate(year, month, day) {
  const y = Number(year), m = Number(month), d = Number(day);
  if (!Number.isInteger(y) || y < 1990 || y > 2100 || m < 1 || m > 12 || d < 1 || d > 31) return null;
  const date = new Date(Date.UTC(y, m - 1, d));
  if (date.getUTCMonth() !== m - 1 || date.getUTCDate() !== d) return null;
  return `${String(y).padStart(4, '0')}-${String(m).padStart(2, '0')}-${String(d).padStart(2, '0')}`;
}

const asOfPatterns = [
  // Stand: 01.01.2026 · Stand 1.1.2026
  { re: /\bStand:?\s+(\d{1,2})\.\s?(\d{1,2})\.\s?(\d{4})\b/gi, parts: m => [m[3], m[2], m[1]] },
  // Stand: 1. Januar 2026 · Stand 01. März 2026
  { re: new RegExp(`\\bStand:?\\s+(\\d{1,2})\\.?\\s+(${germanMonths})\\s+(\\d{4})\\b`, 'gi'), parts: m => [m[3], monthNumbers[m[2].toLowerCase()], m[1]] },
  // zuletzt geändert durch Art. 3 G v. 23.12.2025 · Zuletzt geändert am 05.03.2026
  { re: /\bzuletzt\s+(?:geändert|aktualisiert)\b[^\n]{0,80}?(\d{1,2})\.\s?(\d{1,2})\.\s?(\d{4})\b/gi, parts: m => [m[3], m[2], m[1]] },
  // Last updated: March 5, 2026 · Last updated March 5 2026
  { re: new RegExp(`\\b(?:Last\\s+)?updated:?\\s+(?:on\\s+)?(${englishMonths})\\s+(\\d{1,2}),?\\s+(\\d{4})\\b`, 'gi'), parts: m => [m[3], monthNumbers[m[1].toLowerCase()], m[2]] },
  // Last updated: 5 March 2026
  { re: new RegExp(`\\b(?:Last\\s+)?updated:?\\s+(?:on\\s+)?(\\d{1,2})\\s+(${englishMonths})\\s+(\\d{4})\\b`, 'gi'), parts: m => [m[3], monthNumbers[m[2].toLowerCase()], m[1]] },
  // Updated 2026-03-05 · Last updated: 2026-03-05
  { re: /\b(?:Last\s+)?updated:?\s+(?:on\s+)?(\d{4})-(\d{2})-(\d{2})\b/gi, parts: m => [m[1], m[2], m[3]] },
];

/** The page's "as of" date as 'yyyy-mm-dd' or null. With several dates, the most recent. */
export function asOfDate(text) {
  const source = String(text ?? '');
  let best = null;
  for (const { re, parts } of asOfPatterns) {
    re.lastIndex = 0;
    for (const match of source.matchAll(re)) {
      const [year, month, day] = parts(match);
      const value = isoDate(year, month, day);
      if (value && (best === null || value > best)) best = value;
    }
  }
  return best;
}

/** Markdown from pi-web-access as plain text: links without target, no images, no emphasis marks. */
export function plainText(markdown) {
  return String(markdown ?? '')
    .replace(/!\[[^\]]*\]\([^)]*\)/g, '')
    .replace(/\[([^\]]*)\]\((?:[^()]|\([^)]*\))*\)/g, '$1')
    .replace(/\*\*|__/g, '')
    .replace(/`+/g, '')
    .replace(/^[ \t]*#{1,6}[ \t]+/gm, '')
    .replace(/^[ \t]*>[ \t]?/gm, '')
    .replace(/[ \t]+\n/g, '\n')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

function validQuery(query) {
  if (typeof query !== 'string') return null;
  if (/[\r\n\u2028\u2029]/.test(query)) return null;
  const trimmed = query.trim();
  if (trimmed.length < limits.queryMin || trimmed.length > limits.queryMax) return null;
  return trimmed;
}

/**
 * `search(query, { numResults, signal })` → { results: [{ title, url, snippet }] } (pi-web-access SearchResponse)
 * `extract(url, signal, options)` → { url, title, content, error } (pi-web-access ExtractedContent)
 */
export function createFetcher({ search, extract, now = () => new Date(), deadlineMs = limits.deadlineMs } = {}) {
  let running = false;
  async function readPage(candidate, signal) {
    let page;
    try {
      page = await extract(candidate.url, signal, { timeoutMs: limits.pageMs, rejectDirectImages: 'no images' });
    } catch { return null; }
    // pi-web-access reports "appears incomplete" for short pages even when the content is usable: the content decides.
    const content = typeof page?.content === 'string' ? plainText(page.content) : '';
    if (content.trim().length < limits.minContent) return null;
    const text = content.slice(0, limits.textMax);
    let asOf = asOfDate(text);
    const today = now();
    if (asOf && today instanceof Date && !Number.isNaN(today.getTime())) {
      // A date more than a day in the future is not a valid "as of" date.
      const limit = new Date(today.getTime() + 86_400_000).toISOString().slice(0, 10);
      if (asOf > limit) asOf = null;
    }
    const title = (typeof page?.title === 'string' && page.title.trim()) || candidate.title || siteOf(candidate.url);
    return { url: candidate.url, site: siteOf(candidate.url), title: title.replace(/\s+/g, ' ').trim().slice(0, 300), asOf, text };
  }
  async function lookup(request) {
    const query = validQuery(request?.query);
    const language = request?.language ?? 'de';
    if (!query || (language !== 'de' && language !== 'en')) return { ok: false, code: 'invalid_request' };
    const requested = request?.maxPages === undefined ? limits.maxPages : Number(request.maxPages);
    if (!Number.isInteger(requested) || requested < 1) return { ok: false, code: 'invalid_request' };
    const maxPages = Math.min(requested, limits.maxPages);
    if (running) return { ok: false, code: 'busy' };
    running = true;
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), deadlineMs);
    try {
      let response;
      try {
        response = await search(query, { numResults: limits.numResults, signal: AbortSignal.any([controller.signal, AbortSignal.timeout(limits.searchMs)]) });
      } catch (error) {
        // DuckDuckGo reports "no parseable results" when it simply found nothing.
        const message = error instanceof Error ? error.message : String(error);
        return { ok: false, code: /no parseable results/i.test(message) ? 'no_results' : 'failed' };
      }
      const ranked = rankSources(response?.results);
      if (ranked.length === 0) return { ok: false, code: 'no_results' };
      const sources = [];
      // At most two rounds: if none of the first pages can be read, the next ones follow.
      for (let start = 0; start < ranked.length && start < maxPages * 2 && sources.length === 0 && !controller.signal.aborted; start += maxPages) {
        const pages = await Promise.all(ranked.slice(start, start + maxPages).map(candidate => readPage(candidate, controller.signal)));
        for (const page of pages) if (page) sources.push(page);
      }
      if (sources.length > 0) return { ok: true, sources };
      return { ok: false, code: controller.signal.aborted ? 'failed' : 'no_results' };
    } catch {
      return { ok: false, code: 'failed' };
    } finally {
      clearTimeout(timer);
      running = false;
    }
  }
  /** Reads exactly one page. The host decides which addresses are allowed (WebAccessGate); here only http(s). */
  async function page(request) {
    const url = typeof request?.url === 'string' ? request.url.trim() : '';
    const language = request?.language ?? 'de';
    if (!isWebURL(url) || url.length > 2000 || /[\r\n]/.test(url) || (language !== 'de' && language !== 'en')) return { ok: false, code: 'invalid_request' };
    if (running) return { ok: false, code: 'busy' };
    running = true;
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), deadlineMs);
    try {
      const read = await readPage({ url, title: '' }, controller.signal);
      return read ? { ok: true, sources: [read] } : { ok: false, code: controller.signal.aborted ? 'failed' : 'no_results' };
    } catch {
      return { ok: false, code: 'failed' };
    } finally {
      clearTimeout(timer);
      running = false;
    }
  }
  return { lookup, page };
}

/** Reads JSON lines from `input`, writes answers to `output`. Ends with `shutdown` or end of input. */
export function serve(input, output, fetcher) {
  return new Promise(resolve => {
    const lines = createInterface({ input, crlfDelay: Infinity });
    let finished = false;
    const finish = () => { if (finished) return; finished = true; lines.close(); resolve(); };
    const write = value => { if (!finished) output.write(JSON.stringify(value) + '\n'); };
    lines.on('line', line => {
      let command;
      try { command = JSON.parse(line); } catch { return; }
      if (!command || typeof command !== 'object') return;
      if (command.type === 'shutdown') { finish(); return; }
      const id = typeof command.id === 'string' ? command.id : null;
      if ((command.type !== 'lookup' && command.type !== 'page') || id === null) { write({ id, ok: false, code: 'invalid_request' }); return; }
      Promise.resolve()
        .then(() => command.type === 'page'
          ? fetcher.page({ url: command.url, language: command.language })
          : fetcher.lookup({ query: command.query, language: command.language, maxPages: command.maxPages }))
        .then(result => write({ id, ...result }), () => write({ id, ok: false, code: 'failed' }));
    });
    lines.on('close', finish);
  });
}

function startFromCommandLine() {
  // stdout belongs to the protocol, stderr stays empty: no console output from dependencies.
  for (const name of ['log', 'info', 'warn', 'error', 'debug', 'trace']) console[name] = () => {};
  process.on('unhandledRejection', () => {});
  process.on('uncaughtException', () => process.exit(1));
  if (!process.env.PIPPA_FETCHER_CONFIG_DIR) {
    // Own empty settings folder: direct fetch only, no third-party services, protection against internal addresses stays on.
    const directory = mkdtempSync(join(tmpdir(), 'pippa-fetcher-'));
    writeFileSync(join(directory, 'web-search.json'), JSON.stringify({ fetchRouting: { providers: ['http'], allowRemoteHostedProviders: false } }));
    process.env.PI_CODING_AGENT_DIR = directory;
    process.on('exit', () => { try { rmSync(directory, { recursive: true, force: true }); } catch {} });
  } else {
    process.env.PI_CODING_AGENT_DIR = process.env.PIPPA_FETCHER_CONFIG_DIR;
  }
  // Load only afterwards: pi-web-access reads the folder at import.
  Promise.all([import('./generated/extract.mjs'), import('./generated/duckduckgo.mjs')]).then(async ([{ extractContent }, { searchWithDuckDuckGo }]) => {
    const fetcher = createFetcher({ search: (query, options) => searchWithDuckDuckGo(query, options), extract: extractContent });
    await serve(process.stdin, process.stdout, fetcher);
    process.exit(0);
  }, () => process.exit(1));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) startFromCommandLine();
