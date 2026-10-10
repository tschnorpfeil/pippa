/**
 * Keeps the conversation's context small without the person waiting for it. Loaded by Pippa next to its other
 * extensions:
 *
 *   pi --mode rpc --extension …/pippa-context.ts …
 *
 * - Summarize while the person reads: Pi compacts on its own only when the context is nearly full, and then in the
 *   middle of an answer (16k: at 12,288 tokens, with the local model, so the person waits). Here Pi's own compaction
 *   (`ctx.compact`) starts after an answer, once the person has been quiet for `IDLE_MS` and the context is at least
 *   `SOFT_SHARE` full, with everyday instructions instead of Pi's coding format. Pi's threshold stays as the net. If the
 *   person asks something meanwhile, Pippa stops the summary first (PiRPCClient.prompt), so nothing is lost.
 * - Summaries without thinking: Pi summarizes at the conversation's thinking level, and Qwen's thinking can use up the
 *   summary's token cap (0.8 × reserveTokens, 3,276 at 16k) before the summary is written ("generation hit the token
 *   cap"). The level goes to `off` for the summary only and back right after, or at the latest before the next answer.
 * - Handover between topics: a new session (Pippa starts one by itself for a new topic) gets a short `<earlier>`
 *   section from the session the person used last, if that was within `HANDOVER_HOURS`: its last summary (its facts
 *   first), or the last question and answer, shortened. Read from Pi's session files, no model call; fixed for the session (prompt cache).
 */
import { readdir, readFile, stat } from "node:fs/promises";
import { join } from "node:path";

type ExtensionAPI = any;

export const SOFT_SHARE = 0.6;
export const IDLE_MS = 20_000;
export const HANDOVER_HOURS = 12;
export const HANDOVER_CHARS = 1200;

export const EVERYDAY_SUMMARY = "This is an everyday helper conversation, not programming. Write every entry in the "
	+ "language of the conversation (German conversation: German entries); keep the section headings as given. Keep exactly: "
	+ "names, dates, times, amounts and addresses that matter to the person; full paths of files the person showed or that "
	+ "were created; what was done (drafts, appointments, reminders, moved files); what is still open or was promised. "
	+ "Under Constraints & Preferences only what the person said about themselves in their own words: what they ask for in "
	+ "one request (a detailed answer, a list) is not a preference; when unsure, write (none). Leave out tool details and "
	+ "reasoning. Short plain sentences.";

/** Compact now? Only with a known size, at or above the soft share, and below Pi's own threshold region is fine too. */
export function shouldCompact(usage: { tokens: number | null; contextWindow: number } | undefined, share = SOFT_SHARE): boolean {
	if (!usage || usage.tokens == null || !usage.contextWindow) return false;
	return usage.tokens >= usage.contextWindow * share;
}

function textOf(message: any): string {
	const content = message?.content;
	if (typeof content === "string") return content;
	return (Array.isArray(content) ? content : []).filter((block: any) => block?.type === "text").map((block: any) => block.text ?? "").join("");
}

function cut(text: string, limit: number): string {
	const clean = text.replace(/\s+\n/g, "\n").trim();
	return clean.length > limit ? clean.slice(0, limit - 1).trimEnd() + "…" : clean;
}

/** Pi's summary sections (`## Heading`) in the order a handover needs them: the facts first, the bookkeeping last, empty
 * ones and "(none)" dropped, preferences too (the memory holds those). A summary without sections stays as it is. */
const HANDOVER_ORDER = ["critical context", "goal", "next steps", "progress", "key decisions"];
export function handoverSummary(summary: string): string {
	const parts = summary.split(/^(?=## )/m);
	if (parts.length < 2) return summary;
	const sections = parts.filter((part) => part.startsWith("## ")).map((part) => {
		const [heading, ...rest] = part.split("\n");
		const body = rest.map((line) => line.trimEnd()).filter((line) => line.trim() && !/^\s*-?\s*\(none\)\s*$/i.test(line)).join("\n");
		return { name: heading.slice(3).trim().toLowerCase(), heading: heading.trim(), body };
	}).filter((section) => section.body && section.name !== "constraints & preferences");
	const rank = (name: string) => { const i = HANDOVER_ORDER.indexOf(name); return i < 0 ? HANDOVER_ORDER.length : i; };
	return sections.sort((a, b) => rank(a.name) - rank(b.name)).map((section) => `${section.heading}\n${section.body}`).join("\n");
}

/** The handover text from a session file's JSONL, or `undefined` if it has nothing worth carrying. */
export function handoverFrom(jsonl: string, limit = HANDOVER_CHARS): string | undefined {
	let summary: string | undefined;
	let question: string | undefined;
	let answer: string | undefined;
	for (const line of jsonl.split("\n")) {
		if (!line.trim()) continue;
		let entry: any;
		try { entry = JSON.parse(line); } catch { continue; }
		if (entry?.type === "compaction" && typeof entry.summary === "string") {
			summary = entry.summary; question = undefined; answer = undefined;
		} else if (entry?.type === "message") {
			const role = entry.message?.role;
			const text = textOf(entry.message).trim();
			if (!text) continue;
			if (role === "user") { question = text; answer = undefined; }
			else if (role === "assistant") answer = text;
		}
	}
	const parts: string[] = [];
	if (summary) parts.push(cut(handoverSummary(summary), Math.floor(limit * 0.6)));
	if (question) parts.push(`Last question: ${cut(question, Math.floor(limit * 0.2))}`);
	if (answer) parts.push(`Last answer: ${cut(answer, Math.floor(limit * 0.4))}`);
	if (!parts.length) return undefined;
	return cut(parts.join("\n"), limit);
}

/** The session file the person used last before this one, if recent enough. */
export async function previousSession(directory: string, current: string | undefined, now = Date.now(), hours = HANDOVER_HOURS): Promise<string | undefined> {
	let names: string[];
	try { names = await readdir(directory); } catch { return undefined; }
	let best: { path: string; modified: number } | undefined;
	for (const name of names) {
		if (!name.endsWith(".jsonl")) continue;
		const path = join(directory, name);
		if (current && path === current) continue;
		try {
			const modified = (await stat(path)).mtimeMs;
			if (!best || modified > best.modified) best = { path, modified };
		} catch { continue; }
	}
	if (!best || now - best.modified > hours * 3_600_000) return undefined;
	return best.path;
}

export function handoverSection(text: string): string {
	return "From the person's previous conversation (another topic). Use it only if they refer back to it.\n" + text;
}

/** Does the session already hold a conversation (resumed)? Then it needs no handover. */
function hasMessages(sessionManager: any): boolean {
	try { return (sessionManager?.getEntries?.() ?? []).some((entry: any) => entry?.type === "message" && entry.message?.role === "user"); }
	catch { return true; }
}

export default function (pi: ExtensionAPI) {
	const idle = Number(process.env.PIPPA_COMPACT_IDLE_MS ?? IDLE_MS);
	let timer: ReturnType<typeof setTimeout> | undefined;
	const cancel = () => { if (timer) { clearTimeout(timer); timer = undefined; } };

	let earlier: string | undefined;
	let decided = false;
	// The thinking level to put back after a summary (also after a failed or stopped one, before the next answer).
	let restore: string | undefined;
	const putBack = () => {
		if (restore === undefined) return;
		try { pi.setThinkingLevel(restore); } catch { /* stale after a session switch */ }
		restore = undefined;
	};
	pi.on("session_before_compact", async () => {
		try {
			const level = pi.getThinkingLevel();
			if (level && level !== "off") { restore = restore ?? level; pi.setThinkingLevel("off"); }
		} catch { /* no thinking control: summarize as is */ }
	});
	pi.on("session_compact", async () => putBack());

	pi.on("session_start", async () => { decided = false; earlier = undefined; restore = undefined; });
	pi.on("before_agent_start", async (event: any, ctx: any) => {
		cancel();
		putBack();
		if (!decided) {
			decided = true;
			const manager = ctx?.sessionManager;
			if (manager && !hasMessages(manager)) {
				try {
					const file = await previousSession(manager.getSessionDir(), manager.getSessionFile());
					const text = file ? handoverFrom(await readFile(file, "utf8")) : undefined;
					earlier = text ? handoverSection(text) : undefined;
				} catch { earlier = undefined; }
			}
		}
		const sections = event?.systemPromptOptions?.sections;
		if (sections && earlier) sections.earlier = earlier;
	});

	pi.on("agent_start", async () => cancel());
	pi.on("agent_settled", async (event: any, ctx: any) => {
		cancel();
		if (event?.aborted) return;
		timer = setTimeout(() => {
			timer = undefined;
			try {
				if (!ctx?.isIdle?.() || ctx?.hasPendingMessages?.()) return;
				if (!shouldCompact(ctx.getContextUsage?.())) return;
				ctx.compact({ customInstructions: EVERYDAY_SUMMARY, onError: () => {} });
			} catch { /* stale context after a session switch: nothing to do */ }
		}, idle);
		timer.unref?.();
	});
	pi.on("session_shutdown", async () => { cancel(); putBack(); });
}
