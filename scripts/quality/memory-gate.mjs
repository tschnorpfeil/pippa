#!/usr/bin/env node
// Release memory gate: a 5-turn script (one file read, one search) against an ALREADY RUNNING Pippa/Pi setup.
// Samples the peak llama-server footprint, the vm.swapusage delta and the maximum memory-pressure level, and
// writes docs/measurements/release-candidate-<version>-<date>.md.
// Gate: swap growth <= 256 MiB and the pressure level never critical.
//
// It does nothing heavy unless --run is given. Usage:
//   node memory-gate.mjs --run --version 0.3.18 [--pi "<cmd>"] [--cwd <dir>] [--out <dir>]
// WARNING: --run loads the Mac heavily (model inference plus a file read and a search). Use a dedicated test Mac.
import { spawn, execFileSync } from 'node:child_process';
import { writeFileSync, mkdirSync, mkdtempSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

export const SWAP_LIMIT_MIB = 256;
export const PRESSURE_NAMES = { 1: 'normal', 2: 'warning', 4: 'critical' };

/** "total = 2048.00M  used = 512.25M  free = 1535.75M  (encrypted)" -> used MiB (vm.swapusage reports MB = MiB). */
export function parseSwapUsedMiB(text) {
 const m = String(text).match(/used\s*=\s*([\d.]+)\s*([KMGT])/i);
 if (!m) return null;
 return Number(m[1]) * { K: 1 / 1024, M: 1, G: 1024, T: 1024 * 1024 }[m[2].toUpperCase()];
}

/** kern.memorystatus_vm_pressure_level prints a bare integer: 1 normal, 2 warning, 4 critical. */
export function parsePressure(text) {
 const n = Number.parseInt(String(text).trim(), 10);
 return Number.isFinite(n) ? n : null;
}

/** footprint(1) output ("Footprint: 5.2 GB") -> MiB. */
export function parseFootprintMiB(text) {
 const m = String(text).match(/Footprint:\s*([\d.]+)\s*([KMG]B)/);
 if (!m) return null;
 return Number(m[1]) * { KB: 1 / 1024, MB: 1, GB: 1024 }[m[2]];
}

/** Fold samples ({footprintMiB, swapUsedMiB, pressure}) into peak, swap delta and maximum pressure. */
export function summarizeSamples(samples) {
 const valid = k => samples.map(s => s[k]).filter(v => v != null);
 const swap = valid('swapUsedMiB'), fp = valid('footprintMiB'), pr = valid('pressure');
 return {
  samples: samples.length,
  peakFootprintMiB: fp.length ? Math.max(...fp) : null,
  swapStartMiB: swap.length ? swap[0] : null,
  swapEndMiB: swap.length ? swap.at(-1) : null,
  swapPeakMiB: swap.length ? Math.max(...swap) : null,
  // Growth is measured against the start, at the highest point reached (swap that came back down still counted).
  swapGrowthMiB: swap.length ? Math.max(...swap) - swap[0] : null,
  maxPressure: pr.length ? Math.max(...pr) : null,
 };
}

/** The gate. Missing measurements fail: an unmeasured gate is not a pass. */
export function evaluateGate(summary, limitMiB = SWAP_LIMIT_MIB) {
 const checks = [
  { name: `swap growth <= ${limitMiB} MiB`, ok: summary.swapGrowthMiB != null && summary.swapGrowthMiB <= limitMiB },
  { name: 'memory pressure never critical', ok: summary.maxPressure != null && summary.maxPressure < 4 },
  { name: 'llama-server footprint measured', ok: summary.peakFootprintMiB != null },
 ];
 return { pass: checks.every(c => c.ok), checks };
}

const fmt = (x, d = 0) => (x == null ? 'n/a' : x.toFixed(d));

export function renderReport({ version, date, host, summary, gate, turns }) {
 const lines = [
  `# Pippa ${version} release candidate: memory gate`,
  '',
  `Measured ${date}${host ? ` on ${host}` : ''}. A 5-turn script (one file read, one search) ran against an already running Pippa/Pi setup.`,
  '',
  `**Result: ${gate.pass ? 'PASS' : 'FAIL'}**`,
  '',
  '| Check | Result |', '| --- | --- |',
  ...gate.checks.map(c => `| ${c.name} | ${c.ok ? 'pass' : 'FAIL'} |`),
  '',
  '| Measurement | Value |', '| --- | --- |',
  `| Peak llama-server footprint | ${fmt(summary.peakFootprintMiB)} MiB |`,
  `| Swap used at start / end / peak | ${fmt(summary.swapStartMiB)} / ${fmt(summary.swapEndMiB)} / ${fmt(summary.swapPeakMiB)} MiB |`,
  `| Swap growth | ${fmt(summary.swapGrowthMiB)} MiB (limit ${SWAP_LIMIT_MIB}) |`,
  `| Maximum pressure level | ${summary.maxPressure == null ? 'n/a' : `${summary.maxPressure} (${PRESSURE_NAMES[summary.maxPressure] ?? 'unknown'})`} |`,
  `| Samples | ${summary.samples} |`,
 ];
 if (turns?.length) {
  lines.push('', '| Turn | Prompt | Seconds | Settled |', '| --- | --- | --- | --- |',
   ...turns.map((t, i) => `| ${i + 1} | ${t.label} | ${fmt(t.seconds, 1)} | ${t.settled ? 'yes' : 'NO'} |`));
 }
 return lines.join('\n') + '\n';
}

export function reportFileName(version, date) { return `release-candidate-${version}-${date}.md`; }

/** The fixed script. The file and the folder are created by the runner, so the answers are checkable by hand. */
export function turnScript(dir) {
 return [
  { label: 'greeting', message: 'Hallo, bist du bereit?' },
  { label: 'file read', message: `Lies die Datei ${join(dir, 'brief.txt')} und fasse sie in zwei Sätzen zusammen.` },
  { label: 'follow-up', message: 'Welche Zahl steht darin als Betrag?' },
  { label: 'search', message: `Suche in ${dir} nach Dateien, die das Wort "Rechnung" enthalten, und nenne die Treffer.` },
  { label: 'follow-up', message: 'Fasse in einem Satz zusammen, was du gefunden hast.' },
 ];
}

// ---- everything below touches the machine; only reached with --run ----

const sh = (bin, args, timeout = 20000) => execFileSync(bin, args, { encoding: 'utf8', timeout });
const sleep = ms => new Promise(r => setTimeout(r, ms));

function llamaPid() {
 let out = '';
 try { out = sh('/usr/bin/pgrep', ['-x', 'llama-server']).trim(); } catch {}
 const pids = out.split('\n').filter(Boolean);
 if (pids.length !== 1) throw Error(`expected exactly one running llama-server, found ${pids.length}`);
 return Number(pids[0]);
}

function sample(pid) {
 const safe = f => { try { return f(); } catch { return null; } };
 return {
  footprintMiB: safe(() => parseFootprintMiB(sh('/usr/bin/footprint', ['-p', String(pid)]))),
  swapUsedMiB: safe(() => parseSwapUsedMiB(sh('/usr/sbin/sysctl', ['-n', 'vm.swapusage']))),
  pressure: safe(() => parsePressure(sh('/usr/sbin/sysctl', ['-n', 'kern.memorystatus_vm_pressure_level']))),
 };
}

/** One turn over Pi's RPC protocol (JSON lines; same shape model-compare/agentic.mjs uses). */
function runTurns(child, turns, timeoutMs) {
 const results = [];
 let buffer = '', resolveTurn = null;
 child.stdout.on('data', d => {
  buffer += d; let n;
  while ((n = buffer.indexOf('\n')) >= 0) {
   const line = buffer.slice(0, n); buffer = buffer.slice(n + 1);
   let e; try { e = JSON.parse(line); } catch { continue; }
   if (e.type === 'extension_ui_request' && ['select', 'confirm'].includes(e.method))
    child.stdin.write(JSON.stringify({ type: 'extension_ui_response', id: e.id, ...(e.method === 'confirm' ? { confirmed: true } : { value: e.options[0] }) }) + '\n');
   if (e.type === 'agent_settled' && resolveTurn) resolveTurn(true);
  }
 });
 return (async () => {
  for (const t of turns) {
   const t0 = Date.now();
   const settled = await new Promise(res => {
    const timer = setTimeout(() => res(false), timeoutMs);
    resolveTurn = ok => { clearTimeout(timer); res(ok); };
    child.stdin.write(JSON.stringify({ type: 'prompt', message: t.message }) + '\n');
   });
   results.push({ label: t.label, seconds: (Date.now() - t0) / 1000, settled });
   if (!settled) break;
  }
  return results;
 })();
}

export function parseArgs(argv) {
 const a = { run: false, version: null, pi: 'pi --mode rpc --provider pippa-local', cwd: null, out: null, turnTimeoutS: 600 };
 for (let i = 0; i < argv.length; i++) {
  const k = argv[i];
  if (k === '--run') a.run = true;
  else if (k === '--version') a.version = argv[++i];
  else if (k === '--pi') a.pi = argv[++i];
  else if (k === '--cwd') a.cwd = argv[++i];
  else if (k === '--out') a.out = argv[++i];
  else if (k === '--turn-timeout') a.turnTimeoutS = Number(argv[++i]);
  else throw Error(`unknown argument ${k}`);
 }
 return a;
}

export const WARNING = 'WARNING: --run loads this Mac heavily (model inference, file read, search, memory sampling). Run it only on a dedicated test Mac, with nothing else open.';

async function main() {
 const args = parseArgs(process.argv.slice(2));
 if (!args.run) {
  console.log(WARNING);
  console.log('Nothing was done. Pass --run --version <x.y.z> to execute the 5-turn gate against the running llama-server.');
  return;
 }
 console.error(WARNING);
 if (!args.version) throw Error('--version is required with --run');
 const pid = llamaPid();
 const dir = mkdtempSync(join(tmpdir(), 'pippa-memory-gate-'));
 writeFileSync(join(dir, 'brief.txt'), 'Rechnung Nr. 4711 vom 3. Oktober. Betrag: 84,20 Euro. Bitte bis zum 17. Oktober überweisen.\n');
 writeFileSync(join(dir, 'other.txt'), 'Nichts Wichtiges hier.\n');
 const samples = [sample(pid)];
 const timer = setInterval(() => samples.push(sample(pid)), 2000);
 const [bin, ...piArgs] = args.pi.split(/\s+/).filter(Boolean);
 const child = spawn(bin, piArgs, { cwd: args.cwd ?? dir, stdio: ['pipe', 'pipe', 'inherit'] });
 let turns;
 try { turns = await runTurns(child, turnScript(dir), args.turnTimeoutS * 1000); }
 finally { child.kill(); clearInterval(timer); }
 await sleep(2000);
 samples.push(sample(pid));
 const summary = summarizeSamples(samples);
 const gate = evaluateGate(summary);
 if (turns.length < 5 || turns.some(t => !t.settled)) gate.pass = false, gate.checks.push({ name: 'all 5 turns settled', ok: false });
 const date = new Date().toISOString().slice(0, 10);
 const outDir = args.out ?? join(import.meta.dirname, '..', '..', 'docs', 'measurements');
 mkdirSync(outDir, { recursive: true });
 const file = join(outDir, reportFileName(args.version, date));
 writeFileSync(file, renderReport({ version: args.version, date, host: sh('/usr/sbin/sysctl', ['-n', 'hw.model']).trim(), summary, gate, turns }));
 console.log(`${gate.pass ? 'PASS' : 'FAIL'}: ${file}`);
 process.exitCode = gate.pass ? 0 : 1;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) main().catch(e => { console.error(e.message); process.exit(2); });
