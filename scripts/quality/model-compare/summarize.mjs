// Summary of the raw comparison data: median and range per variant.
//   node summarize.mjs <measurement dir>   (reads raw/*.json, raw/r7-*.log, grades.json, blind-grades.json if present)
// Writes summary.json and summary.md, and (once) answers-blind.md + blind-key.json for blind German grading.
import { readFile, readdir, writeFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { join } from 'node:path';

const dir = process.argv[2];
const raw = join(dir, 'raw');
const files = await readdir(raw);
const load = async f => JSON.parse(await readFile(join(raw, f)));
const opt = async f => existsSync(join(dir, f)) ? JSON.parse(await readFile(join(dir, f))) : {};
const grades = await opt('grades.json');           // manual: { "<variant>-r<round>-<task>": { grade, invented, note } }
// Blind language rating (blind-ratings.json, labels X/Y/Z) mapped back with blind-key.json. Mean over all answers and
// over the German questions only.
const blindRatings = await opt('blind-ratings.json'), blindKey = await opt('blind-key.json');
const blindGrades = { byVariant: {} };
for (const [label, rating] of Object.entries(blindRatings)) {
 const v = blindKey[label]; if (!v) continue;
 const b = blindGrades.byVariant[v] ??= { scores: [], german: [] };
 b.scores.push(rating.score); if (!label.startsWith('en-')) b.german.push(rating.score);
}
for (const b of Object.values(blindGrades.byVariant)) {
 const mean = a => a.reduce((x, y) => x + y, 0) / a.length;
 Object.assign(b, { mean: mean(b.scores), n: b.scores.length, germanMean: mean(b.german), germanN: b.german.length });
}
const V = ['A', 'B', 'C'];

const median = a => { const s = a.filter(x => x != null).sort((x, y) => x - y); if (!s.length) return null; const m = s.length >> 1; return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2; };
const range = a => { const s = a.filter(x => x != null); return s.length ? [Math.min(...s), Math.max(...s)] : null; };
const stat = a => ({ median: median(a), range: range(a), n: a.filter(x => x != null).length });
const fmt = (s, d = 1) => s?.median == null ? '–' : `${s.median.toFixed(d)} (${s.range[0].toFixed(d)}–${s.range[1].toFixed(d)})`;

const agentic = [], search = [], choice = [], blocks = [];
for (const f of files.sort()) {
 if (f.startsWith('agentic-') && !f.includes('-payload')) agentic.push(...(await load(f)).map((r, i) => ({ ...r, cold: i === 0 })));
 else if (f.startsWith('search-')) search.push({ file: f, variant: f[7].toUpperCase(), round: Number(f.match(/-r(\d)/)[1]), results: await load(f) });
 else if (f.startsWith('choice-')) choice.push({ file: f, variant: f[7].toUpperCase(), round: Number(f.match(/-r(\d)/)[1]), results: await load(f) });
 else if (f.startsWith('block-')) blocks.push(await load(f));
}
for (const r of agentic) {
 const key = `${r.variant}-r${r.round}-${r.task}`;
 r.key = key;
 r.grade = grades[key]?.grade ?? r.autoGrade;
 r.invented = grades[key]?.invented ?? null;
}

// r7 latency logs: "= R7LAT <case> <on|off> r<n>: first word <ms> ms ... total <ms> ms, tools [...]"
const r7 = {};
for (const f of files.filter(f => /^r7-[abc]\.log$/.test(f))) {
 const v = f[3].toUpperCase();
 const lines = (await readFile(join(raw, f), 'utf8')).split('\n').filter(l => l.includes('= R7LAT'));
 r7[v] = lines.map(l => ({ firstWord: Number(l.match(/first word (\d+) ms/)[1]) / 1000, total: Number(l.match(/total (\d+) ms/)[1]) / 1000,
  tools: l.match(/tools (\[[^\]]*\])/)?.[1] }));
}

const summary = { variants: {} };
for (const v of V) {
 const runs = agentic.filter(r => r.variant === v);
 if (!runs.length) continue;
 const count = g => runs.filter(r => r.grade === g).length;
 const perTask = {};
 for (const r of runs) (perTask[r.task] ??= []).push(r.grade);
 const vb = blocks.filter(b => b.variant === v);
 const s = search.filter(x => x.variant === v), c = choice.filter(x => x.variant === v);
 summary.variants[v] = {
  model: runs[0].model, thinking: runs[0].thinking, agenticRuns: runs.length,
  success: { yes: count('yes'), partial: count('partial'), no: count('no') }, perTask,
  // Loop/runaway: Pippa's loop stop, an abort/timeout, or the last turn cut by the token limit.
  loopsOrAborts: runs.filter(r => r.loopStopped || r.aborted || r.stopReasons.at(-1) === 'length').map(r => `${r.key}: ${r.loopStopped ? 'loop-stop' : r.aborted ?? 'token limit after ' + r.toolCalls + ' tool calls'}`),
  httpErrors: runs.flatMap(r => r.httpErrors.map(e => `${r.key}: ${e.status} ${String(e.error).slice(0, 120)}`)),
  invented: runs.filter(r => r.invented === true).map(r => r.key),
  toolCalls: stat(runs.map(r => r.toolCalls)),
  firstWordCold: stat(runs.filter(r => r.cold).map(r => r.firstWordSeconds)),
  firstWordWarm: stat(runs.filter(r => !r.cold).map(r => r.firstWordSeconds)),
  totalCold: stat(runs.filter(r => r.cold).map(r => r.totalSeconds)),
  totalWarm: stat(runs.filter(r => !r.cold).map(r => r.totalSeconds)),
  total: stat(runs.map(r => r.totalSeconds)),
  serverLoad: stat(vb.map(b => b.loadSeconds)),
  serverPeakRSSMB: stat(vb.map(b => b.peakRSSMB)), serverFootprintMB: stat(vb.map(b => b.peakFootprintMB)),
  piPeakRSSMB: stat(runs.map(r => r.piPeakRSSMB)),
  search6: s.map(x => x.results.filter(r => r.ok).length), searchSeconds: stat(s.flatMap(x => x.results.map(r => r.seconds))),
  choice25: c.map(x => x.results.filter(r => r.ok).length), choiceFails: c.flatMap(x => x.results.filter(r => !r.ok).map(r => `r${x.round} ${r.id}: ${r.choices[0]?.name ?? 'answer'}`)),
  r7FirstWord: stat((r7[v] ?? []).map(x => x.firstWord)), r7Total: stat((r7[v] ?? []).map(x => x.total)), r7Runs: (r7[v] ?? []).length,
  germanBlind: blindGrades.byVariant?.[v] ?? null,
 };
}

// Decision rule (fixed in advance, README.md). Compared: each Qwen variant against A.
const A = summary.variants.A;
summary.decision = {};
for (const v of ['B', 'C']) {
 const q = summary.variants[v];
 if (!A || !q) continue;
 const success = q.success.yes >= A.success.yes - 1;
 const loops = q.loopsOrAborts.length <= A.loopsOrAborts.length;
 const german = q.germanBlind == null || A.germanBlind == null ? null : q.germanBlind.germanMean >= A.germanBlind.germanMean;
 const time = q.total.median <= A.total.median * 1.2;
 summary.decision[v] = { successAtLeastK2MinusOne: success, noNewLoops: loops, germanBlindAtLeastK2: german, totalTimeWithin20Percent: time,
  qwenBecomesDefault: success && loops && german === true && time };
}

const rows = [
 ['Agentic success yes/partial/no', v => `${v.success.yes}/${v.success.partial}/${v.success.no} of ${v.agenticRuns}`],
 ['Loops / aborts', v => String(v.loopsOrAborts.length)],
 ['HTTP errors (template)', v => String(v.httpErrors.length)],
 ['Invented facts (manual)', v => String(v.invented.length)],
 ['Tool calls per task', v => fmt(v.toolCalls, 0)],
 ['First word cold, s', v => fmt(v.firstWordCold)],
 ['First word warm, s', v => fmt(v.firstWordWarm)],
 ['Total per task warm, s', v => fmt(v.totalWarm)],
 ['Total per task all, s', v => fmt(v.total)],
 ['Server load, s', v => fmt(v.serverLoad)],
 ['llama-server peak RSS, MB', v => fmt(v.serverPeakRSSMB, 0)],
 ['llama-server footprint, MB', v => fmt(v.serverFootprintMB, 0)],
 ['Pi peak RSS, MB', v => fmt(v.piPeakRSSMB, 0)],
 ['File search 6 (per round)', v => v.search6.join(' / ')],
 ['Tool choice 25 (per round)', v => v.choice25.join(' / ')],
 ['r7 first word, s', v => fmt(v.r7FirstWord)],
 ['r7 total, s', v => fmt(v.r7Total)],
 ['Blind language rating, German questions (1–5)', v => v.germanBlind ? `${v.germanBlind.germanMean.toFixed(2)} (n ${v.germanBlind.germanN})` : '–'],
 ['Blind language rating, all incl. English (1–5)', v => v.germanBlind ? `${v.germanBlind.mean.toFixed(2)} (n ${v.germanBlind.n})` : '–'],
];
const present = V.filter(v => summary.variants[v]);
let md = `| Metric | ${present.map(v => `${v} ${summary.variants[v].model} ${summary.variants[v].thinking}`).join(' | ')} |\n|---|${present.map(() => '---').join('|')}|\n`;
for (const [label, f] of rows) md += `| ${label} | ${present.map(v => f(summary.variants[v])).join(' | ')} |\n`;
md += `\nPer task (yes/partial/no over rounds):\n\n| Task | ${present.join(' | ')} |\n|---|${present.map(() => '---').join('|')}|\n`;
const taskIds = [...new Set(agentic.map(r => r.task))];
for (const t of taskIds) md += `| ${t} | ${present.map(v => (summary.variants[v].perTask[t] ?? []).map(g => ({ yes: '✓', partial: '~', no: '✗' })[g]).join(' ')).join(' | ')} |\n`;
await writeFile(join(dir, 'summary.json'), JSON.stringify(summary, null, 1));
await writeFile(join(dir, 'summary.md'), md);
console.log(md);
console.log(JSON.stringify(summary.decision, null, 1));

// Blind answers: per task and round, the three variants' final answers under shuffled labels X/Y/Z. Key kept separately.
if (!existsSync(join(dir, 'blind-key.json')) && present.length === 3) {
 const key = {}; let out = '# Antworten für die Blindbewertung\n\nJe Aufgabe und Runde drei Antworten (X, Y, Z), Reihenfolge zufällig. Bewertet wird nur die Sprache (Deutsch bzw. Englisch): verständlich, natürlich, freundlich, fehlerfrei, angemessen kurz. 1 = schlecht … 5 = sehr gut.\n';
 const rand = (() => { let s = 20261009; return () => (s = (s * 1103515245 + 12345) % 2147483648) / 2147483648; })();
 for (const t of taskIds) for (const round of [1, 2, 3]) {
  const set = present.map(v => agentic.find(r => r.variant === v && r.task === t && r.round === round)).filter(Boolean);
  if (set.length !== 3) continue;
  const order = set.map(r => [rand(), r]).sort((a, b) => a[0] - b[0]).map(x => x[1]);
  out += `\n## ${t} · Runde ${round}\n\nFrage: ${set[0].prompt.split('\n').at(-1)}\n`;
  order.forEach((r, i) => { const label = 'XYZ'[i]; key[`${t}-r${round}-${label}`] = r.variant; out += `\n### ${label}\n\n${(r.finalAnswer || '(keine Antwort)').replace(/\/Users\/[^\s)]*\/dist\/model-compare-home/g, '~')}\n`; });
 }
 await writeFile(join(dir, 'answers-blind.md'), out);
 await writeFile(join(dir, 'blind-key.json'), JSON.stringify(key, null, 1));
}
