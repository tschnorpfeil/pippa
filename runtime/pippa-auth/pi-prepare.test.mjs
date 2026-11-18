// The online turn's credential, prepared with the bundled Pi's own ModelRuntime and AuthStorage (issue #193). Sign-in
// services are faked in-process (fixtures/fake-sign-in.mjs); nothing reaches the network.
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { FROZEN_REFRESH, frozen } from './pi-providers.mjs';
import { jwt } from './fixtures/fake-sign-in.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const pin = JSON.parse(readFileSync(resolve(here, '../../app/Packaging/pi-release/package.json'), 'utf8')).version;
const release = process.env.PIPPA_PI_PAYLOAD ? join(process.env.PIPPA_PI_PAYLOAD, 'release')
  : process.env.PIPPA_PI_CLI ? resolve(dirname(process.env.PIPPA_PI_CLI), '../../../../..')
    : resolve(here, `../../.build/pi-payload-${pin}/release`);
const bundled = existsSync(join(release, 'package.json'));
const skip = !bundled && 'Bundled Pi payload not available';
const node = process.env.PIPPA_PI_NODE ?? resolve(release, '../bin/node');
const piIndex = () => import(pathToFileURL(join(release, 'node_modules/@earendil-works/pi-coding-agent/dist/index.js')).href);
const codexModel = 'gpt-5.6-terra';
const copilotModel = 'claude-haiku-4.5';

function fixture(credentials, signIn) {
  const root = mkdtempSync(join(tmpdir(), 'pippa-prepare-'));
  const agent = join(root, 'agent'), service = join(root, 'service');
  mkdirSync(agent); mkdirSync(service);
  writeFileSync(join(agent, 'auth.json'), JSON.stringify(credentials), { mode: 0o600 });
  writeFileSync(join(service, 'state.json'), JSON.stringify(signIn));
  const target = name => { const folder = join(root, name); mkdirSync(folder, { mode: 0o700 }); return folder; };
  const calls = () => readFileSync(join(service, 'calls.jsonl'), 'utf8').split('\n').filter(Boolean).map(line => JSON.parse(line));
  return { root, agent, service, target, calls, cleanup: () => rmSync(root, { recursive: true, force: true }) };
}

function prepare(f, provider, model, target, agent = f.agent) {
  return new Promise(done => {
    const child = spawn(existsSync(node) ? node : process.execPath,
      ['--import', join(here, 'fixtures/fake-sign-in.mjs'), join(here, 'pi-providers.mjs'), release, 'prepare', provider, model, target], {
        env: { HOME: f.root, PATH: '/usr/bin:/bin', PI_CODING_AGENT_DIR: agent, PI_OFFLINE: '1', PI_TELEMETRY: '0', PIPPA_FAKE_SIGN_IN: f.service },
        stdio: ['ignore', 'pipe', 'pipe'],
      });
    let out = '';
    child.stdout.on('data', chunk => { out += chunk; });
    child.on('close', status => done({ status, events: out.split('\n').filter(Boolean).map(line => JSON.parse(line)) }));
  });
}

const read = file => JSON.parse(readFileSync(file, 'utf8'));
const expiredCodex = () => ({ 'openai-codex': { type: 'oauth', access: jwt('acct-1', 0), refresh: 'REFRESH-0', expires: Date.now() - 1000, accountId: 'acct-1' } });

test('a pinned credential cannot be renewed and keeps only a digest of the refresh token', () => {
  const credential = { type: 'oauth', access: 'A', refresh: 'SECRET-REFRESH', expires: 1, accountId: 'x' };
  const pinned = frozen(credential);
  assert.equal(pinned.access, 'A');
  assert.equal(pinned.accountId, 'x');
  assert.equal(pinned.expires, Number.MAX_SAFE_INTEGER);
  assert.ok(pinned.refresh.startsWith(FROZEN_REFRESH));
  assert.equal(JSON.stringify(pinned).includes('SECRET-REFRESH'), false);
  assert.deepEqual(frozen(pinned), pinned);
  const key = { type: 'api_key', key: 'K' };
  assert.equal(frozen(key), key);
});

test('two Pippa processes preparing at once renew a rotating sign-in once, through Pi\'s shared lock', { skip, timeout: 60_000 }, async () => {
  const f = fixture(expiredCodex(), { accountId: 'acct-1', delayMs: 400 });
  try {
    const one = f.target('one'), two = f.target('two');
    const results = await Promise.all([prepare(f, 'openai-codex', codexModel, one), prepare(f, 'openai-codex', codexModel, two)]);
    for (const result of results) {
      assert.equal(result.status, 0, JSON.stringify(result.events));
      assert.deepEqual(result.events.at(-1), { event: 'done', endpoint: null });
    }
    const calls = f.calls();
    assert.deepEqual(calls.map(call => call.service), ['codex'], JSON.stringify(calls));
    assert.equal(read(join(f.agent, 'auth.json'))['openai-codex'].refresh, 'REFRESH-1');
    for (const target of [one, two]) {
      const pinned = read(join(target, 'auth.json'));
      assert.deepEqual(Object.keys(pinned), ['openai-codex']);
      assert.equal(pinned['openai-codex'].access, jwt('acct-1', 1));
      assert.ok(pinned['openai-codex'].refresh.startsWith(FROZEN_REFRESH));
      assert.equal(JSON.stringify(pinned).includes('REFRESH-1'), false);
      assert.equal(statSync(join(target, 'auth.json')).mode & 0o777, 0o600);
    }
  } finally { f.cleanup(); }
});

test('control: two private copies of auth.json renew twice, and the second renewal is refused', { skip, timeout: 60_000 }, async () => {
  const f = fixture(expiredCodex(), { accountId: 'acct-1', delayMs: 100 });
  try {
    const copyOne = join(f.root, 'copy-one'), copyTwo = join(f.root, 'copy-two');
    cpSync(f.agent, copyOne, { recursive: true }); cpSync(f.agent, copyTwo, { recursive: true });
    const results = await Promise.all([prepare(f, 'openai-codex', codexModel, f.target('one'), copyOne),
      prepare(f, 'openai-codex', codexModel, f.target('two'), copyTwo)]);
    assert.equal(f.calls().filter(call => call.service === 'codex').length, 2);
    assert.deepEqual(results.map(result => result.events.at(-1).code ?? 'done').sort(), ['done', 'signed_out']);
  } finally { f.cleanup(); }
});

test('the Pi that runs a turn never renews its pinned sign-in, even past the real expiry', { skip, timeout: 60_000 }, async () => {
  const f = fixture(expiredCodex(), { accountId: 'acct-1' });
  const original = globalThis.fetch;
  let requests = 0;
  try {
    const target = f.target('pinned');
    assert.equal((await prepare(f, 'openai-codex', codexModel, target)).status, 0);
    const { ModelRuntime } = await piIndex();
    globalThis.fetch = async () => { requests++; throw new Error('no network in this test'); };
    const pinned = await ModelRuntime.create({ authPath: join(target, 'auth.json'), modelsPath: join(target, 'models.json'), allowModelNetwork: false });
    const before = readFileSync(join(target, 'auth.json'), 'utf8');
    const resolution = await pinned.getAuth(pinned.getModel('openai-codex', codexModel), { minOAuthValidityMs: 24 * 3600_000 });
    assert.equal(resolution.auth.apiKey, jwt('acct-1', 1));
    assert.equal(requests, 0);
    assert.equal(readFileSync(join(target, 'auth.json'), 'utf8'), before);
  } finally { globalThis.fetch = original; f.cleanup(); }
});

test('GitHub Copilot: Pi\'s resolver reports the endpoint a renewal moved to, and the pinned Pi keeps it', { skip, timeout: 60_000 }, async () => {
  const individual = 'tid=fixture;exp=1;proxy-ep=proxy.individual.githubcopilot.com;';
  const f = fixture({ 'github-copilot': { type: 'oauth', access: individual, refresh: 'GHU-FIXTURE', expires: Date.now() + 3600_000 } },
    { copilotProxy: 'proxy.business.githubcopilot.com' });
  try {
    const valid = await prepare(f, 'github-copilot', copilotModel, f.target('valid'));
    assert.deepEqual(valid.events.at(-1), { event: 'done', endpoint: 'https://api.individual.githubcopilot.com' });
    assert.deepEqual(f.calls(), []);
    const auth = read(join(f.agent, 'auth.json'));
    auth['github-copilot'].expires = Date.now() - 1000;
    writeFileSync(join(f.agent, 'auth.json'), JSON.stringify(auth));
    const target = f.target('renewed');
    const renewed = await prepare(f, 'github-copilot', copilotModel, target);
    assert.deepEqual(renewed.events.at(-1), { event: 'done', endpoint: 'https://api.business.githubcopilot.com' });
    assert.deepEqual(f.calls().map(call => call.service), ['copilot-token', 'copilot-models']);
    const pinned = read(join(target, 'auth.json'))['github-copilot'];
    assert.match(pinned.access, /proxy-ep=proxy\.business\.githubcopilot\.com/);
    assert.equal(pinned.refresh.includes('GHU-FIXTURE'), false);
  } finally { f.cleanup(); }
});

test('of the bundled Pi\'s sign-ins, only GitHub Copilot derives an endpoint, and only from proxy-ep and enterpriseUrl', { skip }, async () => {
  const { ModelRuntime } = await piIndex();
  const runtime = await ModelRuntime.create({ authPath: join(mkdtempSync(join(tmpdir(), 'pippa-oauth-')), 'auth.json'), modelsPath: null, allowModelNetwork: false });
  const derived = {};
  for (const provider of runtime.getProviders().filter(provider => provider.auth.oauth)) {
    const base = { type: 'oauth', refresh: 'R', expires: Date.now() + 3600_000, accountId: 'a' };
    const one = await provider.auth.oauth.toAuth({ ...base, access: 'tid=1;proxy-ep=proxy.one.example;' });
    const other = await provider.auth.oauth.toAuth({ ...base, access: 'tid=2;exp=9;proxy-ep=proxy.one.example;', refresh: 'S', expires: 1 });
    const moved = await provider.auth.oauth.toAuth({ ...base, access: 'tid=1;proxy-ep=proxy.two.example;' });
    if (one.baseUrl !== undefined || moved.baseUrl !== undefined) derived[provider.id] = [one.baseUrl, other.baseUrl, moved.baseUrl];
  }
  assert.deepEqual(derived, { 'github-copilot': ['https://api.one.example', 'https://api.one.example', 'https://api.two.example'] });
  const copilot = runtime.getProvider('github-copilot').auth.oauth;
  const enterprise = await copilot.toAuth({ type: 'oauth', access: 'tid=1;', refresh: 'R', expires: 0, enterpriseUrl: 'ghe.example.com' });
  assert.equal(enterprise.baseUrl, 'https://copilot-api.ghe.example.com');
});
