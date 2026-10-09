import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { allowedSignInURL, interaction, status } from './pi-auth.mjs';

const here = dirname(fileURLToPath(import.meta.url));

test('only OpenAI sign-in pages are opened', () => {
  assert.ok(allowedSignInURL('https://auth.openai.com/oauth/authorize?client_id=x&state=y'));
  for (const bad of ['http://auth.openai.com/x', 'https://auth.openai.com.evil.example/x', 'https://evil.example/?u=auth.openai.com', 'file:///etc/passwd', 'nonsense']) {
    assert.equal(allowedSignInURL(bad), false, bad);
  }
});

test('status: subscription, API key or nothing; models only from the openai catalog; no credential fields', () => {
  const runtime = (sub, configured) => ({
    isUsingSubscription: () => sub, hasConfiguredAuth: () => configured,
    getAvailableSnapshot: () => [{ provider: 'openai', id: 'gpt-x' }, { provider: 'omlx', id: 'local' }],
  });
  assert.deepEqual(status(runtime(true, true), { openai: 'gpt-x' }), { signedIn: true, kind: 'subscription', defaultModel: 'gpt-x', models: ['gpt-x'] });
  assert.equal(status(runtime(false, true), {}).kind, 'apiKey');
  assert.equal(status(runtime(false, false), {}).kind, 'none');
});

test('interaction: the browser link goes to the app, a foreign link is refused, the ChatGPT method is chosen, pasting waits', async () => {
  const lines = [];
  const controller = new AbortController();
  const io = interaction(value => lines.push(value), controller.signal);
  io.notify({ type: 'auth_url', url: 'https://auth.openai.com/oauth/authorize?x=1' });
  io.notify({ type: 'auth_url', url: 'https://evil.example/' });
  assert.deepEqual(lines, [{ event: 'open', url: 'https://auth.openai.com/oauth/authorize?x=1' }, { event: 'error', code: 'unexpected_url' }]);
  assert.equal(await io.prompt({ type: 'select', options: [{ id: 'key', label: 'API key' }, { id: 'oauth-chatgpt', label: 'Sign in with ChatGPT' }] }), 'oauth-chatgpt');
  const paste = io.prompt({ type: 'text', message: 'paste the redirect URL' });
  controller.abort();
  await assert.rejects(paste);
});

test('a broken release path says pi_missing on stdout and nothing on stderr', () => {
  const empty = mkdtempSync(join(tmpdir(), 'pippa-auth-test-'));
  const run = spawnSync(process.execPath, [join(here, 'pi-auth.mjs'), empty, 'status'], { env: { PATH: process.env.PATH, HOME: empty }, encoding: 'utf8' });
  assert.deepEqual(JSON.parse(run.stdout.trim()), { event: 'error', code: 'pi_missing' });
  assert.equal(run.stderr, '');
});
