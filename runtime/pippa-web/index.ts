/**
 * Pippa's web access for Pi: the pinned Pi package pi-web-access (search and read pages), loaded with Pippa's own
 * settings instead of the person's.
 *
 *   pi --mode rpc --extension …/pippa-web/index.ts
 *
 * pi-web-access reads `web-search.json` from Pi's agent folder, which Pippa shares with the person's terminal Pi. So
 * this file writes Pippa's settings (`SETTINGS`) into Pippa's own folder (`PIPPA_WEB_DIR`, default
 * `~/Library/Application Support/Pippa/pi-web`) and points pi-web-access there while it loads. pi-web-access resolves
 * its config path once at import; afterwards the environment is put back, so bash commands do not inherit it.
 *
 * The settings:
 * - Search only through Exa (no key needed), DuckDuckGo if Exa fails. `allowedProviders` makes every other provider
 *   fail even when the model names it, so a ChatGPT sign-in never turns into an OpenAI search.
 * - Only `web_search`, `fetch_content` (readable mode) and `get_search_content`; short page slices for small local
 *   models; no curator, no summaries by another model, no browser cookies, no GitHub clones, no video.
 * - Page addresses are fetched from this Mac only (pi-web-access keeps hosted fetchers off by default).
 *
 * Model input repair (pi-web-access #542): a small model sometimes sends `queries` as a JSON string with a missing
 * quote. pi-web-access then searches for the broken text literally. `repairQueries` turns it into a list, or blocks
 * the call with a reason the model understands.
 *
 * Short declarations (`DECLARATIONS`): pi-web-access declares every option it knows (proxies, video frames, Gemini,
 * browser cookies, curator), ~1,500 tokens, more than all of Pippa's other tools together. Most are switched off in
 * `SETTINGS` anyway. `leanDeclarations` sends the model only what Pippa uses; pi-web-access still accepts its full
 * input, so nothing about running a call changes.
 */
import { mkdirSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

type ExtensionAPI = any;

export const SETTINGS = {
	searchRouting: { providers: ["exa", "duckduckgo"], fallbackOn: ["transient", "quota", "network", "invalid-response"] },
	webSearch: { allowedProviders: ["exa", "duckduckgo"] },
	openaiSearchProviders: [],
	tools: {
		webSearch: { enabled: true },
		sourceCheck: { enabled: false },
		fetchContent: { enabled: true },
		getSearchContent: { enabled: true },
	},
	toolActivation: "eager",
	workflow: "none",
	fetch: { defaultMode: "readable", allowedModes: ["readable"], timeout: 20 },
	fetchRouting: { allowRemoteHostedProviders: false },
	maxInlineContentChars: 6000,
	commands: { websearch: { enabled: false }, curator: { enabled: false }, search: { enabled: false }, "google-account": { enabled: false } },
	image: { enabled: false },
	githubClone: { enabled: false },
	githubPrIssue: { enabled: false },
	allowBrowserCookies: false,
};

const text = { type: "string" };
const texts = { type: "array", items: text };

/** What the model sees of the web tools: one description and the parameters Pippa uses. */
export const DECLARATIONS: Record<string, { description: string; parameters: Record<string, unknown> }> = {
	web_search: {
		description: "Search the web; results with links. More of a result: get_search_content with its responseId.",
		parameters: { type: "object", properties: {
			query: text,
			queries: { ...texts, description: "Up to three different searches at once." },
			recencyFilter: { type: "string", enum: ["day", "week", "month", "year"] },
		} },
	},
	fetch_content: {
		description: "Read a web page as text; urls for several at once.",
		parameters: { type: "object", properties: { url: text, urls: texts } },
	},
	get_search_content: {
		description: "Read more of a result stored by web_search or fetch_content.",
		parameters: { type: "object", required: ["responseId"], properties: {
			responseId: text,
			url: text,
			offset: { type: "integer", description: "Character to continue from." },
			findText: { ...text, description: "Return only passages with this text." },
		} },
	},
};

/** The provider request with `DECLARATIONS` for the web tools; `undefined` = nothing to change (keep Pi's payload). */
export function leanDeclarations(payload: any): any {
	if (!payload || !Array.isArray(payload.tools)) return undefined;
	let changed = false;
	const tools = payload.tools.map((tool: any) => {
		// OpenAI chat completions: {type, function: {name, parameters}}; Responses API: {name, parameters}; Anthropic: {name, input_schema}.
		const fn = tool?.function ?? tool;
		const lean = DECLARATIONS[fn?.name];
		const key = fn?.parameters ? "parameters" : fn?.input_schema ? "input_schema" : undefined;
		if (!lean || !key || (fn.description === lean.description && fn[key] === lean.parameters)) return tool;
		changed = true;
		const next = { ...fn, description: lean.description, [key]: lean.parameters };
		return tool?.function ? { ...tool, function: next } : next;
	});
	return changed ? { ...payload, tools } : undefined;
}

/** Pippa's folder for `web-search.json` and the page cache. */
export function settingsDirectory(env: Record<string, string | undefined>): string {
	return env.PIPPA_WEB_DIR || join(homedir(), "Library", "Application Support", "Pippa", "pi-web");
}

/** Writes `SETTINGS` where pi-web-access will look: Pippa's folder, or `PI_CODING_AGENT_DIR` (test runs only). */
export function writeSettings(env: Record<string, string | undefined>): { home: string; configDirectory: string } {
	const home = settingsDirectory(env);
	const configDirectory = env.PI_CODING_AGENT_DIR || join(home, "pi");
	mkdirSync(configDirectory, { recursive: true, mode: 0o700 });
	writeFileSync(join(configDirectory, "web-search.json"), JSON.stringify(SETTINGS, null, "\t") + "\n", { mode: 0o600 });
	return { home, configDirectory };
}

/**
 * `queries` as a string: a JSON list, a JSON list with one missing quote before `]`, or a single query.
 * Returns the repaired input, or a reason to block with.
 */
export function repairQueries(input: Record<string, unknown>): { input: Record<string, unknown> } | { reason: string } {
	const value = input.queries;
	if (typeof value !== "string") return { input };
	const text = value.trim();
	if (!text.startsWith("[")) return { input: { ...input, queries: [text] } };
	for (const candidate of [text, text.replace(/([^"\s])\s*\]$/, '$1"]')]) {
		try {
			const parsed = JSON.parse(candidate);
			if (Array.isArray(parsed) && parsed.length > 0 && parsed.every((item) => typeof item === "string" && item.trim())) {
				return { input: { ...input, queries: parsed } };
			}
		} catch {}
	}
	return { reason: "queries must be a list of search texts, e.g. [\"Wetter Berlin morgen\"]. Nothing was searched; call web_search again." };
}

export default async function (pi: ExtensionAPI) {
	const { home, configDirectory } = writeSettings(process.env);
	const saved = process.env.XDG_CONFIG_HOME;
	process.env.XDG_CONFIG_HOME = home;
	if (!process.env.PI_WEB_ACCESS_CACHE_ROOT) process.env.PI_WEB_ACCESS_CACHE_ROOT = configDirectory;
	try {
		const { default: webAccess } = await import("pi-web-access/dist/index.js");
		await webAccess(pi);
	} finally {
		if (saved === undefined) delete process.env.XDG_CONFIG_HOME;
		else process.env.XDG_CONFIG_HOME = saved;
	}
	pi.on("before_provider_request", (event: any) => leanDeclarations(event?.payload));
	pi.on("tool_call", async (event: any) => {
		if (event.toolName !== "web_search" || !event.input) return;
		const repaired = repairQueries(event.input);
		if ("reason" in repaired) return { block: true, reason: repaired.reason };
		if (repaired.input !== event.input) Object.assign(event.input, repaired.input);
	});
}
