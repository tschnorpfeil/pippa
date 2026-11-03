// Native UI bridge to Pi's public provider/auth APIs. Credentials travel only over stdin to Pi; stdout is JSONL.
import { pathToFileURL } from 'node:url';
import { join } from 'node:path';
import { homedir } from 'node:os';

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

export async function main(args = process.argv.slice(2)) {
  for (const name of ['log', 'info', 'warn', 'error', 'debug', 'trace']) console[name] = () => {};
  let emitted = 0;
  const write = value => {
    if (++emitted > 2000) throw new Error('output_limit');
    process.stdout.write(JSON.stringify(value) + '\n');
  };
  const [release, command, providerId, authType] = args;
  if (!['catalog', 'login', 'logout'].includes(command) || (command !== 'catalog' && !providerId)) {
    write({ event: 'error', code: 'invalid_request' }); return 2;
  }
  const controller = new AbortController();
  let hardStop;
  const stop = () => {
    controller.abort();
    // A provider which ignores AbortSignal must not leave a callback process alive indefinitely.
    hardStop ??= setTimeout(() => {
      process.stdout.write(JSON.stringify({ event: 'error', code: 'cancelled' }) + '\n', () => process.exit(1));
    }, 2000);
  };
  const timer = setTimeout(stop, command === 'login' ? 10 * 60_000 : 30_000);
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
    let ModelRuntime, SettingsManager;
    try {
      ({ ModelRuntime, SettingsManager } = await import(pathToFileURL(join(release ?? '', 'node_modules/@earendil-works/pi-coding-agent/dist/index.js')).href));
    } catch { write({ event: 'error', code: 'pi_missing' }); return 2; }
    const runtime = await ModelRuntime.create({ allowModelNetwork: false, signal: controller.signal });
    if (command === 'catalog') {
      if (providerId && runtime.getProvider(providerId)) await refreshProvider(runtime, providerId, controller.signal);
      write(catalog(runtime, await piDefaults(release))); return 0;
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
    write({ event: 'error', code: controller.signal.aborted ? 'cancelled' : /EADDRINUSE/.test(String(error?.code ?? '') + String(error?.message ?? '')) ? 'port_busy' : 'failed' });
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
