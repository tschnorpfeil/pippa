/**
 * Small helps that keep a small local model on track. No permissions: Pi runs every tool without asking, this file only
 * steers. Loaded by Pippa next to its file tools:
 *
 *   pi --mode rpc --extension …/pippa-tools.ts --extension …/pippa-assist.ts
 *
 * - `read` on a PDF, Word file, image, mail or spreadsheet is sent to Pippa's document reader (`read_document`): `read`
 *   returns raw bytes, and K2 ran out of context mid-answer reading a PDF that way.
 * - Loop brake: small models repeat the very same call (K2 sent the same failing reminder_add 20 times, read one file
 *   200 times, added the same reminder four times). Per answer an identical call that already failed twice, an
 *   identical change that already worked once, or any identical call run four times is stopped; after three stops the
 *   answer ends (session entry `pippa-loop-stop`, so Pippa can tell it apart from the person's Stop).
 * - Call budget: a model can also wander without repeating itself (Qwen3.5 9B listed every folder and read all 21 PDFs
 *   when the search came back empty: 48 calls, 4 minutes, a wrong total). After `MAX_CALLS` tool calls in one answer
 *   every further call is stopped with the request to answer now; the measured tasks needed at most 14.
 * - File search results: `search_files` results become a session entry `pippa-search-result`, so Pippa shows the
 *   files found from the tool's output, never from the model's prose.
 * - Today's date: each new message starts with "[2026-10-09, Friday]". The system prompt has no date so it stays the
 *   same (prompt cache); without one K2 searched the weather for a wrong "tomorrow". The line is saved with the
 *   message, so earlier turns never change. ISO date, no sentence: the answer follows the question's language.
 */

type ExtensionAPI = any;

/** Files Pi's `read` only returns as raw bytes (or as an image the local model cannot see). */
const DOCUMENT_TYPES = /\.(pdf|docx?|pages|rtf|odt|xlsx?|numbers|key|pptx?|eml|emlx|msg|png|jpe?g|heic|heif|tiff?|gif|webp|bmp)$/i;

/** Tools that change something: the same successful change is not done twice in one answer. */
const CHANGES = new Set(["write", "edit", "move_files", "move_to_trash",
	"mcp__pippa__calendar_add", "mcp__pippa__reminder_add", "mcp__pippa__mail_draft"]);

/** `read` on a document: the reason that sends Pi to Pippa's document reader instead (text, OCR for scans). */
export function documentForRead(tool: string, input: any): string | undefined {
	if (tool !== "read") return undefined;
	const path = String(input?.path ?? input?.file_path ?? "");
	if (!DOCUMENT_TYPES.test(path)) return undefined;
	return `Not read: '${path.split("/").pop()}' is a document (PDF, Word, image, mail or spreadsheet); read gives raw bytes. Call mcp__pippa__read_document with the same path instead.`;
}

/** Tool calls per answer before Pi is told to answer with what it has (docs/rebuild/measurements/model-compare). */
export const MAX_CALLS = 20;

/** Over budget: the reason Pi gets instead of the call. */
export function overBudget(calls: number): string | undefined {
	if (calls <= MAX_CALLS) return undefined;
	return `Stopped: you already used ${MAX_CALLS} tool calls for this answer. Do not call any more tools. Answer the user now with what you found, and say in one short sentence what you could not check.`;
}

export interface LoopCount { runs: number; failures: number; successes: number }

/**
 * Loop brake for one answer: `undefined` lets the call run (and counts it), otherwise the reason Pi gets instead.
 * Identical means same tool and same arguments.
 */
export function loopBrake(counts: Map<string, LoopCount>, keys: Map<string, string>,
	toolCallId: string, tool: string, input: unknown, changes = false): string | undefined {
	let key: string;
	try { key = `${tool} ${JSON.stringify(input ?? {})}`; } catch { return undefined; }
	const count = counts.get(key) ?? { runs: 0, failures: 0, successes: 0 };
	if (changes && count.successes >= 1) {
		return `Stopped: this exact '${tool}' call already worked in this answer; doing it again would make a duplicate. It is done. Do not call it again; tell the user in one short sentence what was done.`;
	}
	if (count.failures >= 2) {
		return `Stopped: this exact '${tool}' call already failed ${count.failures} times in this answer. Do not repeat it. Change the arguments (read the error), take another way, or tell the user in one short sentence what did not work.`;
	}
	if (count.runs >= 4) {
		return `Stopped: you already ran this exact '${tool}' call ${count.runs} times in this answer; the result will not change. Use what you already have and answer the user now.`;
	}
	count.runs++;
	counts.set(key, count);
	keys.set(toolCallId, key);
	return undefined;
}

/** File locations from a search result, never inferred from the model's prose. */
export function searchFiles(content: any[]): string[] {
	const text = (content ?? []).filter((p) => p?.type === "text").map((p) => String(p.text ?? "")).join("\n");
	try {
		const result = JSON.parse(text);
		return Array.isArray(result.files) ? result.files.map((f: any) => f?.path).filter((p: any) => typeof p === "string" && p.startsWith("/")) : [];
	} catch {
		return text.split(/[\n\0]/).filter((p) => p.startsWith("/") && !/[\r\t]/.test(p));
	}
}

/** "[2026-10-09, Friday]": today in the Mac's time zone, in no particular language. */
export function todayLine(now: Date): string {
	const pad = (n: number) => String(n).padStart(2, "0");
	const weekday = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][now.getDay()];
	return `[${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}, ${weekday}]`;
}

/** The message with today's date in front; a skill button (`/skill:name text`) keeps its command first. */
export function withToday(text: string, line: string): string {
	if (!text.startsWith("/")) return `${line}\n${text}`;
	if (!text.startsWith("/skill:")) return text;
	const space = text.indexOf(" ");
	return space === -1 ? `${text} ${line}` : `${text.slice(0, space)} ${line}\n${text.slice(space + 1)}`;
}

export default function (pi: ExtensionAPI) {
	const counts = new Map<string, LoopCount>();
	const keys = new Map<string, string>();
	let stops = 0;
	let calls = 0;
	const searchCalls = new Set<string>();
	const found = new Set<string>();
	let searched = false;
	let truncated = false;
	const reset = () => { counts.clear(); keys.clear(); stops = 0; calls = 0; searchCalls.clear(); found.clear(); searched = false; truncated = false; };
	// Only a new message; a message sent while Pi is still working (steering) is shown back as typed.
	pi.on("input", async (event: any) => {
		if (event?.streamingBehavior || typeof event?.text !== "string") return { action: "continue" };
		return { action: "transform", text: withToday(event.text, todayLine(new Date())) };
	});
	pi.on("agent_start", async () => reset());
	pi.on("agent_end", async () => reset());

	pi.on("tool_call", async (event: any, ctx: any) => {
		const tool: string = event.toolName;
		const document = documentForRead(tool, event.input);
		if (document) return { block: true, reason: document };
		const loop = overBudget(++calls) ?? loopBrake(counts, keys, event.toolCallId, tool, event.input, CHANGES.has(tool));
		if (loop) {
			if (++stops === 3) {
				pi.appendEntry("pippa-loop-stop", { v: 1, tool, searched, files: [...found].slice(0, 200), truncated: truncated || found.size > 200 });
				ctx?.abort?.();
			}
			return { block: true, reason: loop };
		}
		if (tool === "search_files" || (tool === "bash" && /(^|\s)mdfind\b/.test(String(event.input?.command ?? "")))) {
			searchCalls.add(event.toolCallId);
			searched = true;
		}
		return undefined;
	});

	pi.on("tool_result", async (event: any) => {
		if (event.toolName === "search_files" && searchCalls.has(event.toolCallId)) {
			pi.appendEntry("pippa-search-result", { v: 1, files: searchFiles(event.content).slice(0, 200) });
		}
		if (searchCalls.delete(event.toolCallId)) {
			// Failed or time-limited searches may still return useful partial locations.
			for (const path of searchFiles(event.content)) if (found.size < 201) found.add(path);
			try {
				const text = (event.content ?? []).filter((p: any) => p?.type === "text").map((p: any) => p.text).join("\n");
				truncated ||= JSON.parse(text).truncated === true;
			} catch { /* Plain mdfind results have no structured truncation flag. */ }
		}
		const key = keys.get(event.toolCallId);
		keys.delete(event.toolCallId);
		const count = key ? counts.get(key) : undefined;
		if (count) { if (event.isError) count.failures++; else count.successes++; }
		return undefined;
	});
}
