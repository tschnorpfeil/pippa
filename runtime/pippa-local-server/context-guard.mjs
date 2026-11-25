// Keeps the context of Pippa's local model (provider `pippa-local`) small enough to answer. Shared, byte for byte, by
// Terminal Pi (runtime/pippa-local-server) and the Pippa app (runtime/pippa-tools); no imports, so each copy stands alone.
//
// Three hooks, all Pi 1.6.0 session boundaries or results, all only for `pippa-local`:
//
// - `turn_end`: a finished `write` or `edit` call carries the whole file text in its arguments, and every later request
//   sends it again (a 20 KB HTML page is ~6k tokens of a 32k window). Once the call succeeded, a `context_edit` swaps
//   oversized texts for a short stub. Only the newest turn is edited, so the server's prefix cache of earlier turns
//   stays valid; Pi's projection and compaction see the stub too. Failed calls stay whole: the model needs its text to
//   try again.
// - `tool_result` (Terminal Pi only; the app caps results in budget.ts): one result must not fill the window.
// - `agent_before_settle`: a length-truncated answer that Pi omitted for its compact-and-retry, but whose compaction
//   found nothing to cut (prepareCompaction() is undefined when keepRecentTokens keeps the whole tail after the last
//   compaction), leaves every next request just as full: max_tokens stays tiny and the next answer is cut again.
//   Once per run, a factual compaction (no model call) replaces that tail and the run continues.

const PROVIDER = "pippa-local";
const DEFAULT_WINDOW = 32_768;
/** Texts this short are never stubbed, whatever the limit. */
const STUB_MIN_CHARS = 256;
/** A trailing user prompt up to this size is kept verbatim after a rescue compaction. */
const KEEP_PROMPT_CHARS = 4_000;
const SUMMARY_PART_CHARS = 2_000;
const MAX_LISTED_FILES = 20;

function windowOf(contextWindow) {
	const window = Number(contextWindow);
	return window > 0 ? window : DEFAULT_WINDOW;
}

/** Characters a write/edit argument may keep in context: an eighth of the window in tokens (32k → 4,096). */
export function writeArgLimit(contextWindow) {
	return Math.max(1_024, Math.floor(windowOf(contextWindow) / 8));
}

/** Characters one tool result may bring in: half of the window in tokens, at most 16,000 (16k → 8,192, 32k → 16,000). */
export function resultCharLimit(contextWindow) {
	return Math.min(16_000, Math.max(4_000, Math.round(windowOf(contextWindow) * 0.5)));
}

function stub(kind, text, path) {
	const where = typeof path === "string" && path ? ` for ${path}` : "";
	return `[${kind} of ${text.length} characters${where} omitted from the conversation to save context; read the file to see it.]`;
}

function stubWrite(args, limit) {
	if (typeof args.content !== "string" || args.content.length <= limit) return undefined;
	return { ...args, content: stub("Content", args.content, args.path) };
}

function stubEdit(args, limit) {
	const fields = ["oldText", "newText"];
	const textsOf = (o) => fields.map((f) => (typeof o?.[f] === "string" ? o[f] : ""));
	const edits = Array.isArray(args.edits) ? args.edits : [];
	const total = [...textsOf(args), ...edits.flatMap(textsOf)].reduce((n, t) => n + t.length, 0);
	if (total <= limit) return undefined;
	let changed = false;
	const shrink = (o) => {
		if (!o || typeof o !== "object") return o;
		const out = { ...o };
		for (const f of fields) {
			if (typeof o[f] === "string" && o[f].length > STUB_MIN_CHARS) {
				out[f] = stub(f, o[f], args.path);
				changed = true;
			}
		}
		return out;
	};
	const next = shrink(args);
	if (edits.length) next.edits = edits.map(shrink);
	return changed ? next : undefined;
}

/**
 * The assistant content with oversized `write`/`edit` arguments stubbed, for calls whose result succeeded.
 * `undefined` = nothing to change. Every other block, and every call's id and name, stays as it was.
 */
export function stubLargeToolCalls(content, toolResults, limit) {
	if (!Array.isArray(content)) return undefined;
	const succeeded = new Set((toolResults ?? []).filter((r) => r && r.isError !== true).map((r) => r.toolCallId));
	let changed = false;
	const next = content.map((block) => {
		if (block?.type !== "toolCall" || !succeeded.has(block.id)) return block;
		const args = block.arguments;
		if (!args || typeof args !== "object") return block;
		const stubbed = block.name === "write" ? stubWrite(args, limit) : block.name === "edit" ? stubEdit(args, limit) : undefined;
		if (!stubbed) return block;
		changed = true;
		return { ...block, arguments: stubbed };
	});
	return changed ? next : undefined;
}

function textLength(content) {
	if (typeof content === "string") return content.length;
	if (!Array.isArray(content)) return 0;
	return content.reduce((n, part) => n + (part?.type === "text" ? String(part.text ?? "").length : 0), 0);
}

/**
 * A text tool result cut to the window, with a sentence saying so. `bash` keeps the end (errors and results), `read`
 * keeps whole lines from the start and names the `offset` to read on with, anything else keeps the start. Pippa's MCP
 * tools (`mcp__*`) are skipped: their JSON must stay whole. `undefined` = fits.
 */
export function capTerminalToolResult(toolName, content, contextWindow, input) {
	const name = String(toolName ?? "");
	if (name.startsWith("mcp__") || !Array.isArray(content)) return undefined;
	const limit = resultCharLimit(contextWindow);
	const total = textLength(content);
	if (total <= limit) return undefined;
	const texts = content.filter((part) => part?.type === "text");
	if (name === "read" && texts.length === 1) {
		const text = String(texts[0].text ?? "");
		const cut = text.lastIndexOf("\n", limit);
		if (cut > 0) {
			const kept = text.slice(0, cut);
			const lines = kept.split("\n").length;
			const first = Number(input?.offset) > 0 ? Number(input.offset) : 1;
			const note = `\n[Only lines ${first}-${first + lines - 1} are shown; the rest did not fit the conversation. Use offset=${first + lines} to read on.]`;
			return content.map((part) => (part === texts[0] ? { ...part, text: kept + note } : part));
		}
	}
	const keepEnd = name === "bash";
	let budget = limit;
	const parts = keepEnd ? [...content].reverse() : [...content];
	const kept = parts.map((part) => {
		if (part?.type !== "text") return part;
		const text = String(part.text ?? "");
		const piece = keepEnd ? text.slice(Math.max(0, text.length - budget)) : text.slice(0, budget);
		budget -= piece.length;
		return { ...part, text: piece };
	}).filter((part) => part?.type !== "text" || part.text.length > 0);
	if (keepEnd) kept.reverse();
	const note = keepEnd
		? `[Only the last ${limit} of ${total} characters are shown; the rest did not fit the conversation.]\n`
		: `\n[Only the first ${limit} of ${total} characters are shown; the rest did not fit the conversation.]`;
	const at = keepEnd ? kept.findIndex((p) => p?.type === "text") : kept.map((p) => p?.type).lastIndexOf("text");
	if (at >= 0) kept[at] = { ...kept[at], text: keepEnd ? note + kept[at].text : kept[at].text + note };
	return kept;
}

function clip(text, max) {
	return text.length <= max ? text : `${text.slice(0, max)} […]`;
}

function plainText(content) {
	if (typeof content === "string") return content;
	if (!Array.isArray(content)) return "";
	return content.filter((p) => p?.type === "text").map((p) => String(p.text ?? "")).join("\n");
}

const isMessage = (entry) => entry?.type === "message" && entry.message;

/**
 * The rescue for a length-truncation deadlock on this branch, or `undefined`: the newest assistant message stopped at
 * `length`, Pi omitted it (`context_edit` with `replacement: null`), and no compaction followed. The result is a
 * compaction draft whose summary is built from the branch alone. A short user prompt right before the cut-off answer
 * stays as `firstKeptEntryId`; anything else (a tool result, whose call would be summarized away, or a long prompt)
 * gives `firstKeptEntryId: null`, so the context restarts at the summary and no old usage figure limits max_tokens.
 */
export function buildLengthDeadlockRescue(branch) {
	if (!Array.isArray(branch)) return undefined;
	let index = -1;
	for (let i = branch.length - 1; i >= 0; i--) {
		if (isMessage(branch[i]) && branch[i].message.role === "assistant") { index = i; break; }
	}
	if (index < 0) return undefined;
	const assistant = branch[index];
	if (assistant.message.stopReason !== "length") return undefined;
	const after = branch.slice(index + 1);
	if (after.some((e) => e?.type === "compaction")) return undefined;
	if (!after.some((e) => e?.type === "context_edit" && e.targetId === assistant.id && e.replacement === null)) return undefined;

	let previous;
	for (let i = index - 1; i >= 0; i--) {
		const e = branch[i];
		if (isMessage(e) && e.message.role !== "system") { previous = e; break; }
		if (e?.type === "compaction" || e?.type === "branch_summary" || e?.type === "custom_message") break;
	}
	const prompt = previous?.message.role === "user" ? previous : undefined;
	const promptContent = prompt?.message.content;
	const keepPrompt = prompt !== undefined
		&& (typeof promptContent === "string" || (Array.isArray(promptContent) && promptContent.every((p) => p?.type === "text")))
		&& textLength(promptContent) <= KEEP_PROMPT_CHARS;
	const firstKeptEntryId = keepPrompt ? prompt.id : null;

	let lastCompaction = -1;
	for (let i = index - 1; i >= 0; i--) if (branch[i]?.type === "compaction") { lastCompaction = i; break; }
	// What the context still showed: the latest compaction's kept tail (it may start before that compaction) and on.
	let start = lastCompaction + 1;
	if (lastCompaction >= 0) {
		const kept = branch.findIndex((e) => e?.id === branch[lastCompaction].firstKeptEntryId);
		if (kept >= 0 && kept < lastCompaction) start = kept;
	}
	const files = [];
	const requests = [];
	let lastTool;
	for (const e of branch.slice(start, index)) {
		if (!isMessage(e)) continue;
		const m = e.message;
		if (m.role === "assistant" && Array.isArray(m.content)) {
			for (const b of m.content) {
				const path = b?.type === "toolCall" && (b.name === "write" || b.name === "edit") ? b.arguments?.path : undefined;
				if (typeof path === "string" && !files.includes(path)) files.push(path);
			}
		}
		if (m.role === "user" && e !== (keepPrompt ? prompt : undefined)) {
			const text = plainText(m.content).trim();
			if (text) requests.push(text);
		}
		if (m.role === "toolResult") {
			const text = plainText(m.content).trim();
			if (text) lastTool = { name: String(m.toolName ?? "tool"), isError: m.isError === true, text };
		}
	}

	const lines = [
		"Pippa reset the conversation context: the model's last answer was cut off because the context window was full, and compaction found nothing to shorten. The earlier messages are no longer visible.",
	];
	const earlier = lastCompaction >= 0 ? String(branch[lastCompaction].summary ?? "").trim() : "";
	if (earlier) lines.push("", "Summary before that:", clip(earlier, SUMMARY_PART_CHARS));
	if (requests.length) lines.push("", "Requests since then (oldest first):", ...requests.slice(-3).map((t) => `- ${clip(t, SUMMARY_PART_CHARS / 2)}`));
	if (files.length) lines.push("", "Files written or edited since then (read them for their current content):", ...files.slice(-MAX_LISTED_FILES).map((p) => `- ${p}`));
	if (!keepPrompt && lastTool) {
		const status = lastTool.isError ? " (error)" : "";
		lines.push("", `Last tool result (${lastTool.name}${status}):`, clip(lastTool.text, SUMMARY_PART_CHARS / 2));
	}
	lines.push("", keepPrompt ? "Continue with the request that follows." : "Continue with the latest request.");
	return { type: "compaction", summary: lines.join("\n"), firstKeptEntryId };
}

const isLocal = (ctx) => ctx?.model?.provider === PROVIDER;

/**
 * Register the guard. `capToolResults`: also cap tool results (Terminal Pi; the app does it in budget.ts).
 * Handlers only add to `event.entries`, so a second copy of the guard in the same Pi never adds the same draft twice.
 */
export function registerLocalContextGuard(pi, { capToolResults = false } = {}) {
	let rescued = false;

	// Reset only after the whole run settles (not on agent_start, which fires again on agent.continue()).
	pi.on("agent_settled", () => {
		rescued = false;
		return undefined;
	});

	pi.on("turn_end", (event, ctx) => {
		if (!isLocal(ctx) || event?.message?.role !== "assistant" || !event.messageEntryId) return undefined;
		const drafts = Array.isArray(event.entries) ? event.entries : [];
		if (drafts.some((d) => d?.type === "context_edit" && d.targetId === event.messageEntryId)) return undefined;
		const content = stubLargeToolCalls(event.message.content, event.toolResults, writeArgLimit(ctx.model.contextWindow));
		if (!content) return undefined;
		return { entries: [...drafts, { type: "context_edit", targetId: event.messageEntryId, replacement: { content } }] };
	});

	if (capToolResults) {
		pi.on("tool_result", (event, ctx) => {
			// A script's own calls never enter the conversation; only its output is capped, as a top-level result.
			if (!isLocal(ctx) || event?.parentToolCallId) return undefined;
			const content = capTerminalToolResult(event?.toolName, event?.content, ctx.model.contextWindow, event?.input);
			return content ? { content } : undefined;
		});
	}

	pi.on("agent_before_settle", (event, ctx) => {
		if (rescued || !isLocal(ctx) || event?.outcome === "aborted" || event?.context?.canContinue === false) return undefined;
		const drafts = Array.isArray(event?.entries) ? event.entries : [];
		if (drafts.some((d) => d?.type === "compaction")) return undefined;
		const rescue = buildLengthDeadlockRescue(ctx.sessionManager?.getBranch?.());
		if (!rescue) return undefined;
		rescued = true;
		return { entries: [...drafts, rescue], continue: true };
	});
}
