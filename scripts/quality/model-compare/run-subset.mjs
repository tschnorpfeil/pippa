// Agentic tasks only, chosen variants and tasks, rounds interleaved (A,B,A,B,...). One fresh llama-server per block.
// Before the first block the Mac must be free for PIPPA_MC_QUIET_MINUTES (default 10): no llama-server, no Pippa test
// process, load < 10 (other threads' tests use this Mac too).
//   CFFIXED_USER_HOME=<.../dist/model-compare-home> PIPPA_MC_LLAMA=<patched llama-server> \
//   node run-subset.mjs <raw dir> <rounds> <variants e.g. AB> <task ids...>
import { spawn, execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { mkdir, writeFile } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { VARIANTS, load1, serverArgs } from './variants.mjs';
import { startServer, stopServer } from './server.mjs';

const root = resolve(import.meta.dirname, '../../..');
const [rawDir, rounds, variants, ...tasks] = process.argv.slice(2);
const bin = process.env.PIPPA_MC_LLAMA, payload = join(root, '.build/pi-payload');
if (!rawDir || !bin || !tasks.length) throw Error('raw dir, rounds, variants, tasks and PIPPA_MC_LLAMA required');
await mkdir(rawDir, { recursive: true });

function busy() {
 const found = [];
 for (const name of ['llama-server', 'Pippa', 'PippaChecks', 'PippaLive', 'PiRPCR2Spike', 'PiRPCR3Spike']) {
  try { found.push(execFileSync('/usr/bin/pgrep', ['-lx', name], { encoding: 'utf8' }).trim()); } catch {}
 }
 if (load1() >= 10) found.push(`load ${load1()}`);
 return found.join(' | ');
}
const quiet = Number(process.env.PIPPA_MC_QUIET_MINUTES ?? 10) * 60000;
for (let since = Date.now(); ;) {
 const b = busy();
 if (b) { console.log(`${new Date().toISOString()} Mac busy: ${b.replace(/\n/g, ' ')}`); since = Date.now(); }
 else if (Date.now() - since >= quiet) break;
 await new Promise(r => setTimeout(r, 30000));
}
console.log(`${new Date().toISOString()} Mac free, starting`);

const run = args => new Promise((ok, fail) => spawn(process.execPath, args, { stdio: 'inherit' }).on('exit', c => c === 0 ? ok() : fail(Error('exit ' + c))));
for (let round = 1; round <= Number(rounds); round++) {
 for (const name of variants) {
  const tag = `${name.toLowerCase()}-r${round}`, blockFile = join(rawDir, `block-${tag}.json`);
  if (existsSync(blockFile)) continue;
  const v = VARIANTS[name];
  const server = await startServer(bin, v, 18431, join(rawDir, `server-${tag}.log`));
  const block = { variant: name, round, model: v.key, thinking: v.thinking, serverArgs: serverArgs(v, server.port), loadSeconds: server.loadSeconds, startedAt: new Date().toISOString(), loadAvgStart: load1() };
  try { await run([join(import.meta.dirname, 'agentic.mjs'), payload, server.url, name, String(round), join(rawDir, `agentic-${tag}.json`), ...tasks]); }
  finally { block.peakRSSMB = server.peakRSS; block.footprintEndMB = server.footprint(); block.endedAt = new Date().toISOString(); await stopServer(server); }
  await writeFile(blockFile, JSON.stringify(block, null, 1));
 }
}
console.log('all blocks done');
