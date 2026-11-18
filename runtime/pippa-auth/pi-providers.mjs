// Native UI bridge to Pi's public provider/auth APIs. Credentials travel only over stdin to Pi; stdout is JSONL.
import { pathToFileURL } from 'node:url';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { createHash, randomUUID } from 'node:crypto';
import { readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';

const clean = value => String(value ?? '').replace(/[\u0000-\u001f\u007f]/g, ' ').slice(0, 4096);
const aborted = () => new Error('cancelled');

export function allowedSignInURL(value) {
  if (typeof value !== 'string' || value.length > 16_384 || /[\u0000-\u0020\u007f]/.test(value)) return false;
  try {
    const url = new URL(value);
    return url.protocol === 'https:' && !!url.hostname && !url.username && !url.password;
  } catch { return false; }
}

/** Only public catalog metadata leaves Pi; no auth result or credential object is serialized. `defaults` is Pi's own
 * model choice per provider (`defaultModelPerProvider`), named only when that model is on the provider's list. */
export function catalog(runtime, defaults = {}) {
  const available = runtime.getAvailableSnapshot();
  return { providers: runtime.getProviders().map(provider => {
    const configured = runtime.getProviderAuthStatus(provider.id).configured;
    const models = configured ? available.filter(model => model.provider === provider.id) : runtime.getModels(provider.id);
    const methods = [];
    if (provider.auth.oauth) methods.push({ id: 'oauth', name: clean(provider.auth.oauth.loginLabel ?? provider.auth.oauth.name) });
    if (provider.auth.apiKey?.login) methods.push({ id: 'api_key', name: clean(provider.auth.apiKey.name) });
    const defaultModel = models.some(model => model.id === defaults[provider.id]) ? defaults[provider.id] : undefined;
    return {
      id: provider.id, name: clean(provider.name), configured, methods,
      models: models.map(model => ({ id: model.id, name: clean(model.name) })),
      ...(defaultModel ? { defaultModel } : {}),
    };
  }) };
}

/** Matches responses to prompts, including callback races which cancel only the manual-code prompt. */
export function interaction(write, signal) {
  let sequence = 0;
  const pending = new Map();
  const settle = (id, value, error) => {
    const item = pending.get(id);
    if (!item) return;
    pending.delete(id);
    item.cleanup();
    if (error) { write({ event: 'dismiss', id }); item.reject(error); }
    else item.resolve(value);
  };
  return {
    signal,
    prompt(prompt) {
      if (signal.aborted || prompt.signal?.aborted) return Promise.reject(aborted());
      if (!['text', 'secret', 'select', 'manual_code'].includes(prompt.type)) return Promise.reject(new Error('unsupported_prompt'));
      const id = String(++sequence);
      return new Promise((resolve, reject) => {
        const cancel = () => settle(id, undefined, aborted());
        const cleanup = () => { signal.removeEventListener('abort', cancel); prompt.signal?.removeEventListener('abort', cancel); };
        pending.set(id, { resolve, reject, cleanup, options: prompt.type === 'select' ? prompt.options : undefined });
        signal.addEventListener('abort', cancel, { once: true });
        prompt.signal?.addEventListener('abort', cancel, { once: true });
        write({ event: 'prompt', id, type: prompt.type, message: clean(prompt.message),
          ...(prompt.placeholder ? { placeholder: clean(prompt.placeholder) } : {}),
          ...(prompt.type === 'select' ? { options: prompt.options.map(option => ({ id: option.id, label: clean(option.label), ...(option.description ? { description: clean(option.description) } : {}) })) } : {}),
        });
      });
    },
    respond(response) {
      if (!response || typeof response.id !== 'string' || typeof response.value !== 'string' || response.value.length > 65_536) return false;
      const item = pending.get(response.id);
      if (!item || (item.options && !item.options.some(option => option.id === response.value))) return false;
      settle(response.id, response.value);
      return true;
    },
    notify(event) {
      switch (event?.type) {
      case 'auth_url':
        if (!allowedSignInURL(event.url)) throw new Error('unsafe_sign_in_url');
        write({ event: 'open', url: event.url, ...(event.instructions ? { instructions: clean(event.instructions) } : {}) });
        break;
      case 'device_code':
        if (!allowedSignInURL(event.verificationUri)) throw new Error('unsafe_sign_in_url');
        write({ event: 'device_code', userCode: clean(event.userCode), verificationUri: event.verificationUri });
        break;
      case 'info': case 'progress':
        write({ event: event.type, message: clean(event.message) });
        break;
      }
    },
    close() { for (const id of [...pending.keys()]) settle(id, undefined, aborted()); },
  };
}

/** Pi's default model per provider, as `pi --provider <id>` picks it. Not on Pi's public index, so optional. */
export async function piDefaults(release) {
  try {
    const { defaultModelPerProvider } = await import(pathToFileURL(join(release ?? '', 'node_modules/@earendil-works/pi-coding-agent/dist/core/model-resolver.js')).href);
    return defaultModelPerProvider && typeof defaultModelPerProvider === 'object' ? defaultModelPerProvider : {};
  } catch { return {}; }
}

export async function refreshProvider(runtime, provider, signal) {
  // Login has already succeeded; a transient catalog refresh must not report that credentials were rejected.
  try {
    await runtime.refresh({ providers: [provider], allowNetwork: true, signal: AbortSignal.any([signal, AbortSignal.timeout(15_000)]) });
  } catch { /* A cached catalog remains available; the UI can refresh again later. */ }
}

/** Marks the refresh token of a pinned credential: only its digest, never a token any provider would accept. */
export const FROZEN_REFRESH = 'pippa-frozen:';
/** Headroom for one online turn: a sign-in expiring sooner is renewed before the turn, never inside the pinned Pi. */
export const TURN_HEADROOM_MS = 15 * 60_000;

/** The credential a pinned Pi gets: an OAuth sign-in keeps its access token and account fields, but Pi can never renew
 * it (no refresh token, no expiry it would act on), so no second process rotates the person's refresh token and the
 * endpoint Pi derives from the access token stays the one checked. A sign-in without a refresh token (OpenRouter's:
 * a lasting key as `access`, `refresh: ""`) keeps it empty, so Pippa names it by its key in both copies. Other
 * credentials are copied as they are. */
export function frozen(credential) {
  if (credential?.type !== 'oauth') return credential;
  const refresh = String(credential.refresh ?? '');
  if (!refresh) return { ...credential, expires: Number.MAX_SAFE_INTEGER };
  const digest = refresh.startsWith(FROZEN_REFRESH) ? refresh.slice(FROZEN_REFRESH.length) : createHash('sha256').update(refresh).digest('hex');
  return { ...credential, refresh: FROZEN_REFRESH + digest, expires: Number.MAX_SAFE_INTEGER };
}

/** Writes `value` privately, or removes the file when there is nothing to write. */
function writePrivate(file, value) {
  if (value === undefined) { rmSync(file, { force: true }); return; }
  const temporary = `${file}.${randomUUID()}`;
  try {
    writeFileSync(temporary, JSON.stringify(value, null, 2), { mode: 0o600, flag: 'wx' });
    renameSync(temporary, file);
  } finally { rmSync(temporary, { force: true }); }
}

/**
 * Prepares one online turn with Pi's own code. In Pi's shared agent folder (`agent`), `ModelRuntime.getAuth` renews a
 * sign-in that would expire within the turn, under Pi's auth.json lock and re-checked there, so two Pippa processes (or
 * Pi in the terminal) renew a rotating refresh token once, not twice. The credential as stored then goes frozen into
 * `target/auth.json`, the private folder of the Pi that runs the turn, with the provider's models.json entry (read by
 * Pi's own `ModelConfig`: comments, trailing commas, its schema) and cached catalog. That folder is resolved as that Pi
 * will resolve it, and the endpoint Pi derives from the credential (GitHub Copilot: from the access token) is returned
 * for the recipient check. Nothing here sends a model request; only a due renewal reaches the provider's sign-in service.
 */
export async function prepareRecipient(pi, { agent, target, providerId, modelId, signal }) {
  const { ModelRuntime, ModelConfig, readStoredCredential } = pi;
  // A models.json Pi cannot use would leave the shared Pi on other settings than the ones Pippa named: send nothing.
  const config = await ModelConfig.load(join(agent, 'models.json'));
  if (config.getError()) throw Object.assign(new Error('models.json unreadable'), { code: 'unreadable_config' });
  const entry = config.getProvider(providerId);
  writePrivate(join(target, 'models.json'), entry && { providers: { [providerId]: entry } });
  const shared = await ModelRuntime.create({ authPath: join(agent, 'auth.json'), modelsPath: join(agent, 'models.json'), allowModelNetwork: false, signal });
  const model = shared.getModel(providerId, modelId);
  if (!model) throw Object.assign(new Error('unknown model'), { code: 'unknown_model' });
  try {
    await shared.getAuth(model, { signal, minOAuthValidityMs: TURN_HEADROOM_MS });
  } catch (error) {
    // The renewal ran and was stored, but this provider's tokens live shorter than the headroom: use what it issued.
    if (!/expires too soon/.test(String(error?.message))) throw error;
  }
  signal.throwIfAborted();
  // The catalog as Pi's FileModelsStore parses it, after a renewal that may have refreshed it.
  let catalog;
  try {
    const content = readFileSync(join(agent, 'models-store.json'), 'utf8');
    catalog = content ? JSON.parse(content.replace(/^\uFEFF/, '')) : {};
  } catch (error) { if (error?.code !== 'ENOENT') throw error; }
  writePrivate(join(target, 'models-store.json'), catalog?.[providerId] === undefined ? undefined : { [providerId]: catalog[providerId] });
  const credential = readStoredCredential(providerId, join(agent, 'auth.json'));
  const pinnedAuth = join(target, 'auth.json');
  writePrivate(pinnedAuth, credential ? { [providerId]: frozen(credential) } : undefined);
  const pinned = await ModelRuntime.create({ authPath: pinnedAuth, modelsPath: join(target, 'models.json'), allowModelNetwork: false, signal });
  const pinnedModel = pinned.getModel(providerId, modelId);
  const resolution = pinnedModel && await pinned.getAuth(pinnedModel, { signal });
  if (!resolution) throw Object.assign(new Error('not configured'), { code: 'not_configured' });
  return { endpoint: typeof resolution.auth?.baseUrl === 'string' ? resolution.auth.baseUrl : null };
}

export async function main(args = process.argv.slice(2)) {
  for (const name of ['log', 'info', 'warn', 'error', 'debug', 'trace']) console[name] = () => {};
  let emitted = 0;
  const write = value => {
    if (++emitted > 2000) throw new Error('output_limit');
    process.stdout.write(JSON.stringify(value) + '\n');
  };
  const [release, command, providerId, authType, target] = args;
  if (!['catalog', 'login', 'logout', 'prepare'].includes(command) || (command !== 'catalog' && !providerId)
      || (command === 'prepare' && (!authType || !target || !process.env.PI_CODING_AGENT_DIR))) {
    write({ event: 'error', code: 'invalid_request' }); return 2;
  }
  const controller = new AbortController();
  let hardStop;
  let stopCode = 'cancelled';
  const stop = () => {
    controller.abort();
    // A provider which ignores AbortSignal must not leave a callback process alive indefinitely. A renewal that has
    // started is bounded by Pi itself (15 s) and must be stored, or the rotated refresh token would be lost.
    hardStop ??= setTimeout(() => {
      process.stdout.write(JSON.stringify({ event: 'error', code: stopCode }) + '\n', () => process.exit(1));
    }, command === 'prepare' ? 20_000 : 2000);
  };
  const timer = setTimeout(() => {
    if (!controller.signal.aborted) stopCode = 'timeout';
    stop();
  }, command === 'login' ? 10 * 60_000 : command === 'prepare' ? 45_000 : 30_000);
  process.on('SIGTERM', stop);
  let bridge;
  let buffer = '';
  const onInput = chunk => {
    buffer += chunk;
    if (buffer.length > 131_072) { stop(); return; }
    let end;
    while ((end = buffer.indexOf('\n')) !== -1) {
      const line = buffer.slice(0, end); buffer = buffer.slice(end + 1);
      try { bridge?.respond(JSON.parse(line)); } catch { /* Invalid replies never reach a provider. */ }
    }
  };
  try {
    let pi;
    try {
      pi = await import(pathToFileURL(join(release ?? '', 'node_modules/@earendil-works/pi-coding-agent/dist/index.js')).href);
    } catch { write({ event: 'error', code: 'pi_missing' }); return 2; }
    const { ModelRuntime, SettingsManager } = pi;
    if (command === 'prepare') {
      // Pi's models.json reader is not on its public index; the pinned release is checked by pi-prepare.test.mjs.
      const { ModelConfig } = await import(pathToFileURL(join(release, 'node_modules/@earendil-works/pi-coding-agent/dist/core/model-config.js')).href);
      const prepared = await prepareRecipient({ ...pi, ModelConfig }, { agent: process.env.PI_CODING_AGENT_DIR, target, providerId, modelId: authType, signal: controller.signal });
      write({ event: 'done', endpoint: prepared.endpoint }); return 0;
    }
    const runtime = await ModelRuntime.create({ allowModelNetwork: false, signal: controller.signal });
    if (command === 'catalog') {
      if (providerId && runtime.getProvider(providerId)) await refreshProvider(runtime, providerId, controller.signal);
      const defaults = await piDefaults(release);
      controller.signal.throwIfAborted();
      write(catalog(runtime, defaults)); return 0;
    }
    const provider = runtime.getProvider(providerId);
    if (!provider || (command === 'login' && !((authType === 'oauth' && provider.auth.oauth) || (authType === 'api_key' && provider.auth.apiKey?.login)))) {
      write({ event: 'error', code: 'invalid_request' }); return 2;
    }
    if (command === 'logout') {
      await runtime.logout(providerId, { signal: controller.signal }); write({ event: 'done' }); return 0;
    }
    bridge = interaction(write, controller.signal);
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', onInput);
    process.stdin.on('end', stop);
    process.stdin.resume();
    const settings = SettingsManager.create(homedir());
    await runtime.login(providerId, authType, bridge, { getDeviceId: () => settings.getOrCreateDeviceId() });
    await refreshProvider(runtime, providerId, controller.signal);
    write({ event: 'done' }); return 0;
  } catch (error) {
    const detail = String(error?.code ?? '') + String(error?.message ?? '');
    write({ event: 'error', code: controller.signal.aborted ? stopCode : /EADDRINUSE/.test(detail) ? 'port_busy'
      : command === 'prepare' && /not_configured|OAuth refresh failed/.test(detail) ? 'signed_out' : 'failed' });
    return 1;
  } finally {
    clearTimeout(timer); clearTimeout(hardStop);
    controller.abort(); bridge?.close();
    process.removeListener('SIGTERM', stop);
    process.stdin.removeListener('data', onInput);
    process.stdin.removeListener('end', stop);
    process.stdin.pause();
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  // Pi's login callback server or dynamic provider may retain handles after cancellation.
  const code = await main();
  await new Promise(resolve => process.stdout.write('', resolve));
  process.exit(code);
}
