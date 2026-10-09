// Variants of the K2 vs. Qwen3.5-9B comparison. Server arguments mirror LlamaServer.arguments (Pi path: alias set,
// no --reasoning off), models.json fields mirror PiReasoningStyle.modelFields as PiInstaller writes them
// (PiSetupSpike --install-only), context as Pippa uses it from 24 GB (32768, one slot).
// The only addition for Qwen is Pi's own `samplingParamsByThinkingLevel` (models.md), so B and C get the sampling the
// comparison prescribes per request while the server stays the same.
import { execFileSync } from 'node:child_process';
import { homedir } from 'node:os';
import { join } from 'node:path';

export const CTX = 32768;
const models = process.env.PIPPA_MC_MODELS ?? join(homedir(), 'pi-bench-models');

const k2Fields = {
 reasoning: true,
 thinkingLevelMap: { off: 'high', minimal: null, low: 'high', medium: 'medium', high: 'high', xhigh: null, max: null },
 compat: { thinkingFormat: 'chat-template', chatTemplateKwargs: { reasoning_effort: { $var: 'thinking.effort' }, tool_call_format: 'xml' } },
};
const qwenFields = {
 reasoning: true,
 thinkingLevelMap: { off: 'off', minimal: null, low: null, medium: 'medium', high: null, xhigh: null, max: null },
 compat: { thinkingFormat: 'qwen-chat-template' },
};
const qwenSampling = {
 samplingParamsByThinkingLevel: {
  medium: { temperature: 0.6, top_p: 0.95, top_k: 20 },
  off: { temperature: 0.7, top_p: 0.8, presence_penalty: 1.5 },
 },
};

const k2 = {
 key: 'k2-horizon-7b',
 file: join(models, 'K2-Horizon-7B-Q4_K_M.gguf'),
 sha256: 'eb89c15a0ae9712be2ee462bf43802de14200f20f93b73da6eb68c2ebdd28e4e',
 // catalog.json: sampling (sorted keys as LlamaServer passes them) and extra.
 serverExtra: ['--min-p', '0', '--temp', '0.6', '--top-k', '0', '--top-p', '0.95',
  '--chat-template-kwargs', '{"reasoning_effort":"low","tool_call_format":"xml"}'],
 fields: k2Fields,
};
const qwen = {
 key: 'qwen3.5-9b-q4',
 file: join(models, 'Qwen3.5-9B-Q4_K_M.gguf'),
 sha256: '03b74727a860a56338e042c4420bb3f04b2fec5734175f4cb9fa853daf52b7e8',
 serverExtra: [], // catalog.json has no sampling/extra for this entry
 fields: { ...qwenFields, ...qwenSampling },
};

export const VARIANTS = {
 A: { ...k2, label: 'A', thinking: 'medium', note: 'K2 as in Pippa: reasoning medium, temp 0.6 (server)' },
 B: { ...qwen, label: 'B', thinking: 'medium', note: 'Qwen3.5-9B thinking on: temp 0.6, top_p 0.95, top_k 20 (request)' },
 C: { ...qwen, label: 'C', thinking: 'off', note: 'Qwen3.5-9B thinking off: temp 0.7, top_p 0.8, presence_penalty 1.5 (request)' },
};

/** Fixed template variants, only used if B/C fail on the chat template (labelled separately). */
export function withTemplate(variant, template) {
 return { ...variant, label: variant.label + '2', serverExtra: [...variant.serverExtra, '--chat-template-file', template], note: variant.note + ', fixed template' };
}

export function modelEntry(v) {
 return { id: v.key, name: v.key, contextWindow: CTX, maxTokens: 4096, ...v.fields };
}

export function modelsJson(v, baseUrl) {
 return { providers: { 'pippa-local': { baseUrl, api: 'openai-completions', apiKey: 'none', models: [modelEntry(v)] } } };
}

/** Pi settings as PiModelTuning.merge writes them for this model (32k: reserve 4096, keep 12288). */
export function piSettings(v) {
 const key = `pippa-local/${v.key}`;
 return {
  defaultProjectTrust: 'never', quietStartup: true,
  compaction: { modelOverrides: { [key]: { reserveTokens: Math.min(4096, CTX / 4), keepRecentTokens: CTX * 3 / 8 } } },
  modelThinkingLevels: { [key]: v.thinking },
 };
}

export function serverArgs(v, port) {
 return ['-m', v.file, '--host', '127.0.0.1', '--port', String(port), '--jinja', '--ctx-size', String(CTX), '--parallel', '1',
  '--alias', v.key, '--no-webui', '--cache-type-k', 'q8_0', '--cache-type-v', 'q8_0', ...v.serverExtra];
}

export function load1() {
 return Number(execFileSync('/usr/sbin/sysctl', ['-n', 'vm.loadavg'], { encoding: 'utf8' }).trim().replace(/[{}]/g, '').trim().split(/\s+/)[0]);
}
