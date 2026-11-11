/**
 * What the local model gets to read, kept small (pippa-tools.ts registers both hooks). Every token of the fixed prefix
 * is evaluated again after each cold start, and a single tool result must not fill a 16k window.
 * No Pi imports, so the tests can load this file without a Pi payload.
 */

/**
 * Short parameter texts for the Pi built-in tools Pippa turns on (PippaPiLaunch.tools; Pi 1.1.0: edit alone ~190
 * tokens, most of it parameter texts). Pi has no hook for parameter descriptions (`prepareLoadout` changes only the
 * tool description), so `shortenParameters`
 * replaces them in the provider request; "" drops a text the name already says. Only `description` strings change,
 * never the schema; payloads of an unknown shape stay untouched.
 */
export const BUILTIN_PARAMETERS: Record<string, Record<string, string>> = {
	read: { path: "", offset: "First line (1-based).", limit: "Number of lines." },
	bash: { command: "", timeout: "Seconds." },
	edit: { path: "", edits: "Replacements, each matched against the original file; they must not overlap.", oldText: "Exact text, unique in the file.", newText: "" },
	write: { path: "", content: "" },
};

/** The provider request with `BUILTIN_PARAMETERS` applied; `undefined` = nothing to change (keep Pi's payload). */
export function shortenParameters(payload: any): any {
	if (!payload || !Array.isArray(payload.tools)) return undefined;
	let changed = false;
	const shorten = (schema: any, texts: Record<string, string>): any => {
		if (!schema || typeof schema !== "object" || !schema.properties || typeof schema.properties !== "object") return schema;
		const properties: Record<string, any> = {};
		for (const [key, property] of Object.entries<any>(schema.properties)) {
			let next = property;
			if (next && typeof next === "object") {
				const text = texts[key];
				if (typeof next.description === "string" && text !== undefined && next.description !== text) {
					next = { ...next, description: text };
					if (!text) delete next.description;
					changed = true;
				}
				if (next.items) next = { ...next, items: shorten(next.items, texts) };
			}
			properties[key] = next;
		}
		return { ...schema, properties };
	};
	const tools = payload.tools.map((tool: any) => {
		// OpenAI chat completions: {type, function: {name, parameters}}; Responses API: {name, parameters}; Anthropic: {name, input_schema}.
		const fn = tool?.function ?? tool;
		const texts = BUILTIN_PARAMETERS[fn?.name];
		if (!texts) return tool;
		const key = fn.parameters ? "parameters" : fn.input_schema ? "input_schema" : undefined;
		if (!key) return tool;
		const next = { ...fn, [key]: shorten(fn[key], texts) };
		return tool?.function ? { ...tool, function: next } : next;
	});
	return changed ? { ...payload, tools } : undefined;
}

/** The smallest cap `resultLimit` ever gives. */
export const SMALLEST_RESULT_LIMIT = 6_000;

/** Characters a `search_files` or `list_folder` result may take: always under the smallest cap, so `capResult` never
 * cuts their JSON (facts.mjs `fitting` drops whole entries instead). */
export const FACT_RESULT_CHARS = 5_500;

/**
 * Characters one tool result may bring into the conversation, from the model's context window: three quarters of a
 * character per token of context, so a single result takes about a quarter of the window at most
 * (16k → 12,288 characters, 32k and more → 24,000). Unknown window: as for 16k.
 */
export function resultLimit(contextWindow: unknown): number {
	const window = Number(contextWindow) > 0 ? Number(contextWindow) : 16_384;
	return Math.min(24_000, Math.max(SMALLEST_RESULT_LIMIT, Math.round(window * 0.75)));
}

/**
 * A text result cut to `limit` characters, with a sentence saying so (never silently). Pippa's MCP tools are skipped:
 * the app caps them itself (≤ 9,000 characters) and their JSON must stay whole. bash keeps the end (where errors and
 * results are, like Pi's own bash truncation), everything else the beginning (like Pi's read).
 * `undefined` = fits, nothing to change.
 *
 * `read` counts `offset` in lines, so its text is cut after a whole line and the note names the exact `offset` to read
 * on with. A note in characters made small models pass a character count as `offset` and loop on "beyond the end".
 * `input` is the call's arguments (its `offset` says which line the text starts at).
 */
export function capResult(toolName: string, content: unknown, limit: number, input?: Record<string, unknown>): any[] | undefined {
	if (toolName.startsWith("mcp__") || !Array.isArray(content)) return undefined;
	const total = content.reduce((n: number, part: any) => n + (part?.type === "text" ? String(part.text ?? "").length : 0), 0);
	if (total <= limit) return undefined;
	if (toolName === "read") {
		const texts = content.filter((part: any) => part?.type === "text");
		if (texts.length === 1) return capLines(content, texts[0], limit, Number(input?.offset) || 1, Number(input?.limit) > 0);
	}
	const keepEnd = toolName === "bash";
	const note = keepEnd
		? `[Only the last ${limit} of ${total} characters are shown; the rest did not fit the conversation.]\n`
		: `\n[Only the first ${limit} of ${total} characters are shown; the rest did not fit the conversation.]`;
	let budget = limit;
	const parts = keepEnd ? [...content].reverse() : [...content];
	const kept = parts.map((part: any) => {
		if (part?.type !== "text") return part;
		const text = String(part.text ?? "");
		const piece = keepEnd ? text.slice(Math.max(0, text.length - budget)) : text.slice(0, budget);
		budget -= piece.length;
		return { ...part, text: piece };
	}).filter((part: any) => part?.type !== "text" || part.text.length > 0);
	if (keepEnd) kept.reverse();
	const at = keepEnd ? kept.findIndex((part: any) => part?.type === "text") : kept.map((part: any) => part?.type).lastIndexOf("text");
	if (at >= 0) kept[at] = { ...kept[at], text: keepEnd ? note + kept[at].text : kept[at].text + note };
	return kept;
}

/** `read`'s one text part cut after the last whole line that fits; the note says which lines it shows and where to go on. */
function capLines(content: any[], part: any, limit: number, first: number, limited: boolean): any[] {
	const text = String(part.text ?? "");
	const lines = text.split("\n");
	let used = 0, count = 0;
	while (count < lines.length && used + lines[count].length + (count ? 1 : 0) <= limit) {
		used += lines[count].length + (count ? 1 : 0);
		count++;
	}
	const last = first + Math.max(count, 1) - 1;
	const end = first + lines.length - 1;
	// One line longer than the whole budget: its start, and the note says it was cut.
	const piece = count > 0 ? lines.slice(0, count).join("\n") : text.slice(0, limit);
	const cut = count === 0 ? ` Line ${first} is too long and was cut.` : "";
	const of = limited ? `of the requested lines ${first}-${end}` : `of ${end}`;
	const note = `\n[Shown: lines ${first}-${last} ${of}; the rest did not fit the conversation.${cut} `
		+ `To read on, call read again with offset ${last + 1} (offset counts lines, not characters).]`;
	return content.map((p: any) => p === part ? { ...part, text: piece + note } : p);
}
