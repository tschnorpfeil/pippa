/**
 * What Pippa knows about the person across conversations: one short text file, one line per fact. Loaded by Pippa next
 * to its other extensions:
 *
 *   pi --mode rpc --extension …/pippa-memory.ts …   (file: PIPPA_MEMORY_FILE, set by the app)
 *
 * - The lines go into the system prompt as their own section (`<memory>`), read once per session and then left as they
 *   are. Pi sends an unchanged section only once, so the local model's prompt cache stays warm; a fact remembered
 *   mid-conversation reaches the model through the tool result and the next session through the section.
 * - One tool, `remember`: add a lasting fact, forget one, or both (a change). When to use it stands in its description,
 *   not in Pippa's system prompt.
 * - Hard limits live here, not in the prompt: no account, card, ID or tax numbers, no passwords or PINs; at most
 *   `MAX_LINES` lines of `MAX_LINE` characters, the oldest go first. No extra model call per answer: a local model has
 *   one slot, and every side call would make each answer slower.
 *
 * The file stays plain text (`- fact` per line), so Pippa's settings can show it and the person can delete it. Without
 * PIPPA_MEMORY_FILE (trial runs, spikes) the facts live only as long as the process, so no run touches the real file.
 */
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname } from "node:path";

type ExtensionAPI = any;

export const MAX_LINES = 30;
export const MAX_LINE = 200;

export function memoryFile(env: Record<string, string | undefined> = process.env): string | undefined {
	return env.PIPPA_MEMORY_FILE || undefined;
}

/** The facts of a memory file: one per `- ` line; other lines (a heading the person typed) are ignored. */
export function parseMemory(text: string): string[] {
	return text.split("\n").map((line) => line.trim()).filter((line) => line.startsWith("- ")).map((line) => line.slice(2).trim()).filter(Boolean);
}

export function renderMemory(facts: string[]): string {
	return facts.length ? facts.map((fact) => `- ${fact}`).join("\n") + "\n" : "";
}

/** The `<memory>` section for the system prompt, or `undefined` when Pippa knows nothing yet (no tokens spent). */
export function memorySection(facts: string[]): string | undefined {
	if (!facts.length) return undefined;
	return "What you know about the person from earlier conversations. Use it when it helps; don't recite it.\n" + renderMemory(facts).trimEnd();
}

/** Why a fact must not be stored, or `undefined`. Nine or more digits in a row (spaces, dots, dashes and slashes between
 * them count as one run) cover IBAN, account, card, ID, tax and phone numbers; dates like 09.10.2026 have eight. */
export function refusal(fact: string): string | undefined {
	if (/\b[A-Z]{2}\d{2}(?:\s?[A-Z0-9]){11,30}\b/.test(fact) || /\d(?:[\s./-]?\d){8,}/.test(fact)) {
		return "Not saved: Pippa never keeps account, card, ID, tax or phone numbers. Tell the person in one short sentence that you don't keep such numbers.";
	}
	if (/\b(passw(or)?d|passwort|kennwort|pin|puk|tan|zugangsdaten|login)\b/i.test(fact)) {
		return "Not saved: Pippa never keeps passwords, PINs or sign-in details. Tell the person in one short sentence that you don't keep those.";
	}
	return undefined;
}

/** Lines to forget: those containing the text, otherwise those containing all of its words (3+ letters). `*`: all. */
export function matches(facts: string[], forget: string): number[] {
	const needle = forget.trim().toLowerCase();
	if (!needle) return [];
	if (needle === "*") return facts.map((_, i) => i);
	const direct = facts.flatMap((fact, i) => (fact.toLowerCase().includes(needle) ? [i] : []));
	if (direct.length) return direct;
	const words = needle.split(/[^\p{L}\p{N}]+/u).filter((word) => word.length >= 3);
	if (!words.length) return [];
	return facts.flatMap((fact, i) => (words.every((word) => fact.toLowerCase().includes(word)) ? [i] : []));
}

export interface Change { facts: string[]; added?: string; forgotten: string[]; dropped: string[]; error?: string }

/** Applies one `remember` call: forget first, then add (so one call can replace a fact). */
export function apply(facts: string[], params: { add?: string; forget?: string }): Change {
	const add = String(params?.add ?? "").replace(/\s+/g, " ").trim();
	const forget = String(params?.forget ?? "").trim();
	if (!add && !forget) return { facts, forgotten: [], dropped: [], error: "Nothing to do: give `add`, `forget` or both." };
	if (add) {
		const reason = refusal(add);
		if (reason) return { facts, forgotten: [], dropped: [], error: reason };
		if (add.length > MAX_LINE) return { facts, forgotten: [], dropped: [], error: `Too long: keep a fact under ${MAX_LINE} characters, one fact per call.` };
	}
	const gone = new Set(forget ? matches(facts, forget) : []);
	const forgotten = facts.filter((_, i) => gone.has(i));
	let next = facts.filter((_, i) => !gone.has(i));
	if (add && !next.some((fact) => fact.toLowerCase() === add.toLowerCase())) next.push(add);
	const dropped = next.length > MAX_LINES ? next.slice(0, next.length - MAX_LINES) : [];
	next = next.slice(dropped.length);
	return { facts: next, added: add || undefined, forgotten, dropped };
}

export async function readFacts(file: string): Promise<string[]> {
	try { return parseMemory(await readFile(file, "utf8")); } catch { return []; }
}

/** Write whole, never half: temporary file next to it, then rename. Only the person can read it. */
export async function writeFacts(file: string, facts: string[]): Promise<void> {
	await mkdir(dirname(file), { recursive: true });
	const temp = `${file}.${process.pid}.tmp`;
	await writeFile(temp, renderMemory(facts), { mode: 0o600 });
	await rename(temp, file);
}

export default function (pi: ExtensionAPI) {
	const file = memoryFile();
	let kept: string[] = [];   // without a file: this process only
	const load = async () => (file ? readFacts(file) : kept);
	const save = async (facts: string[]) => { if (file) await writeFacts(file, facts); else kept = facts; };
	// Read once per session: the section stays byte-identical for the whole session (prompt cache).
	let section: string | undefined;
	let loaded = false;
	pi.on("session_start", async () => { loaded = false; });
	pi.on("before_agent_start", async (event: any) => {
		if (!loaded) { section = memorySection(await load()); loaded = true; }
		const sections = event?.systemPromptOptions?.sections;
		if (sections && section) sections.memory = section;
	});

	pi.registerTool({
		name: "remember",
		label: "Merken",
		description: "Pippa's memory across conversations. add: a lasting fact or wish the person states about themselves "
			+ "(people and companies they deal with, where they live, how they want answers), one short fact per call; not "
			+ "details of the current task. forget: what the person asks you to forget ('*' = everything). Both = change.",
		parameters: {
			type: "object",
			properties: {
				add: { type: "string", description: "One fact in a short sentence, e.g. 'Landlord: Mr Berger, Hausverwaltung Kraus'." },
				forget: { type: "string", description: "Words of the fact to remove." },
			},
			additionalProperties: false,
		},
		annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
		executionMode: "sequential",
		async execute(_id: string, params: any) {
			const change = apply(await load(), params ?? {});
			if (change.error) throw new Error(change.error);
			await save(change.facts);
			const parts: string[] = [];
			if (change.forgotten.length) parts.push(`Forgotten: ${change.forgotten.join("; ")}.`);
			else if (params?.forget) parts.push("Nothing matched to forget.");
			if (change.added) parts.push(`Remembered: ${change.added}.`);
			return { content: [{ type: "text", text: parts.join(" ") }], details: { count: change.facts.length, forgotten: change.forgotten.length, dropped: change.dropped.length } };
		},
	});
}
