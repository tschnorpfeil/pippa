#!/usr/bin/env node
// The recipient PiSession checked is the one Pi's request reaches (P1-01). The actual app runs `--ask` on a Pi provider
// whose key lives in auth.json, in a temporary HOME, against loopback responders; no account or LLM is used.
//
//   node scripts/recipient-binding-smoke.mjs <Pippa.app | app/.build/debug/Pippa>
//   (a debug binary needs PIPPA_PI_PAYLOAD, a folder from `scripts/bundle-pi-payload.sh <folder> --with-node`)
//
// Pippa's own pippa-assist.ts is wrapped by a test copy that, inside Pi, after PiSession's last check and before Pi
// resolves the credential for the request (`context` runs before every provider call), rotates the shared
// ~/.pi/agent: auth.json gets another key and models.json another endpoint. Pi 1.5 rereads auth.json per request, so
// without a private copy the approved recipient's question would go out with the other account's key.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { cp, mkdir, mkdtemp, readdir, readFile, rename, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const target = resolve(process.argv[2] ?? 'dist/Pippa.app');
const binary = target.endsWith('.app') ? join(target, 'Contents/MacOS/Pippa') : target;
const repo = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const home = await mkdtemp(join(tmpdir(), 'pippa-recipient-smoke-'));
const agent = join(home, '.pi/agent');
const support = join(home, 'Library/Application Support/Pippa');
const extensions = join(home, 'extensions');
const KEY_A = 'KEY-A-approved-' + 'a1'.repeat(16);
const KEY_B = 'KEY-B-rotated-' + 'b2'.repeat(16);
const QUESTION = 'RECIPIENT-MARKER-61c3 Reply with PIPPA_RECIPIENT_OK. Do not use tools.';

const requests = { a: [], b: [] };
const responder = name => createServer((req, res) => {
  let body = '';
  req.on('data', chunk => { body += chunk; });
  req.on('end', () => {
    requests[name].push({ url: req.url, authorization: req.headers.authorization ?? '', body });
    if (req.url !== '/v1/chat/completions') { res.writeHead(404).end(); return; }
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    const chunk = (delta, finish_reason = null) => `data: ${JSON.stringify({ id: 'fixture', object: 'chat.completion.chunk', created: 0, model: 'rot-fixture', choices: [{ index: 0, delta, finish_reason }] })}\n\n`;
    res.end(chunk({ role: 'assistant', content: 'PIPPA_RECIPIENT_OK' }) + chunk({}, 'stop') + 'data: [DONE]\n\n');
  });
});
const servers = { a: responder('a'), b: responder('b') };
const entry = port => ({ baseUrl: `http://127.0.0.1:${port}/v1`, api: 'openai-completions',
  models: [{ id: 'rot-fixture', name: 'Fixture', contextWindow: 32768, maxTokens: 1024 }] });

let child;
let timeout;
try {
  await Promise.all([agent, support].map(path => mkdir(path, { recursive: true })));
  await Promise.all(Object.values(servers).map(server => new Promise(done => server.listen(0, '127.0.0.1', done))));
  const [portA, portB] = [servers.a.address().port, servers.b.address().port];
  await writeFile(join(agent, 'models.json'), JSON.stringify({ providers: { 'rot-fixture': entry(portA) } }));
  await writeFile(join(agent, 'auth.json'), JSON.stringify({ 'rot-fixture': { type: 'api_key', key: KEY_A },
    'other-provider': { type: 'api_key', key: 'OTHER-KEY-never-copied' } }), { mode: 0o600 });
  await writeFile(join(support, 'inference-settings.json'), JSON.stringify({ policy: 'localOnly',
    piModel: { providerID: 'rot-fixture', modelID: 'rot-fixture', providerName: 'Fixture' } }));

  // Pippa's extensions with pippa-assist.ts wrapped: the rotation runs inside Pi, after the prompt arrived.
  await cp(join(repo, 'runtime/pippa-tools'), extensions, { recursive: true });
  await rename(join(extensions, 'pippa-assist.ts'), join(extensions, 'pippa-assist-original.ts'));
  await writeFile(join(extensions, 'pippa-assist.ts'), `import { existsSync, readFileSync, writeFileSync } from "node:fs";
import original from "./pippa-assist-original.ts";
export * from "./pippa-assist-original.ts";
let rotated = false;
export default function (pi: any) {
  original(pi);
  pi.on("context", () => {
    if (rotated) return;
    rotated = true;
    const own = process.env.PI_CODING_AGENT_DIR + "/auth.json";
    writeFileSync(${JSON.stringify(join(home, 'pi-agent'))}, JSON.stringify({ shared: process.env.PI_CODING_AGENT_DIR === ${JSON.stringify(agent)},
      providers: existsSync(own) ? Object.keys(JSON.parse(readFileSync(own, "utf8"))) : [] }));
    writeFileSync(${JSON.stringify(join(agent, 'auth.json'))}, JSON.stringify({ "rot-fixture": { type: "api_key", key: ${JSON.stringify(KEY_B)} } }));
    writeFileSync(${JSON.stringify(join(agent, 'models.json'))}, JSON.stringify({ providers: { "rot-fixture": ${JSON.stringify(entry(portB))} } }));
    writeFileSync(${JSON.stringify(join(home, 'rotated'))}, "1");
  });
}
`);

  const env = { HOME: home, CFFIXED_USER_HOME: home, PIPPA_PI_HOME: home, PI_CODING_AGENT_DIR: agent, PIPPA_PI_EXTENSIONS: extensions, PIPPA_PI_WEB: '',
    PATH: '/usr/bin:/bin:/usr/sbin:/sbin', PIPPA_NO_MOVE: '1', PI_TELEMETRY: '0', PI_OFFLINE: '1', PI_SKIP_VERSION_CHECK: '1' };
  if (process.env.PIPPA_PI_PAYLOAD) env.PIPPA_PI_PAYLOAD = process.env.PIPPA_PI_PAYLOAD;
  child = spawn(binary, ['--ask', QUESTION], { detached: true, env, stdio: ['ignore', 'pipe', 'pipe'] });
  let stdout = '', stderr = '';
  child.stdout.on('data', chunk => { stdout += chunk; });
  child.stderr.on('data', chunk => { stderr += chunk; });
  timeout = setTimeout(() => { try { process.kill(-child.pid, 'SIGKILL'); } catch {} }, 60_000);
  const code = await new Promise((done, reject) => { child.on('error', reject); child.on('exit', done); });

  assert.ok(await stat(join(home, 'rotated')).then(() => true, () => false), 'the rotation ran inside Pi before its request\n' + stdout + stderr);
  const all = [...requests.a, ...requests.b];
  assert.ok(all.every(request => !request.authorization.includes(KEY_B) && !request.body.includes(KEY_B)), 'no request carries the rotated key');
  assert.equal(requests.b.length, 0, 'the rotated endpoint receives nothing');
  const chats = requests.a.filter(request => request.url === '/v1/chat/completions');
  assert.equal(chats.length, 1, 'one question reaches the checked endpoint once\n' + stdout + stderr);
  assert.equal(chats[0].authorization, `Bearer ${KEY_A}`, 'with the checked account');
  const body = JSON.parse(chats[0].body);
  assert.equal(body.model, 'rot-fixture');
  assert.ok(JSON.stringify(body.messages).includes('RECIPIENT-MARKER-61c3'), 'carrying the question');
  assert.equal(code, 0, stdout + stderr);
  const seen = JSON.parse(await readFile(join(home, 'pi-agent'), 'utf8'));
  assert.deepEqual(seen, { shared: false, providers: ['rot-fixture'] }, 'Pi reads a private agent folder holding only this provider');
  assert.ok(stdout.includes('PIPPA_RECIPIENT_OK'), stdout);

  // The person's rotation stays: Pippa never writes a private copy back to the shared auth.json.
  assert.equal(JSON.parse(await readFile(join(agent, 'auth.json'), 'utf8'))['rot-fixture'].key, KEY_B);
  // The private copy is gone after the run, and never held another provider's credential.
  const left = await readdir(join(support, 'pi-recipients')).catch(() => []);
  for (const folder of left) assert.deepEqual(await readdir(join(support, 'pi-recipients', folder)), [], 'snapshot removed');
  console.log(`Recipient binding smoke passed: rotated auth.json and models.json inside Pi; the request went to :${portA} with the checked key only.`);
} finally {
  clearTimeout(timeout);
  if (child?.pid) { try { process.kill(-child.pid, 'SIGKILL'); } catch {} }
  for (const server of Object.values(servers)) { server.closeAllConnections(); await new Promise(done => server.close(done)); }
  if (process.env.PIPPA_SMOKE_KEEP) console.log('kept', home); else await rm(home, { recursive: true, force: true });
}
