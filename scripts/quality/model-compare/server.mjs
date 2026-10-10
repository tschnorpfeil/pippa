// Exactly one llama-server, started and stopped by this harness only. Before starting: no other llama-server on the
// Mac (other project threads use it too) and load < 10, otherwise wait. Never kills a process it did not start.
import { spawn, execFileSync } from 'node:child_process';
import { createWriteStream } from 'node:fs';
import { serverArgs, load1 } from './variants.mjs';

const sleep = ms => new Promise(r => setTimeout(r, ms));

function otherServers() {
 try { return execFileSync('/usr/bin/pgrep', ['-lx', 'llama-server'], { encoding: 'utf8' }).trim(); } catch { return ''; }
}

export function rssMB(pid) {
 try { return Math.round(Number(execFileSync('/bin/ps', ['-o', 'rss=', '-p', String(pid)], { encoding: 'utf8' }).trim()) / 1024); } catch { return 0; }
}

/** phys_footprint in MB (includes Metal buffers that RSS does not show). */
export function footprintMB(pid) {
 try {
  const out = execFileSync('/usr/bin/footprint', ['-p', String(pid)], { encoding: 'utf8', timeout: 20000 });
  const m = out.match(/Footprint:\s*([\d.]+)\s*([KMG]B)/);
  if (!m) return 0;
  return Math.round(Number(m[1]) * { KB: 1 / 1024, MB: 1, GB: 1024 }[m[2]]);
 } catch { return 0; }
}

export async function waitForMac(log = console.log) {
 for (let i = 0; ; i++) {
  const others = otherServers();
  const load = load1();
  if (!others && load < 10) return load;
  log(`waiting: ${others ? 'another llama-server runs: ' + others.replace(/\n/g, ' | ') : ''} load ${load}`);
  await sleep(60000);
 }
}

export async function startServer(bin, variant, port, logFile) {
 await waitForMac();
 const t0 = Date.now();
 const out = createWriteStream(logFile);
 const child = spawn(bin, serverArgs(variant, port), { stdio: ['ignore', 'pipe', 'pipe'] });
 child.stdout.pipe(out); child.stderr.pipe(out);
 let exited = false; child.on('exit', () => { exited = true; });
 for (;;) {
  if (exited) throw Error(`llama-server exited during start, see ${logFile}`);
  try { if ((await fetch(`http://127.0.0.1:${port}/health`)).ok) break; } catch {}
  await sleep(250);
 }
 const server = { child, port, url: `http://127.0.0.1:${port}`, loadSeconds: (Date.now() - t0) / 1000, peakRSS: 0, peakFootprint: 0 };
 server.sampler = setInterval(() => { server.peakRSS = Math.max(server.peakRSS, rssMB(child.pid)); }, 500);
 server.footprint = () => { const f = footprintMB(child.pid); server.peakFootprint = Math.max(server.peakFootprint, f); return f; };
 return server;
}

export async function stopServer(server) {
 clearInterval(server.sampler);
 if (server.child.exitCode !== null) return;
 server.child.kill('SIGTERM');
 for (let i = 0; i < 40 && server.child.exitCode === null; i++) await sleep(250);
 if (server.child.exitCode === null) server.child.kill('SIGKILL');
}
