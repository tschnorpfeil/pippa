// Start one server for a variant, run agentic.mjs for the given tasks, stop the server (smoke tests, single runs).
//   node one.mjs <variant> <out.json> [task ids...]
import { spawn } from 'node:child_process';
import { resolve, join } from 'node:path';
import { VARIANTS } from './variants.mjs';
import { startServer, stopServer } from './server.mjs';
const root = resolve(import.meta.dirname, '../../..');
const [name, out, ...ids] = process.argv.slice(2);
const bin = process.env.PIPPA_MC_LLAMA;
const server = await startServer(bin, VARIANTS[name], 18431, out.replace(/\.json$/, '-server.log'));
console.log(`server ${name} up in ${server.loadSeconds}s`);
try {
 await new Promise((ok, fail) => spawn(process.execPath, [join(import.meta.dirname, 'agentic.mjs'), join(root, '.build/pi-payload'), server.url, name, '0', out, ...ids], { stdio: 'inherit' })
  .on('exit', c => c === 0 ? ok() : fail(Error('agentic exit ' + c))));
} finally { console.log(`peak RSS ${server.peakRSS} MB, footprint ${server.footprint()} MB`); await stopServer(server); }
