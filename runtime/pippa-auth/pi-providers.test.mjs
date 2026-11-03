import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { mkdtempSync, existsSync, rmSync, mkdirSync, writeFileSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { allowedSignInURL, catalog, interaction, refreshProvider } from './pi-providers.mjs';

const here = dirname(fileURLToPath(import.meta.url));

test('sign-in links accept provider HTTPS URLs, but reject local/custom URLs, credentials and control characters', () => {
  for (const url of ['https://auth.openai.com/oauth', 'https://accounts.google.com/o/oauth2/auth', 'https://console.anthropic.com/login', 'https://x.ai/auth']) assert.equal(allowedSignInURL(url), true, url);
  for (const url of ['http://localhost/login', 'file:///etc/passwd', 'javascript:alert(1)', 'https://u:password@example.com/', 'https://example.com/\nsecret', 'garbage', null]) assert.equal(allowedSignInURL(url), false, String(url));
});

test('catalog exposes public methods and chat models, using only available models for configured accounts', () => {
  const runtime = {
    getProviders: () => [
      { id: 'one', name: 'One', auth: { oauth: { name: 'One OAuth', loginLabel: 'Sign in' }, apiKey: { name: 'One API', login() {} } } },
      { id: 'two', name: 'Two', auth: { apiKey: { name: 'Ambient' } } },
    ],
    getProviderAuthStatus: id => ({ configured: id === 'one', secret: 'not serialized' }),
    getAvailableSnapshot: () => [{ provider: 'one', id: 'available', name: 'Available', apiKey: 'not serialized' }],
    getModels: id => [{ provider: id, id: 'catalog', name: 'Catalog' }],
  };
  assert.deepEqual(catalog(runtime), { providers: [
    { id: 'one', name: 'One', configured: true, methods: [{ id: 'oauth', name: 'Sign in' }, { id: 'api_key', name: 'One API' }], models: [{ id: 'available', name: 'Available' }] },
    { id: 'two', name: 'Two', configured: false, methods: [], models: [{ id: 'catalog', name: 'Catalog' }] },
  ] });
  // Pi's default is named only when the account can use it.
  const named = catalog(runtime, { one: 'available', two: 'missing' }).providers;
  assert.equal(named[0].defaultModel, 'available');
  assert.equal('defaultModel' in named[1], false);
});

test('generic text, secret, manual-code and select prompts use correlated stdin replies without echoing credentials', async () => {
  const lines = [], controller = new AbortController();
  const io = interaction(value => lines.push(value), controller.signal);
  for (const type of ['text', 'secret', 'manual_code']) {
    const result = io.prompt({ type, message: 'Enter value', placeholder: 'Value' });
    const id = lines.at(-1).id;
    assert.equal(io.respond({ id: 'wrong', value: 'secret-key' }), false);
    assert.equal(io.respond({ id, value: 'secret-key' }), true);
    assert.equal(await result, 'secret-key');
  }
  const result = io.prompt({ type: 'select', message: 'Choose', options: [{ id: 'subscription', label: 'Subscription' }] });
  const id = lines.at(-1).id;
  assert.equal(io.respond({ id, value: 'not-an-option' }), false);
  assert.equal(io.respond({ id, value: 'subscription' }), true);
  assert.equal(await result, 'subscription');
  assert.equal(JSON.stringify(lines).includes('secret-key'), false);
  io.close();
});

test('a callback cancels its manual prompt while leaving the overall login alive', async () => {
  const lines = [], controller = new AbortController(), promptController = new AbortController();
  const io = interaction(value => lines.push(value), controller.signal);
  const result = io.prompt({ type: 'manual_code', message: 'Code', signal: promptController.signal });
  const rejected = assert.rejects(result, /cancelled/);
  promptController.abort(); await rejected;
  assert.deepEqual(lines.at(-1), { event: 'dismiss', id: '1' });
  assert.equal(controller.signal.aborted, false);
  assert.equal(io.respond({ id: '1', value: 'late' }), false);
  const next = io.prompt({ type: 'text', message: 'Another' });
  const nextRejected = assert.rejects(next, /cancelled/);
  controller.abort(); await nextRejected;
  await assert.rejects(io.prompt({ type: 'secret', message: 'After cancellation' }), /cancelled/);
});

test('notifications relay browser and device flows and omit credential fields', () => {
  const lines = [], controller = new AbortController();
  const io = interaction(value => lines.push(value), controller.signal);
  io.notify({ type: 'auth_url', url: 'https://accounts.google.com/auth', instructions: 'Continue', token: 'private' });
  io.notify({ type: 'device_code', userCode: 'ABCD', verificationUri: 'https://github.com/login/device', token: 'private' });
  io.notify({ type: 'progress', message: 'Waiting\u001b', token: 'private' });
  assert.deepEqual(lines, [
    { event: 'open', url: 'https://accounts.google.com/auth', instructions: 'Continue' },
    { event: 'device_code', userCode: 'ABCD', verificationUri: 'https://github.com/login/device' },
    { event: 'progress', message: 'Waiting ' },
  ]);
  assert.throws(() => io.notify({ type: 'auth_url', url: 'file:///etc/passwd' }));
});

test('provider refresh is scoped and bounded, and a refresh failure does not undo successful login', async () => {
  let options;
  await refreshProvider({ async refresh(value) { options = value; throw new Error('offline'); } }, 'openrouter', new AbortController().signal);
  assert.equal(options.allowNetwork, true);
  assert.deepEqual(options.providers, ['openrouter']);
  assert.ok(options.signal instanceof AbortSignal);
});

test('broken releases and unknown commands return bounded protocol errors without stderr', () => {
  const home = mkdtempSync(join(tmpdir(), 'pippa-provider-missing-'));
  try {
    for (const [command, code] of [['catalog', 'pi_missing'], ['bad-command', 'invalid_request']]) {
      const run = spawnSync(process.execPath, [join(here, 'pi-providers.mjs'), home, command], { env: { PATH: process.env.PATH, HOME: home }, encoding: 'utf8', timeout: 5000 });
      assert.deepEqual(JSON.parse(run.stdout.trim()), { event: 'error', code });
      assert.equal(run.stderr, '');
      assert.equal(run.status, 2);
    }
  } finally { rmSync(home, { recursive: true, force: true }); }
});

const pin = JSON.parse(readFileSync(resolve(here, '../../app/Packaging/pi-release/package.json'), 'utf8')).version;
const release = process.env.PIPPA_PI_PAYLOAD ? join(process.env.PIPPA_PI_PAYLOAD, 'release')
  : process.env.PIPPA_PI_CLI ? resolve(dirname(process.env.PIPPA_PI_CLI), '../../../../..')
    : resolve(here, `../../.build/pi-payload-${pin}/release`);
test('bundled Pi public API lists requested providers and login methods in a fake HOME without network or models', { skip: !existsSync(join(release, 'package.json')) && 'Bundled Pi payload not available' }, () => {
  const home = mkdtempSync(join(tmpdir(), 'pippa-provider-catalog-'));
  try {
    const node = process.env.PIPPA_PI_NODE ?? resolve(release, '../bin/node');
    const run = spawnSync(existsSync(node) ? node : process.execPath, [join(here, 'pi-providers.mjs'), release, 'catalog'], {
      env: { HOME: home, PATH: process.env.PATH, PI_OFFLINE: '1', PI_TELEMETRY: 'off', PI_SKIP_VERSION_CHECK: '1', PI_CODING_AGENT_DIR: join(home, '.pi/agent') }, encoding: 'utf8', timeout: 15_000,
    });
    assert.equal(run.error, undefined);
    assert.equal(run.status, 0, run.stdout + run.stderr);
    assert.equal(run.stderr, '');
    const result = JSON.parse(run.stdout);
    assert.ok(result.providers.length > 10);
    for (const id of ['anthropic', 'openai', 'openai-codex', 'google', 'openrouter', 'opencode', 'opencode-go', 'xai']) {
      const provider = result.providers.find(provider => provider.id === id);
      assert.ok(provider, `${id} must come from Pi`);
      assert.equal(provider.configured, false, id);
      assert.ok(provider.methods.length, id);
    }
    assert.equal(result.providers.some(provider => provider.id === 'google-antigravity'), false, 'Do not invent an unsupported provider');
    // After Sign in with ChatGPT, Pippa preselects Pi's own OpenAI default instead of the oldest model on the list.
    const openai = result.providers.find(provider => provider.id === 'openai');
    assert.ok(openai.defaultModel && openai.models.some(model => model.id === openai.defaultModel), 'openai must name a listed default');
    assert.equal(JSON.stringify(result).includes('access_token'), false);
  } finally { rmSync(home, { recursive: true, force: true }); }
});


for (const outcome of ['reply', 'eof', 'terminate']) {
  test(`helper subprocess keeps auth input off argv/stdout and handles ${outcome}`, { timeout: 8000 }, async () => {
    const root = mkdtempSync(join(tmpdir(), 'pippa-provider-protocol-'));
    const sdk = join(root, 'node_modules/@earendil-works/pi-coding-agent/dist');
    mkdirSync(sdk, { recursive: true });
    writeFileSync(join(root, 'package.json'), JSON.stringify({ type: 'module' }));
    writeFileSync(join(sdk, 'index.js'), `
      export class ModelRuntime {
        static async create() { return new ModelRuntime(); }
        getProvider() { return { auth: { apiKey: { login() {} } } }; }
        async login(provider, type, io) {
          const key = await io.prompt({ type: 'secret', message: 'API key' });
          if (key !== 'fixture-secret') throw new Error('bad reply');
        }
        async refresh() {}
      }
      export const SettingsManager = { create() { return { getOrCreateDeviceId() { return 'test'; } }; } };
    `);
    const child = spawn(process.execPath, [join(here, 'pi-providers.mjs'), root, 'login', 'fixture', 'api_key'], {
      env: { HOME: root, PATH: process.env.PATH }, stdio: ['pipe', 'pipe', 'pipe'],
    });
    let output = '', stderr = '', acted = false;
    child.stderr.setEncoding('utf8'); child.stderr.on('data', chunk => { stderr += chunk; });
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', chunk => {
      output += chunk;
      if (!acted && output.includes('"event":"prompt"')) {
        acted = true;
        const prompt = JSON.parse(output.split('\n').find(line => line.includes('"event":"prompt"')));
        if (outcome === 'reply') child.stdin.write(JSON.stringify({ id: prompt.id, value: 'fixture-secret' }) + '\n');
        else if (outcome === 'eof') child.stdin.end();
        else child.kill('SIGTERM');
      }
    });
    try {
      const code = await new Promise((resolve, reject) => { child.once('error', reject); child.once('close', resolve); });
      assert.equal(code, outcome === 'reply' ? 0 : 1, output + stderr);
      const lines = output.trim().split('\n').map(line => JSON.parse(line));
      assert.deepEqual(lines.at(-1), outcome === 'reply' ? { event: 'done' } : { event: 'error', code: 'cancelled' });
      assert.equal(output.includes('fixture-secret'), false);
      assert.equal(child.spawnargs.join(' ').includes('fixture-secret'), false);
      assert.equal(stderr, '');
    } finally { child.kill('SIGKILL'); rmSync(root, { recursive: true, force: true }); }
  });
}


test('optional provider text fields can submit an empty value', async () => {
  const lines = [], controller = new AbortController();
  const io = interaction(value => lines.push(value), controller.signal);
  const result = io.prompt({ type: 'text', message: 'Enterprise domain (blank for default)' });
  assert.equal(io.respond({ id: lines.at(-1).id, value: '' }), true);
  assert.equal(await result, '');
  io.close();
});
