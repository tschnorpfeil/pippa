// The whole comparison: rounds × variants, interleaved (A,B,C,A,B,C,...). One block = one fresh llama-server for one
// variant: agentic dialogues (first one = cold), file search 6, tool choice 25. Finished blocks are skipped on restart.
//   CFFIXED_USER_HOME=<.../dist/model-compare-home> PIPPA_MC_SEARCH_HOME=<.../pippa/dist/tool-search-home> \
//   PIPPA_MC_LLAMA=<patched llama-server> node run-all.mjs <raw dir> [rounds=3] [variants=ABC]
import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { copyFile, mkdir, writeFile } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { VARIANTS, load1, serverArgs } from './variants.mjs';
import { startServer, stopServer } from './server.mjs';

const root = resolve(import.meta.dirname, '../../..');
const [rawDir, roundsArg = '3', variantsArg = 'ABC'] = process.argv.slice(2);
const bin = process.env.PIPPA_MC_LLAMA, payload = join(root, '.build/pi-payload');
if (!rawDir || !bin) throw Error('raw dir and PIPPA_MC_LLAMA required');
await mkdir(rawDir, { recursive: true });

function run(args, env = {}) {
 return new Promise((ok, fail) => spawn(process.execPath, args, { stdio: 'inherit', env: { ...process.env, ...env } })
  .on('exit', c => c === 0 ? ok() : fail(Error(`${args[0]} exit ${c}`))));
}

for (let round = 1; round <= Number(roundsArg); round++) {
 for (const name of variantsArg) {
  const v = VARIANTS[name], tag = `${name.toLowerCase()}-r${round}`;
  const blockFile = join(rawDir, `block-${tag}.json`);
  if (existsSync(blockFile)) { console.log(`skip ${tag} (done)`); continue; }
  const server = await startServer(bin, v, 18431, join(rawDir, `server-${tag}.log`));
  const block = { variant: name, round, model: v.key, thinking: v.thinking, note: v.note, serverArgs: serverArgs(v, server.port), loadSeconds: server.loadSeconds,
   startedAt: new Date().toISOString(), loadAvgStart: load1(), steps: {} };
  console.log(`== block ${tag}: server up in ${server.loadSeconds}s, load ${block.loadAvgStart}`);
  try {
   let t = Date.now();
   await run([join(import.meta.dirname, 'agentic.mjs'), payload, server.url, name, String(round), join(rawDir, `agentic-${tag}.json`)]);
   block.steps.agentic = (Date.now() - t) / 1000; block.footprintAfterAgentic = server.footprint();
   t = Date.now();
   await run([join(root, 'scripts/quality/tool-choice.mjs'), payload, server.url, `mc-${tag}-search`, 'tax', 'document', 'pdf', 'invoice', 'info', 'where'],
    { PIPPA_SEARCH_FLOW: '1', PIPPA_MC_VARIANT: name, HOME: process.env.PIPPA_MC_SEARCH_HOME, CFFIXED_USER_HOME: process.env.PIPPA_MC_SEARCH_HOME });
   await copyFile(join(root, `.build/tool-choice-mc-${tag}-search.json`), join(rawDir, `search-${tag}.json`));
   block.steps.search = (Date.now() - t) / 1000;
   t = Date.now();
   await run([join(root, 'scripts/quality/tool-choice.mjs'), payload, server.url, `mc-${tag}-choice`], { PIPPA_MC_VARIANT: name, PIPPA_SEARCH_FLOW: '' });
   await copyFile(join(root, `.build/tool-choice-mc-${tag}-choice.json`), join(rawDir, `choice-${tag}.json`));
   block.steps.choice = (Date.now() - t) / 1000;
  } finally {
   block.peakRSSMB = server.peakRSS; block.footprintEndMB = server.footprint(); block.peakFootprintMB = server.peakFootprint;
   block.loadAvgEnd = load1(); block.endedAt = new Date().toISOString();
   await stopServer(server);
  }
  await writeFile(blockFile, JSON.stringify(block, null, 1));
 }
}
console.log('all blocks done');
