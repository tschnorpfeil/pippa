/**
 * Notes on a document whose text does not fit one tool result (document.ts calls this from `read`; budget.ts would cut
 * the text to its first ~12,000-24,000 characters and a 240,000-character thesis would be answered from its opening).
 *
 * - The text is split at line boundaries into parts (`shards`) sized from the model's context window, each line
 *   carrying its number.
 * - Every part goes to the current model in its own fresh call: no conversation, no thinking, a short answer. The
 *   model writes notes (topic, key statements, numbers, short verbatim quotes, each with its lines).
 * - Notes that together exceed the result limit are merged in further rounds until they fit.
 * - The result is saved as a Markdown file, one per document path, and reused while the document's size and
 *   modification time are unchanged (no model call at all then).
 * - Nothing is silent: the header says these are notes on lines 1-N, a part whose call failed is named with its lines,
 *   and when every call fails `digest` returns `undefined` so `read` gives the cut text with budget.ts's note.
 *
 * This is the one place where a Pippa extension makes model calls of its own. pippa-memory.ts states the rule (no
 * extra model call per answer: a local model has one slot, and every side call makes the answer slower). The exception
 * is narrow: only inside a `read` the model asked for, only when the document cannot be given whole, and at most once
 * per document version. The alternative is an answer about a tenth of the document.
 *
 * No Pi imports, so the tests can load this file without a Pi payload.
 */
import { createHash } from "node:crypto";
import { mkdir, readFile, rename, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";

/** One fresh model call: system text, user text, answer length in tokens. Rejects when the call fails. */
export type Complete = (system: string, user: string, maxTokens: number, signal?: AbortSignal) => Promise<string>;

/** `part` of `of` is being read (`phase: "notes"`) or notes are being merged (`phase: "merge"`). */
export type Progress = { part: number; of: number; phase: "notes" | "merge" };

export type Shard = { first: number; last: number; text: string };
type Range = { first: number; last: number };
type Note = { first: number; last: number; text: string; gaps: Range[] };

export type Digest = {
	/** What the model reads: header plus notes, never longer than the result limit. */
	text: string;
	/** The saved Markdown file. */
	file: string;
	lines: number;
	parts: number;
	/** Line ranges without notes (their model call failed, or the document is longer than `MAX_SHARDS` parts). */
	gaps: Range[];
	cached: boolean;
};

/** Characters per token, counted low (as budget.ts does: a quarter of the window is 0.75 characters per token of it). */
const CHARS_PER_TOKEN = 3;
/** A part takes about 40 % of the window; instruction and notes share the rest, also when a token is only 2 characters. */
const SHARD_SHARE = 0.4;
/** Online models have windows of 200k and more; parts stay small enough for careful notes. */
const LARGEST_SHARD = 60_000;
const SMALLEST_SHARD = 4_000;
/** The AI on this Mac: about 4,000 tokens a part whatever its window. Measured 2026-11-11 on a 24 GB Mac mini with other
 * apps open: oMLX's memory guard aborted parts of ~9,000 tokens (prefill peak above its limit) and let ~3,000 through. */
const LOCAL_SHARD = 12_000;
/** More parts than this are not read (20 minutes and more on a local model); the notes name the lines left out. */
export const MAX_SHARDS = 30;
const MERGE_ROUNDS = 3;
const SMALLEST_NOTE = 400;
const LARGEST_NOTE = 2_400;

/** Characters of one part, from the model's context window (16k → 19,661, 32k → 39,322; unknown: as for 16k).
 * `local`: the AI on this Mac, where memory, not the window, sets the size (`LOCAL_SHARD`). */
export function shardChars(contextWindow: unknown, local = false): number {
	const window = Number(contextWindow) > 0 ? Number(contextWindow) : 16_384;
	const size = Math.min(LARGEST_SHARD, Math.max(SMALLEST_SHARD, Math.round(window * SHARD_SHARE * CHARS_PER_TOKEN)));
	return local ? Math.min(size, LOCAL_SHARD) : size;
}

/** A part in two halves at a line boundary, for one more try after its call failed; `undefined` for a single line. */
export function halves(part: Shard): [Shard, Shard] | undefined {
	const lines = part.text.split("\n");
	if (lines.length < 2) return undefined;
	const number = (line: string) => Number(/^(\d+): /.exec(line)?.[1]);
	const middle = Math.floor(lines.length / 2);
	const a = lines.slice(0, middle), b = lines.slice(middle);
	const first = number(a[0]), split = number(b[0]), last = number(b[b.length - 1]);
	if (![first, split, last].every(Number.isFinite)) return undefined;
	return [{ first, last: Math.max(first, split - 1), text: a.join("\n") }, { first: split, last, text: b.join("\n") }];
}

/** `text` in parts of at most `size` characters, cut after whole lines; every line starts with its number ("12: …").
 * A single line longer than a part is cut by characters and keeps its number. */
export function shards(text: string, size: number): Shard[] {
	const out: Shard[] = [];
	let current: string[] = [], used = 0, first = 1;
	const flush = (last: number) => {
		if (current.length) out.push({ first, last, text: current.join("\n") });
		current = []; used = 0;
	};
	text.split("\n").forEach((line, index) => {
		const number = index + 1;
		const prefix = `${number}: `;
		const room = Math.max(1, size - prefix.length);
		for (let at = 0; at === 0 || at < line.length; at += room) {
			const piece = prefix + line.slice(at, at + room);
			if (used + piece.length + 1 > size && current.length) flush(at === 0 ? number - 1 : number);
			if (!current.length) first = number;
			current.push(piece);
			used += piece.length + 1;
		}
	});
	flush(text.split("\n").length);
	return out;
}

/** Where the notes are kept: PIPPA_DIGEST_DIR (set by the app), otherwise a temporary folder (tests, terminal). */
export function digestDirectory(env: Record<string, string | undefined> = process.env): string {
	return env.PIPPA_DIGEST_DIR || join(tmpdir(), "pippa-digests");
}

/** One file per document path, so a changed document replaces its old notes. */
export function digestFile(directory: string, path: string): string {
	const stem = basename(path).replace(/[^\p{L}\p{N}._ -]/gu, "_").slice(0, 80) || "document";
	return join(directory, `${stem}.${createHash("sha256").update(path).digest("hex").slice(0, 10)}.md`);
}

function notesPrompt(chars: number): string {
	return "You take notes on one part of a longer document for someone who cannot see it. Every line starts with its line number.\n"
		+ "Write in the document's language. First line: the topic of this part in one sentence. Then bullet points with the key statements, "
		+ "numbers with their units, names and dates, and one to three short verbatim quotes in quotation marks. "
		+ "End every bullet point with the lines it comes from, like (L120-134). Only what the text says: no introduction, no comment, no advice.\n"
		+ `At most ${chars} characters.`;
}

function mergePrompt(chars: number): string {
	return "These are notes on consecutive parts of one document. Merge them into shorter notes in the same language: "
		+ "keep the order, the most important statements, numbers, names, dates and verbatim quotes, and the line references like (L120-134). "
		+ "Drop repetition and minor detail. Bullet points only: no introduction, no comment.\n"
		+ `At most ${chars} characters.`;
}

const count = (n: number) => n.toLocaleString("en-US");

function gapLine(gap: Range): string {
	return `[Lines ${gap.first}-${gap.last} are not in these notes. Read them with read, offset ${gap.first}, limit ${gap.last - gap.first + 1}.]`;
}

function renderNote(note: Note): string {
	return [`## Lines ${note.first}-${note.last}`, note.text.trim(), ...note.gaps.map(gapLine)].filter(Boolean).join("\n");
}

const renderNotes = (notes: Note[]) => notes.map(renderNote).join("\n\n");

function header(name: string, lines: number, chars: number, parts: number, shortened: boolean): string {
	return `[Notes on ${name}: lines 1-${lines} (${count(chars)} characters), taken from ${parts} parts because the text does not fit the conversation. `
		+ "These are notes, not the full text. For an exact passage or a quote, call read with offset (first line) and limit (number of lines)."
		+ (shortened ? " The notes were shortened to fit." : "") + "]";
}

/** Notes merged in batches that each fit one part; a batch whose call fails stays as it is. */
async function merge(notes: Note[], budget: number, size: number, complete: Complete, signal: AbortSignal | undefined,
	onProgress: ((progress: Progress) => void) | undefined): Promise<Note[]> {
	const total = renderNotes(notes).length;
	const batches: Note[][] = [];
	let used = 0;
	for (const note of notes) {
		const length = renderNote(note).length + 2;
		if (!batches.length || used + length > size) { batches.push([]); used = 0; }
		batches[batches.length - 1].push(note);
		used += length;
	}
	const merged: Note[] = [];
	for (const [index, batch] of batches.entries()) {
		if (signal?.aborted) throw new Error("Reading was stopped.");
		onProgress?.({ part: index + 1, of: batches.length, phase: "merge" });
		const gaps = batch.flatMap((note) => note.gaps);
		const written = batch.filter((note) => note.text.trim());
		const source = written.map((note) => `## Lines ${note.first}-${note.last}\n${note.text.trim()}`).join("\n\n");
		// Each batch gets its share of the budget; headings and gap lines are added after the call.
		const overhead = 30 + gaps.reduce((n, gap) => n + gapLine(gap).length + 1, 0);
		const target = Math.max(200, Math.floor(budget * (renderNotes(batch).length / total) * 0.9) - overhead);
		if (!written.length || source.length <= target) { merged.push(...batch); continue; }
		try {
			const text = (await complete(mergePrompt(target), source, Math.ceil(target / CHARS_PER_TOKEN), signal)).trim();
			if (!text) throw new Error("empty");
			merged.push({ first: batch[0].first, last: batch[batch.length - 1].last, text, gaps });
		} catch (error) {
			if (signal?.aborted) throw error;
			merged.push(...batch);
		}
	}
	return merged;
}

/** Last resort when the model does not shorten: every note cut to its share, marked with "[…]". */
function trim(notes: Note[], budget: number): Note[] {
	const fixed = notes.reduce((n, note) => n + renderNote({ ...note, text: "" }).length + 8, 0);
	const text = notes.reduce((n, note) => n + note.text.trim().length, 0);
	const share = Math.max(0, budget - fixed) / Math.max(1, text);
	return notes.map((note) => {
		const body = note.text.trim();
		const keep = Math.floor(body.length * share);
		return keep >= body.length ? note : { ...note, text: keep > 0 ? body.slice(0, keep).trimEnd() + " […]" : "" };
	});
}

const FRONT = /^---\n([\s\S]*?)\n---\n/;

async function cached(file: string, path: string, size: number, modified: number, limit: number): Promise<{ text: string; meta: any } | undefined> {
	let saved: string;
	try { saved = await readFile(file, "utf8"); } catch { return undefined; }
	const front = FRONT.exec(saved);
	if (!front) return undefined;
	let meta: any;
	try { meta = JSON.parse(front[1]); } catch { return undefined; }
	const text = saved.slice(front[0].length).trimEnd();
	// Notes written for a larger window do not fit a smaller one: taken again.
	if (meta?.source !== path || meta?.size !== size || meta?.modified !== modified || !text || text.length > limit) return undefined;
	return { text, meta };
}

/**
 * Notes on the whole `text` of the document at `path`, at most `limit` characters, saved in `directory`.
 * `undefined`: no notes (no part could be summarized, or the document's file cannot be inspected); the caller returns
 * the text as before.
 */
export async function digest(options: {
	path: string; text: string; contextWindow: unknown; limit: number; complete: Complete; local?: boolean;
	directory?: string; signal?: AbortSignal; onProgress?: (progress: Progress) => void;
}): Promise<Digest | undefined> {
	const { path, text, limit, complete, signal, onProgress } = options;
	const directory = options.directory ?? digestDirectory();
	let info: { size: number; mtimeMs: number };
	try { info = await stat(path); } catch { return undefined; }
	const modified = Math.round(info.mtimeMs);
	const file = digestFile(directory, path);
	const hit = await cached(file, path, info.size, modified, limit);
	if (hit) {
		return { text: hit.text, file, lines: Number(hit.meta.lines) || 0, parts: Number(hit.meta.parts) || 0,
			gaps: Array.isArray(hit.meta.gaps) ? hit.meta.gaps : [], cached: true };
	}

	const name = basename(path);
	const lines = text.split("\n").length;
	const size = shardChars(options.contextWindow, options.local);
	const all = shards(text, size);
	const parts = all.slice(0, MAX_SHARDS);
	const head = header(name, lines, text.length, parts.length, true).length + 2;
	const budget = limit - head;
	// What one part's notes may take so that all fit without a merge round; the model is asked for a little less.
	const each = Math.min(LARGEST_NOTE, Math.max(SMALLEST_NOTE, Math.floor(budget / parts.length) - 40));
	let notes: Note[] = [];
	let written = 0;
	const ask = async (part: Shard, chars: number) => {
		const note = (await complete(notesPrompt(Math.floor(chars * 0.8)), part.text, Math.ceil(chars / CHARS_PER_TOKEN), signal)).trim();
		if (!note) throw new Error("empty");
		return note;
	};
	for (const [index, part] of parts.entries()) {
		if (signal?.aborted) throw new Error("Reading was stopped.");
		onProgress?.({ part: index + 1, of: parts.length, phase: "notes" });
		try {
			notes.push({ first: part.first, last: part.last, text: await ask(part, each), gaps: [] });
			written++;
		} catch (error) {
			if (signal?.aborted) throw error;
			// One more try in two halves: a smaller prompt passes a tight memory guard more often. A half that fails too
			// stays a gap with its lines.
			for (const half of halves(part) ?? [part]) {
				if (half === part) { notes.push({ first: part.first, last: part.last, text: "", gaps: [{ first: part.first, last: part.last }] }); break; }
				try {
					notes.push({ first: half.first, last: half.last, text: await ask(half, Math.max(SMALLEST_NOTE, Math.floor(each / 2))), gaps: [] });
					written++;
				} catch (again) {
					if (signal?.aborted) throw again;
					notes.push({ first: half.first, last: half.last, text: "", gaps: [{ first: half.first, last: half.last }] });
				}
			}
		}
	}
	if (!written) return undefined;
	if (all.length > parts.length) {
		const rest = { first: all[parts.length].first, last: lines };
		notes.push({ first: rest.first, last: rest.last, text: "", gaps: [rest] });
	}

	for (let round = 0; round < MERGE_ROUNDS && renderNotes(notes).length > budget; round++) {
		const before = renderNotes(notes).length;
		notes = await merge(notes, budget, size, complete, signal, onProgress);
		if (renderNotes(notes).length >= before) break;
	}
	let shortened = false;
	if (renderNotes(notes).length > budget) { notes = trim(notes, budget); shortened = true; }
	let body = header(name, lines, text.length, parts.length, shortened) + "\n\n" + renderNotes(notes);
	// Headings and gap lines alone over the limit (hundreds of gaps on a tiny window): cut, and the header says so.
	if (body.length > limit) body = header(name, lines, text.length, parts.length, true) + "\n\n" + renderNotes(notes).slice(0, Math.max(0, budget - 4)) + " […]";

	const gaps = notes.flatMap((note) => note.gaps);
	const meta = { source: path, size: info.size, modified, lines, parts: parts.length, gaps };
	try {
		await mkdir(directory, { recursive: true });
		const temporary = `${file}.${process.pid}.tmp`;
		await writeFile(temporary, `---\n${JSON.stringify(meta)}\n---\n${body}\n`, "utf8");
		await rename(temporary, file);
	} catch {
		// The notes still reach the model; without the file there is nothing to reuse or open.
	}
	return { text: body, file, lines, parts: parts.length, gaps, cached: false };
}

/** `Complete` on Pi's model registry: the conversation's own model, no history, no tools, thinking off (Pi's API
 * options without `reasoningEffort` send `enable_thinking: false` to Qwen-style models and ask others for none). */
export function piComplete(ctx: any): Complete | undefined {
	const model = ctx?.model;
	if (!model || typeof ctx?.modelRegistry?.complete !== "function") return undefined;
	return async (system, user, maxTokens, signal) => {
		const response = await ctx.modelRegistry.complete(model,
			{ systemPrompt: system, messages: [{ role: "user", content: [{ type: "text", text: user }], timestamp: Date.now() }] },
			{ maxTokens, signal, cacheRetention: "none" });
		if (response?.stopReason === "error" || response?.stopReason === "aborted") {
			throw new Error(String(response?.errorMessage || response.stopReason));
		}
		let text = (Array.isArray(response?.content) ? response.content : [])
			.filter((part: any) => part?.type === "text").map((part: any) => String(part.text ?? "")).join("\n")
			.replace(/<think>[\s\S]*?<\/think>/g, "").trim();
		// Stopped at the length limit: the last line is half a sentence.
		if (response?.stopReason === "length" && text.includes("\n")) text = text.slice(0, text.lastIndexOf("\n")).trimEnd();
		return text;
	};
}
