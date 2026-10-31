#!/usr/bin/env node
// Cache telemetry: per request, uncached vs cached prompt tokens, prefill seconds and cache divergences.
// Numbers only. Reads a Pi session JSONL (usage.input / usage.cacheRead) and optionally llama-server-pi.log
// (llama.cpp slot selection, prompt eval timing and slot release lines).
// Usage: node cache-report.mjs <session.jsonl> [llama-server-pi.log]
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

/** Extract assistant usage records from Pi session JSONL text. Bad lines are skipped. */
export function parseSession(text) {
 const out = [];
 for (const line of text.split('\n')) {
  if (!line.trim()) continue;
  let entry; try { entry = JSON.parse(line); } catch { continue; }
  const m = entry?.message;
  if (!m || m.role !== 'assistant' || !m.usage) continue;
  const u = m.usage;
  out.push({ uncached: Number(u.input) || 0, cached: Number(u.cacheRead) || 0, output: Number(u.output) || 0, durationMs: m.durationMs ?? null });
 }
 return out;
}

/** Add per-request prompt size and the number of previously cached tokens that were lost (session view). */
export function sessionRows(usages) {
 let prevPrompt = 0;
 return usages.map((u, i) => {
  const prompt = u.uncached + u.cached;
  // Everything the previous request had in its prompt should be a prefix of this one.
  const lost = i === 0 ? 0 : Math.max(0, prevPrompt - u.cached);
  prevPrompt = prompt;
  return { ...u, prompt, hitRate: prompt ? u.cached / prompt : 0, lostTokens: lost };
 });
}

/** Parse llama.cpp server log text into one record per request (selection -> launch -> timing -> release). */
export function parseLlamaLog(text) {
 const reqs = [];
 let cur = null;
 for (const line of text.split('\n')) {
  let m;
  if ((m = line.match(/get_availabl:.*selected slot by (LRU|LCP similarity)(?:.*f_sim_best = ([\d.]+))?(?:.*f_keep = ([\d.]+))?/))) {
   cur = { select: m[1] === 'LRU' ? 'lru' : 'lcp', simBest: m[2] != null ? Number(m[2]) : null, keep: m[3] != null ? Number(m[3]) : null, task: null, promptTokens: null, prefillSeconds: null, nTokensAfter: null };
   reqs.push(cur);
  } else if (cur && (m = line.match(/launch_slot_:.*\| task (\d+) \|/))) {
   cur.task = Number(m[1]);
  } else if (cur && (m = line.match(/print_timing:.*\| task (\d+) \| prompt eval time =\s*([\d.]+) ms \/\s*(\d+) tokens/))) {
   cur.prefillSeconds = Number(m[2]) / 1000;
   cur.promptTokens = Number(m[3]);
  } else if (cur && (m = line.match(/slot\s+release:.*n_tokens = (\d+)/))) {
   cur.nTokensAfter = Number(m[1]);
  }
 }
 // A request without a timing line never finished (aborted); keep it, it still shows the selection.
 return reqs;
}

/** True when llama.cpp had to discard part of the cached slot (or started cold) instead of extending it. */
export function isDivergence(req, index) {
 if (req.select === 'lru') return index > 0 || req.keep != null;
 return req.keep != null && req.keep < 0.99;
}

/** Join session rows and log requests. The log may start earlier than the session, so align from the end. */
export function joinRows(rows, reqs) {
 const offset = reqs.length - rows.length;
 return rows.map((r, i) => {
  const l = offset + i >= 0 ? reqs[offset + i] : null;
  const idx = offset + i;
  return { n: i + 1, ...r, log: l ? { ...l, divergence: isDivergence(l, idx) } : null };
 });
}

const f = (x, d = 1) => (x == null ? '-' : x.toFixed(d));

export function formatReport(joined, { hasLog }) {
 const head = ['#', 'uncached', 'cached', 'hit%', 'lost', ...(hasLog ? ['log_proc', 'prefill_s', 'sim_best', 'keep', 'diverged'] : [])];
 const lines = [head.join('\t')];
 let un = 0, ca = 0, pre = 0, div = 0;
 for (const r of joined) {
  un += r.uncached; ca += r.cached;
  const cols = [r.n, r.uncached, r.cached, f(r.hitRate * 100, 0), r.lostTokens];
  if (hasLog) {
   const l = r.log;
   if (l) { pre += l.prefillSeconds ?? 0; if (l.divergence) div++; }
   cols.push(l?.promptTokens ?? '-', f(l?.prefillSeconds, 2), f(l?.simBest, 3), f(l?.keep, 3), l ? (l.divergence ? 1 : 0) : '-');
  }
  lines.push(cols.join('\t'));
 }
 const total = un + ca;
 lines.push(['total', un, ca, f(total ? ca / total * 100 : 0, 0), joined.reduce((s, r) => s + r.lostTokens, 0), ...(hasLog ? ['-', f(pre, 2), '-', '-', div] : [])].join('\t'));
 return lines.join('\n');
}

export function report(sessionText, logText) {
 const rows = sessionRows(parseSession(sessionText));
 const reqs = logText == null ? [] : parseLlamaLog(logText);
 return formatReport(joinRows(rows, reqs), { hasLog: logText != null });
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
 const [session, log] = process.argv.slice(2);
 if (!session) { console.error('usage: node cache-report.mjs <session.jsonl> [llama-server-pi.log]'); process.exit(2); }
 console.log(report(readFileSync(session, 'utf8'), log ? readFileSync(log, 'utf8') : null));
}
