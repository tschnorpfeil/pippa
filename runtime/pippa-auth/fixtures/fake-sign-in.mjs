// Test preload (`node --import`): replaces fetch with fake OpenAI Codex and GitHub Copilot sign-in services, so Pi's own
// renewal code runs without any network. State lives in PIPPA_FAKE_SIGN_IN (a folder) and is shared by every process:
// a refresh token is accepted once and then rotated, as OpenAI does (REFRESH-n gives REFRESH-n+1); each request is appended to calls.jsonl. Imported
// without PIPPA_FAKE_SIGN_IN it only exports `jwt`.
import { appendFileSync, closeSync, existsSync, openSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const folder = process.env.PIPPA_FAKE_SIGN_IN;
const log = entry => appendFileSync(join(folder, 'calls.jsonl'), JSON.stringify({ pid: process.pid, ...entry }) + '\n');
const state = () => JSON.parse(readFileSync(join(folder, 'state.json'), 'utf8'));
const json = (status, body) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

export function jwt(accountId, serial) {
  const part = value => Buffer.from(JSON.stringify(value)).toString('base64url');
  return `${part({ alg: 'none' })}.${part({ 'https://api.openai.com/auth': { chatgpt_account_id: accountId }, serial })}.x`;
}

if (folder) globalThis.fetch = async (input, init = {}) => {
  const url = new URL(typeof input === 'string' ? input : input.url);
  const current = state();
  if (url.href === 'https://auth.openai.com/oauth/token') {
    const refresh = new URLSearchParams(String(init.body)).get('refresh_token');
    log({ service: 'codex', refresh });
    await sleep(current.delayMs ?? 0);
    // Each refresh token is accepted once (an exclusive marker file, atomic across processes), then it is rotated.
    const serial = Number(/^REFRESH-(\d+)$/.exec(refresh ?? '')?.[1]);
    try { if (!Number.isInteger(serial)) throw new Error('unknown'); closeSync(openSync(join(folder, `used-${serial}`), 'wx')); }
    catch { return json(400, { error: 'invalid_grant' }); }
    return json(200, { access_token: jwt(current.accountId, serial + 1), refresh_token: `REFRESH-${serial + 1}`, expires_in: 3600 });
  }
  if (url.pathname === '/copilot_internal/v2/token') {
    log({ service: 'copilot-token', host: url.host });
    return json(200, { token: `tid=fixture;exp=${Math.floor(Date.now() / 1000) + 1800};proxy-ep=${current.copilotProxy};`, expires_at: Math.floor(Date.now() / 1000) + 1800 });
  }
  if (url.pathname === '/models' && url.host.endsWith('githubcopilot.com')) {
    log({ service: 'copilot-models', host: url.host });
    return json(200, { data: [] });
  }
  log({ service: 'unexpected', url: url.href });
  throw new Error(`unexpected request to ${url.host}`);
};

if (folder && !existsSync(join(folder, 'calls.jsonl'))) writeFileSync(join(folder, 'calls.jsonl'), '');
