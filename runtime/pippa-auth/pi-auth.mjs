// Pippa's door to Pi's own sign-in for the ChatGPT subscription. Only the app starts it (PiSubscriptionAuth.swift), with
// Pippa's Node and the installed, pinned Pi release. Everything runs through Pi's public API (ModelRuntime: status,
// login, logout); Pi opens its callback on 127.0.0.1 with PKCE and state and stores the credential in its own
// auth.json, exactly as `/login` in the terminal does. This file never sees, prints or copies a token.
//
//   node pi-auth.mjs <release-dir> status   → {"signedIn":bool,"kind":"subscription"|"apiKey"|"none","defaultModel","models":[…]}
//   node pi-auth.mjs <release-dir> login    → {"event":"open","url"} … {"event":"done"} | {"event":"error","code"}
//   node pi-auth.mjs <release-dir> logout   → {"done":true}
//
// stdout is the protocol (JSON lines), stderr stays empty. SIGTERM or a closed stdin cancels a running sign-in.
import { pathToFileURL } from 'node:url';
import { join } from 'node:path';
import { homedir } from 'node:os';

export const provider = 'openai';

/** Only Pi's real sign-in pages may be opened in the browser. */
export function allowedSignInURL(text) {
  try {
    const url = new URL(text);
    return url.protocol === 'https:' && (url.hostname === 'auth.openai.com' || url.hostname.endsWith('.openai.com') || url.hostname === 'chatgpt.com');
  } catch { return false; }
}

/** Status without network: what Pi has stored and which models its catalog offers. */
export function status(runtime, defaults) {
  const signedIn = runtime.isUsingSubscription(provider);
  const kind = signedIn ? 'subscription' : (runtime.hasConfiguredAuth(provider) ? 'apiKey' : 'none');
  const models = runtime.getAvailableSnapshot().filter(model => model.provider === provider).map(model => model.id);
  return { signedIn, kind, defaultModel: defaults?.[provider] ?? null, models };
}

/** Interaction for Pi's login: the browser link goes to the app, a manual paste is not offered (the callback is local). */
export function interaction(write, signal) {
  return {
    signal,
    notify(event) {
      if (event?.type === 'auth_url') {
        if (allowedSignInURL(event.url)) write({ event: 'open', url: event.url });
        else write({ event: 'error', code: 'unexpected_url' });
      } else if (event?.type === 'progress') write({ event: 'progress' });
    },
    prompt(prompt) {
      // A choice of sign-in methods: the ChatGPT one; anything else (paste the redirect URL) waits for the callback.
      if (prompt?.type === 'select' && Array.isArray(prompt.options)) {
        const option = prompt.options.find(o => /chatgpt|subscription/i.test(`${o.id} ${o.label ?? ''}`)) ?? prompt.options[0];
        return Promise.resolve(option.id);
      }
      return new Promise((_, reject) => (prompt?.signal ?? signal).addEventListener('abort', () => reject(new Error('aborted')), { once: true }));
    },
  };
}

async function main() {
  for (const name of ['log', 'info', 'warn', 'error', 'debug', 'trace']) console[name] = () => {};
  const write = value => process.stdout.write(JSON.stringify(value) + '\n');
  const [release, command] = process.argv.slice(2);
  const base = join(release ?? '', 'node_modules/@earendil-works/pi-coding-agent/dist');
  let runtime, defaults, settings;
  try {
    const { ModelRuntime, SettingsManager } = await import(pathToFileURL(join(base, 'index.js')).href);
    // Pi's installation ID (sent to OpenAI as the agent host), created on first use exactly as Pi's own /login does.
    settings = SettingsManager.create(homedir());
    ({ defaultModelPerProvider: defaults } = await import(pathToFileURL(join(base, 'core/model-resolver.js')).href));
    runtime = await ModelRuntime.create();
  } catch {
    write({ event: 'error', code: 'pi_missing' }); process.exit(2);
  }
  if (command === 'status') { write(status(runtime, defaults)); return; }
  if (command === 'logout') { await runtime.logout(provider); write({ done: true }); return; }
  if (command !== 'login') { write({ event: 'error', code: 'invalid_request' }); process.exit(2); }
  const controller = new AbortController();
  const stop = () => controller.abort();
  process.on('SIGTERM', stop);
  process.stdin.on('end', stop);
  process.stdin.resume();
  const timer = setTimeout(stop, 10 * 60_000);
  try {
    await runtime.login(provider, 'oauth', interaction(write, controller.signal), { getDeviceId: () => settings.getOrCreateDeviceId() });
    write({ event: 'done', ...status(runtime, defaults) });
  } catch (error) {
    const text = String(error?.message ?? error);
    write({ event: 'error', code: controller.signal.aborted ? 'cancelled' : /EADDRINUSE|port/i.test(text) ? 'port_busy' : 'failed' });
  } finally {
    clearTimeout(timer);
    process.exit(0);
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main();
