#!/usr/bin/env node
// Fresh-install acceptance: the actual app starts a Pi provider without a pippa-local entry or local model.
// All state lives in a temporary HOME. A loopback scripted responder replaces the model; no account or LLM is used.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const app = resolve(process.argv[2] ?? 'dist/Pippa.app');
const home = await mkdtemp(join(tmpdir(), 'pippa-provider-smoke-'));
const agent = join(home, '.pi/agent');
const support = join(home, 'Library/Application Support/Pippa');
let calls = 0;
let requestModel;
const server = createServer((req, res) => {
  if (req.url !== '/v1/chat/completions') { res.writeHead(404).end(); return; }
  let body = '';
  req.on('data', chunk => { body += chunk; });
  req.on('end', () => {
    calls++;
    requestModel = JSON.parse(body).model;
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    const chunk = (delta, finish_reason = null) => `data: ${JSON.stringify({ id: 'fixture', object: 'chat.completion.chunk', created: 0, model: 'cloud-fixture', choices: [{ index: 0, delta, finish_reason }] })}\n\n`;
    res.end(chunk({ role: 'assistant', content: 'PIPPA_PROVIDER_OK' }) + chunk({}, 'stop') + 'data: [DONE]\n\n');
  });
});
let child;
let timeout;
try {
  await Promise.all([agent, support].map(path => mkdir(path, { recursive: true })));
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  await writeFile(join(agent, 'models.json'), JSON.stringify({ providers: {
    'cloud-fixture': { baseUrl: `http://127.0.0.1:${server.address().port}/v1`, api: 'openai-completions', apiKey: 'test-only',
      models: [{ id: 'cloud-fixture', name: 'Fixture', contextWindow: 32768, maxTokens: 1024 }] },
  } }));
  await writeFile(join(support, 'inference-settings.json'), JSON.stringify({ policy: 'localOnly',
    piModel: { providerID: 'cloud-fixture', modelID: 'cloud-fixture', providerName: 'Fixture' } }));
  child = spawn(join(app, 'Contents/MacOS/Pippa'), ['--ask', 'Reply with PIPPA_PROVIDER_OK. Do not use tools.'], {
    detached: true,
    env: { HOME: home, CFFIXED_USER_HOME: home, PIPPA_PI_HOME: home, PI_CODING_AGENT_DIR: agent,
      PATH: '/usr/bin:/bin:/usr/sbin:/sbin', PIPPA_NO_MOVE: '1', PI_TELEMETRY: '0', PI_OFFLINE: '1', PI_SKIP_VERSION_CHECK: '1' },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let stdout = '', stderr = '';
  child.stdout.on('data', chunk => { stdout += chunk; });
  child.stderr.on('data', chunk => { stderr += chunk; });
  timeout = setTimeout(() => { try { process.kill(-child.pid, 'SIGKILL'); } catch {} }, 30_000);
  const code = await new Promise((resolve, reject) => { child.on('error', reject); child.on('exit', resolve); });
  assert.equal(code, 0, stdout + stderr);
  assert.ok(stdout.includes('PIPPA_PROVIDER_OK'), stdout);
  assert.ok(!stdout.includes('FAILED:'), stdout);
  assert.ok(calls > 0, 'selected provider must receive the request');
  assert.equal(requestModel, 'cloud-fixture');
  console.log('Provider setup smoke passed: fresh HOME → selected Pi provider → actual app answer; no local model.');
} finally {
  clearTimeout(timeout);
  if (child?.pid) { try { process.kill(-child.pid, 'SIGKILL'); } catch {} }
  server.closeAllConnections();
  await new Promise(resolve => server.close(resolve));
  await rm(home, { recursive: true, force: true });
}
