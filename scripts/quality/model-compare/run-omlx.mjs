// Compare the installed oMLX model against Pippa's llama.cpp configuration.
// All agent tools are restricted to the synthetic corpus and deterministic mocks.
import { spawn, execFileSync } from 'node:child_process';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { resolve, join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { startServer, stopServer } from './server.mjs';
import { serverArgs } from './variants.mjs';

const root = resolve(import.meta.dirname, '../../..');
const [outArg, roundsArg = '3', ...taskIDs] = process.argv.slice(2);
if (!outArg || !process.env.PIPPA_MC_VARIANTS_FILE || !process.env.PIPPA_MC_LLAMA || !process.env.PIPPA_MC_API_KEY_FILE) throw Error('Output directory, variants, llama binary and oMLX key file required');
const out = resolve(outArg), payload = resolve(process.env.PIPPA_MC_PAYLOAD ?? '.build/pi-payload-1.4.0');
const base = process.env.PIPPA_MC_OMLX ?? 'http://127.0.0.1:8012';
const key = (await readFile(process.env.PIPPA_MC_API_KEY_FILE, 'utf8')).trim();
const variants = JSON.parse(await readFile(process.env.PIPPA_MC_VARIANTS_FILE, 'utf8'));
const sleep = ms => new Promise(ok => setTimeout(ok, ms));
await mkdir(out, { recursive: true });
async function api(path, method = 'GET') {
 const r = await fetch(base + path, { method, headers: { authorization: `Bearer ${key}` }, signal: AbortSignal.timeout(120000) });
 if (!r.ok) throw Error(`oMLX ${path}: ${r.status} ${await r.text()}`);
 return r.json();
}
async function idle() {
 for (let i = 0; i < 24; i++) {
  const s = await api('/api/status');
  if (!s.active_requests && !s.waiting_requests) return s;
  console.log(`Waiting for existing oMLX work (${s.active_requests} active, ${s.waiting_requests} queued)`);
  await sleep(5000);
 }
 throw Error('oMLX remained busy; no existing request was interrupted');
}
function machine() {
 const cmd = (bin, args) => execFileSync(bin, args, { encoding: 'utf8' }).trim();
 return { chip: cmd('/usr/sbin/sysctl', ['-n', 'machdep.cpu.brand_string']), memory: cmd('/usr/sbin/sysctl', ['-n', 'hw.memsize']),
  os: cmd('/usr/bin/sw_vers', []), load: cmd('/usr/sbin/sysctl', ['-n', 'vm.loadavg']), swap: cmd('/usr/sbin/sysctl', ['-n', 'vm.swapusage']) };
}
const initial = await idle();
const initialModels = await api('/v1/models/status');
const otherLoaded = initialModels.models.filter(m => m.loaded && m.id !== variants.L.key);
if (otherLoaded.length) throw Error('Another oMLX model is loaded; refusing to change its state');
const originallyLoaded = initialModels.models.find(m => m.id === variants.L.key)?.loaded;
const runID = randomUUID();
const meta = { runID, started: new Date().toISOString(), machine: machine(), omlx: initial, initialModels,
 piVersion: JSON.parse(await readFile(join(payload, 'release/node_modules/@earendil-works/pi-coding-agent/package.json'), 'utf8')).version,
 variants, rounds: Number(roundsArg), taskIDs, order: ['LMQ', 'MQL', 'QLM'],
 cacheProtocol: process.env.PIPPA_MC_OMIT_CACHE_TAG === '1' ? 'Diagnostic only: unmodified system prompt, existing cache reuse allowed; not pooled with the controlled timing matrix.' : 'Unique supplied-system-message prefix per block limits earlier task-context reuse; shared chat-template and tool prefixes can still be cached. Subsequent tasks share the block prefix. Models preloaded before task timing. No user cache is cleared.',
 outputBudget: 4096, taskTimeoutSeconds: Number(process.env.PIPPA_MC_TIMEOUT ?? 180000) / 1000 };
if (existsSync(join(out, '../metadata.json'))) meta.previousAttempt = JSON.parse(await readFile(join(out, '../metadata.json'), 'utf8'));
await writeFile(join(out, '../metadata.json'), JSON.stringify(meta, null, 2));
let server;
try {
 for (let round = 1; round <= Number(roundsArg); round++) for (const label of meta.order[(round - 1) % 3]) {
  await idle();
  const v = variants[label], tag = `${label.toLowerCase()}-r${round}`;
  if (existsSync(join(out, `block-${tag}.json`))) {
   const runs = JSON.parse(await readFile(join(out, `agentic-${tag}.json`), 'utf8'));
   if (runs.length !== (taskIDs.length || 10) || runs.some(r => r.httpErrors.length)) throw Error(`Invalid existing block ${tag}; quarantine it before resuming`);
   console.log(`KEEP completed block ${tag}`); continue;
  }
  let url = base;
  const block = { label, round, started: new Date().toISOString(), before: machine() };
  if (label === 'Q') {
   const status = await api('/v1/models/status');
   if (status.models.find(m => m.id === variants.L.key)?.loaded) await api(`/v1/models/${encodeURIComponent(variants.L.key)}/unload`, 'POST');
   server = await startServer(process.env.PIPPA_MC_LLAMA, v, 18431, join(out, `server-${tag}.log`));
   block.serverArgs = serverArgs(v, server.port); block.modelLoadSeconds = server.loadSeconds;
   url = server.url;
  } else {
   const start = Date.now();
   await api(`/v1/models/${encodeURIComponent(v.key)}/load`, 'POST');
   block.loadEndpointSeconds = (Date.now() - start) / 1000;
  }
  console.log(`START ${tag} ${new Date().toISOString()}`);
  const env = { ...process.env, CFFIXED_USER_HOME: join(root, 'dist/model-compare-home'),
   PIPPA_MC_CACHE_TAG: `${runID}-${tag}`, PIPPA_MC_TIMEOUT: process.env.PIPPA_MC_TIMEOUT ?? '180000' };
  if (process.env.PIPPA_MC_OMIT_CACHE_TAG === '1') delete env.PIPPA_MC_CACHE_TAG;
  if (label === 'Q') delete env.PIPPA_MC_API_KEY_FILE;
  try {
   await new Promise((ok, fail) => {
    const p = spawn(process.execPath, [join(import.meta.dirname, 'agentic.mjs'), payload, url, label, String(round), join(out, `agentic-${tag}.json`), ...taskIDs], { env, stdio: 'inherit' });
    p.on('error', fail); p.on('exit', c => c === 0 ? ok() : fail(Error(`Agent harness exited ${c}`)));
   });
  } finally {
   if (server) { block.peakServerRSSMB = server.peakRSS; await stopServer(server); server = undefined; }
  }
  block.after = machine(); block.ended = new Date().toISOString();
  await writeFile(join(out, `block-${tag}.json`), JSON.stringify(block, null, 2));
 }
 meta.completed = new Date().toISOString();
} finally {
 if (server) await stopServer(server);
 await idle();
 const status = await api('/v1/models/status');
 const loaded = status.models.find(m => m.id === variants.L.key)?.loaded;
 if (originallyLoaded && !loaded) await api(`/v1/models/${encodeURIComponent(variants.L.key)}/load`, 'POST');
 if (!originallyLoaded && loaded) await api(`/v1/models/${encodeURIComponent(variants.L.key)}/unload`, 'POST');
 meta.finalMachine = machine();
 await writeFile(join(out, '../metadata.json'), JSON.stringify(meta, null, 2));
}
