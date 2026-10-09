// Pippa's own fetch process for "look up online" and "check online". Only the app starts it (WebFetcher.swift), never
// Pi: the model only proposes a search query or page; the app checks it in code (QueryGuard, WebAccessGate), asks the
// person and sends it here. This process searches (DuckDuckGo HTML, own small request below) and reads pages
// (pi-web-access extract).
//
// Protocol (JSON lines over stdio):
//   in   {"id":"1","type":"lookup","query":"Einspruchsfrist Steuerbescheid","language":"de","maxPages":3}
//        {"id":"2","type":"page","url":"https://…","language":"de"}   (one page the host already allowed)
//        {"type":"shutdown"}
//   out  {"id":"1","ok":true,"sources":[{"url","site","title","asOf":"yyyy-mm-dd"|null,"text"}]}
//        {"id":"1","ok":false,"code":"no_results"|"blocked"|"timeout"|"protocol"|"unreadable"|"failed"|"invalid_request"|"busy"}
//   Both may carry "diag":{"layer":"search"|"page","provider":"duckduckgo","status":200|null,"ms","results","pages"}:
//   numbers and codes only, never the query or page text (WebFetcher.swift logs it).
//
// Codes: no_results = the provider answered and found nothing; blocked = the provider refused us (bot check, 403, 429);
// timeout = no answer in time; protocol = an answer we cannot read (changed page, other HTTP error); unreadable = hits
// or the page exist, but no page text could be read.
//
// Rules: nothing on stderr (no query, no page content); one request at a time; at most 25 s.
// Own package (runtime/pippa-web, in the bundle at Contents/Resources/pippa-web); reads no files except what
// pi-web-access itself needs.
// The search provider is DuckDuckGo HTML (searchDuckDuckGo); replaceable via `search` in createFetcher.
// Latency budget: search 10 s (one more try only after a search timeout), each page 10 s in parallel, 25 s overall.
import { createInterface } from 'node:readline';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

export const limits = Object.freeze({ queryMin: 2, queryMax: 200, maxPages: 3, numResults: 8, searchMs: 10_000, pageMs: 10_000,
  deadlineMs: 25_000, textMax: 40_000, minContent: 200 });

export const duckDuckGoURL = 'https://html.duckduckgo.com/html/';

/** A search failure with one of the codes above; `status` is the HTTP status when there was one. */
export class SearchError extends Error {
  constructor(code, status = null) { super(code); this.code = code; this.status = status; }
}

function resultURL(href) {
  try {
    const link = new URL(href, duckDuckGoURL);
    const url = new URL(link.searchParams.get('uddg') ?? link.href);
    return url.protocol === 'http:' || url.protocol === 'https:' ? url.href : null;
  } catch { return null; }
}

/**
 * Reads one DuckDuckGo HTML answer. Hits → { results }; otherwise throws SearchError. DuckDuckGo answers its bot check
 * with HTTP 202 and an "anomaly" page; pi-web-access 0.37.0 took that for an empty result ("no parseable results").
 */
export async function readDuckDuckGo(status, html) {
  if (status === 403 || status === 429) throw new SearchError('blocked', status);
  if (status < 200 || status > 299) throw new SearchError('protocol', status);
  const { parseHTML } = await import('linkedom');
  const { document } = parseHTML(String(html ?? ''));
  if (status === 202 || document.querySelector('.anomaly-modal__box, form#challenge-form')) throw new SearchError('blocked', status);
  const results = [];
  for (const container of document.querySelectorAll('.result')) {
    if (container.classList.contains('result--ad')) continue;
    const anchor = container.querySelector('.result__a');
    const title = anchor?.textContent?.trim() ?? '';
    const url = resultURL(anchor?.getAttribute('href')?.trim() ?? '');
    if (!title || !url) continue;
    results.push({ title, url, snippet: container.querySelector('.result__snippet')?.textContent?.trim() ?? '' });
  }
  if (results.length > 0) return { results, status };
  if (document.querySelector('.no-results__message, .no-results')) throw new SearchError('no_results', status);
  throw new SearchError('protocol', status);
}

/** DuckDuckGo HTML search, one request. `fetchImpl` only for tests. */
export async function searchDuckDuckGo(query, { numResults = limits.numResults, signal, fetchImpl = fetch } = {}) {
  const url = new URL(duckDuckGoURL);
  url.searchParams.set('q', query);
  let response, html;
  try {
    response = await fetchImpl(url, { headers: { Accept: 'text/html', 'User-Agent': 'Mozilla/5.0 (compatible; Pippa; +https://github.com/tschnorpfeil/pippa)' }, signal, redirect: 'error' });
    html = await response.text();
  } catch (error) {
    throw new SearchError(signal?.aborted ? 'timeout' : 'protocol');
  }
  const read = await readDuckDuckGo(response.status, html);
  return { results: read.results.slice(0, numResults), status: read.status };
}

const searchCodes = new Set(['no_results', 'blocked', 'timeout', 'protocol']);

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
 * `search(query, { numResults, signal })` → { results: [{ title, url, snippet }], status? }; failures throw SearchError
 *   (any other error counts as `protocol`, or `timeout` when the signal ended it).
 * `extract(url, signal, options)` → { url, title, content, error } (pi-web-access ExtractedContent)
 */
export function createFetcher({ search, extract, now = () => new Date(), deadlineMs = limits.deadlineMs, searchMs = limits.searchMs,
  provider = 'duckduckgo' } = {}) {
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
    const started = Date.now();
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), deadlineMs);
    const diag = { layer: 'search', provider, status: null, ms: 0, results: 0, pages: 0 };
    const finish = result => { diag.ms = Date.now() - started; return { ...result, diag }; };
    try {
      let response;
      // At most two tries, and the second only after a search timeout with enough time left: no loop, no other provider.
      for (let attempt = 1; ; attempt++) {
        const signal = AbortSignal.any([controller.signal, AbortSignal.timeout(searchMs)]);
        try {
          response = await search(query, { numResults: limits.numResults, signal });
          break;
        } catch (error) {
          const code = searchCodes.has(error?.code) ? error.code : (signal.aborted ? 'timeout' : 'protocol');
          diag.status = Number.isInteger(error?.status) ? error.status : null;
          const timeLeft = deadlineMs - (Date.now() - started);
          if (code === 'timeout' && attempt === 1 && !controller.signal.aborted && timeLeft > searchMs + limits.pageMs) continue;
          return finish({ ok: false, code });
        }
      }
      diag.status = Number.isInteger(response?.status) ? response.status : null;
      const ranked = rankSources(response?.results);
      diag.results = ranked.length;
      if (ranked.length === 0) return finish({ ok: false, code: 'no_results' });
      diag.layer = 'page';
      const sources = [];
      // At most two rounds: if none of the first pages can be read, the next ones follow.
      for (let start = 0; start < ranked.length && start < maxPages * 2 && sources.length === 0 && !controller.signal.aborted; start += maxPages) {
        const pages = await Promise.all(ranked.slice(start, start + maxPages).map(candidate => readPage(candidate, controller.signal)));
        for (const page of pages) if (page) sources.push(page);
      }
      diag.pages = sources.length;
      if (sources.length > 0) return finish({ ok: true, sources });
      // Hits, but no page text: not "nothing found".
      return finish({ ok: false, code: controller.signal.aborted ? 'timeout' : 'unreadable' });
    } catch {
      return finish({ ok: false, code: 'failed' });
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
    const started = Date.now();
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), deadlineMs);
    const diag = { layer: 'page', provider: null, status: null, ms: 0, results: 0, pages: 0 };
    const finish = result => { diag.ms = Date.now() - started; return { ...result, diag }; };
    try {
      const read = await readPage({ url, title: '' }, controller.signal);
      diag.pages = read ? 1 : 0;
      return finish(read ? { ok: true, sources: [read] } : { ok: false, code: controller.signal.aborted ? 'timeout' : 'unreadable' });
    } catch {
      return finish({ ok: false, code: 'failed' });
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
  import('./generated/extract.mjs').then(async ({ extractContent }) => {
    const fetcher = createFetcher({ search: searchDuckDuckGo, extract: extractContent });
    await serve(process.stdin, process.stdout, fetcher);
    process.exit(0);
  }, () => process.exit(1));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) startFromCommandLine();
