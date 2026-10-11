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
 * - Search only through DuckDuckGo (no key, no account), as the privacy policy on heypippa.app says. `allowedProviders`
 *   makes every other provider fail even when the model names it, so a ChatGPT sign-in never turns into an OpenAI search.
 * - Only `web_search` and `fetch_content` (readable mode); no `get_search_content` (a small model rarely needs more than
 *   the page slice, and it saves its declaration); short page slices for small local
 *   models; no curator, no summaries by another model, no browser cookies, no GitHub clones, no video.
 * - Page addresses are fetched from this Mac only (pi-web-access keeps hosted fetchers off by default).
 *
 * Asking first (`ctx.ui.confirm`, shown by the app): the first search of an answer shows the person the exact search
 * text, and only after their OK does it go to DuckDuckGo; later searches in the same answer run. `fetch_content` reads
 * without asking only pages whose address came from this answer's search results or from the person's own message;
 * any other address (one a document or web page could have planted, e.g. `https://…/?iban=…`) is asked for, and this
 * Mac's own addresses (`localhost`, private networks, `file:`) are never read. No one to ask: nothing goes out.
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
	searchRouting: { providers: ["duckduckgo"], fallbackOn: ["transient", "quota", "network", "invalid-response"] },
	webSearch: { allowedProviders: ["duckduckgo"] },
	openaiSearchProviders: [],
	tools: {
		webSearch: { enabled: true },
		sourceCheck: { enabled: false },
		fetchContent: { enabled: true },
		getSearchContent: { enabled: false },
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
		description: "Search the web; results with links.",
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

/** The http(s) addresses in a text (search results, the person's message), without trailing punctuation. */
export function addressesIn(text: string): string[] {
	return (text.match(/https?:\/\/[^\s<>"'`)\]]+/gi) ?? []).map((url) => url.replace(/[.,;:!?…]+$/, ""));
}

/** Why an address is never read: this Mac or its local network, or not a web page at all; `undefined` = a web address. */
export function localAddress(raw: string): string | undefined {
	let url: URL;
	try { url = new URL(raw); } catch { return "not a web address"; }
	if (url.protocol !== "http:" && url.protocol !== "https:") return "not a web page";
	const host = url.hostname.toLowerCase().replace(/^\[|\]$/g, "");
	if (host === "localhost" || host.endsWith(".localhost") || host.endsWith(".local") || host === "0.0.0.0" || host === "::" || host === "::1") return "this Mac";
	const ip = host.match(/^(\d+)\.(\d+)\.(\d+)\.(\d+)$/)?.slice(1).map(Number);
	if (ip && (ip[0] === 127 || ip[0] === 10 || (ip[0] === 172 && ip[1] >= 16 && ip[1] <= 31) || (ip[0] === 192 && ip[1] === 168) || (ip[0] === 169 && ip[1] === 254) || ip[0] === 0)) return "the local network";
	if (/^(fc|fd|fe80)/.test(host) && host.includes(":")) return "the local network";
	return undefined;
}

/** Same page, ignoring a trailing slash and the `#…` part, so a result link and the call's address match. */
export function samePage(url: string): string {
	return url.replace(/#.*$/, "").replace(/\/$/, "").toLowerCase();
}

/** The question Pippa shows, in the app's language: first everyday words, then what exactly would go out. */
export function webAskText(kind: "search" | "page", detail: string[], language = process.env.PIPPA_LANGUAGE ?? ""): { title: string; message: string } {
	const de = language.startsWith("de");
	const shown = detail.slice(0, 3).map((d) => (d.length > 200 ? d.slice(0, 199) + "…" : d));
	if (kind === "search") {
		return de
			? { title: "Darf Pippa im Internet suchen?", message: `Pippa möchte bei DuckDuckGo suchen nach:\n\n${shown.map((q) => `„${q}“`).join("\n")}` }
			: { title: "May Pippa search the web?", message: `Pippa wants to search DuckDuckGo for:\n\n${shown.map((q) => `“${q}”`).join("\n")}` };
	}
	const hosts = [...new Set(shown.map((u) => { try { return new URL(u).hostname; } catch { return u; } }))];
	return de
		? { title: "Darf Pippa diese Webseite öffnen?", message: `Die Adresse kommt nicht aus deiner Nachricht und nicht aus einer Suche:\n\n${hosts.join("\n")}\n\n${shown.join("\n")}` }
		: { title: "May Pippa open this web page?", message: `The address is not from your message or from a search:\n\n${hosts.join("\n")}\n\n${shown.join("\n")}` };
}

export const WEB_DECLINED_REASON = "Not done: the person said no. Do not try another way to reach the internet; answer with what you have and say in one short sentence that you did not look it up.";
export const WEB_NO_ONE_TO_ASK_REASON = "Not done: going online needs the person's OK, and there is no one to ask right now. Answer without the web.";

/**
 * Asking before anything goes online, per answer: whether the person allowed searching, and the page addresses that
 * may be read without asking. `toolCall` also repairs a broken `queries` string. Wired to Pi's events below.
 */
export function webGuard() {
	let searchAllowed = false;
	const known = new Set<string>();
	let message = "";
	const reset = () => { searchAllowed = false; known.clear(); for (const url of addressesIn(message)) known.add(samePage(url)); };
	const ask = async (ctx: any, kind: "search" | "page", detail: string[]): Promise<string | undefined> => {
		if (!ctx?.hasUI || !ctx?.ui?.confirm) return WEB_NO_ONE_TO_ASK_REASON;
		const { title, message } = webAskText(kind, detail);
		return (await ctx.ui.confirm(title, message)) ? undefined : WEB_DECLINED_REASON;
	};
	return {
		input(event: any): undefined {
			if (typeof event?.text === "string" && !event?.streamingBehavior) message = event.text;
			return undefined;
		},
		agentStart() { reset(); },
		agentEnd() { message = ""; reset(); },
		async toolCall(event: any, ctx: any): Promise<{ block: true; reason: string } | undefined> {
			if (!event?.input) return undefined;
			if (event.toolName === "web_search") {
				const repaired = repairQueries(event.input);
				if ("reason" in repaired) return { block: true, reason: repaired.reason };
				if (repaired.input !== event.input) Object.assign(event.input, repaired.input);
				if (searchAllowed) return undefined;
				const queries = [event.input.query, ...(Array.isArray(event.input.queries) ? event.input.queries : [])]
					.filter((q: unknown): q is string => typeof q === "string" && q.trim() !== "");
				const no = await ask(ctx, "search", queries);
				if (no) return { block: true, reason: no };
				searchAllowed = true;
				return undefined;
			}
			if (event.toolName === "fetch_content") {
				const urls = [event.input.url, ...(Array.isArray(event.input.urls) ? event.input.urls : [])]
					.filter((u: unknown): u is string => typeof u === "string" && u.trim() !== "");
				for (const url of urls) {
					const local = localAddress(url);
					if (local) return { block: true, reason: `Not read: ${url} is ${local}; Pippa only reads web pages. Answer without it.` };
				}
				const unknown = urls.filter((url) => !known.has(samePage(url)));
				if (!unknown.length) return undefined;
				const no = await ask(ctx, "page", unknown);
				if (no) return { block: true, reason: no };
				for (const url of unknown) known.add(samePage(url));
			}
			return undefined;
		},
		/** Links in search results may be read in this answer without asking again. */
		toolResult(event: any): undefined {
			if (event?.toolName !== "web_search" || event.isError) return undefined;
			const text = (event.content ?? []).filter((p: any) => p?.type === "text").map((p: any) => String(p.text ?? "")).join("\n");
			for (const url of addressesIn(text)) known.add(samePage(url));
			return undefined;
		},
	};
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

	const guard = webGuard();
	pi.on("input", async (event: any) => guard.input(event));
	pi.on("agent_start", async () => guard.agentStart());
	pi.on("agent_end", async () => guard.agentEnd());
	pi.on("tool_call", async (event: any, ctx: any) => guard.toolCall(event, ctx));
	pi.on("tool_result", async (event: any) => guard.toolResult(event));
}
