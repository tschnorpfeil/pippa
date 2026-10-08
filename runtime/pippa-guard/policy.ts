/**
 * When the Pippa guard asks and how long undo copies are kept: one place, two presets.
 * Chosen via `PIPPA_GUARD_POLICY` (`undo-first`, default, or `ask-all`).
 *
 * - `undo-first`: Pippa's file tools (write, edit, rename_or_move, move_files, move_to_trash), a plain `mkdir` (`mkdirTargets`)
 *   and Pippa's calendar/reminder/mail-draft tools (`appEntry`) run without a question, with backup or undo entry and
 *   receipt; it asks for sending, network, permanent deleting, unknown commands and foreign tools. The question has a
 *   third answer "allow for this task" (the same category until the end of the answer).
 * - `ask-all`: every change and every command gets a yes/no question.
 *
 * Receipts and backups are the same in both. The classification is deliberately coarse and cautious: when in doubt
 * "command" (ask). Safety comes from the question, not from guessing.
 */
import { readdir, readFile, rm, stat } from "node:fs/promises";
import { join } from "node:path";

/**
 * Kind of a call. There is no `read` here: the guard checks read-only tools from a trusted source beforehand.
 * `appEntry`: Pippa's own tools `calendar_add`, `reminder_add`, `mail_draft` (self-asking.ts `appEntry`): they change
 * something on the Mac but never leave it; events and reminders can be undone, the mail draft is never sent. So they
 * behave like file changes: `undo-first` without a question, with receipt; `ask-all` asks. Sending does not exist as
 * a tool; via bash it stays "send" and asks.
 */
export type Category = "fileChange" | "appEntry" | "look" | "command" | "delete" | "network" | "send" | "tool";
export type Rule = "allow" | "ask";

export interface Policy {
	name: string;
	rules: Record<Category, Rule>;
	/** Third answer "allow for this task" (applies to the same category until the current answer ends). */
	allowForTask: boolean;
	/** Undo entries: at most this old ... */
	keepDays: number;
	/** ... and at most this large together (file sizes; the copies are APFS clones and take no space until the
	 * original changes, but the full size is counted so the limit also holds without cloning). */
	keepBytes: number;
}

const retention = { keepDays: 7, keepBytes: 500 * 1024 * 1024 };

export const POLICIES: Record<string, Policy> = {
	"undo-first": {
		name: "undo-first",
		rules: { fileChange: "allow", appEntry: "allow", look: "allow", command: "ask", delete: "ask", network: "ask", send: "ask", tool: "ask" },
		allowForTask: true,
		...retention,
	},
	"ask-all": {
		name: "ask-all",
		rules: { fileChange: "ask", appEntry: "ask", look: "ask", command: "ask", delete: "ask", network: "ask", send: "ask", tool: "ask" },
		allowForTask: false,
		...retention,
	},
};

export function currentPolicy(name = process.env.PIPPA_GUARD_POLICY): Policy {
	return POLICIES[name ?? ""] ?? POLICIES["undo-first"];
}

/** Pippa's file tools: changes with a real backup or way back. */
const FILE_TOOLS = new Set(["write", "edit", "rename_or_move", "move_files", "move_to_trash"]);

export function classify(tool: string, input: any): Category {
	if (FILE_TOOLS.has(tool)) return "fileChange";
	if (tool === "bash" || tool === "powershell") return classifyCommand(String(input?.command ?? ""));
	return "tool";
}

/**
 * Shell command to category; the most dangerous wins: send before network before delete before look; everything else
 * is "command". Scripting languages (python, node, osascript ...) count as network: what they do is not in the command.
 */
export function classifyCommand(command: string): Category {
	// Creating folders is reversible (empty folders go to the trash): like Pippa's file tools.
	if (mkdirTargets(command)) return "fileChange";
	const c = ` ${command} `;
	if (/\b(sendmail|mail|mailx)\s/.test(c) || /tell\s+application\s+"?(Mail|Messages|Nachrichten)"?/i.test(c) && /\bsend\b/i.test(c)) return "send";
	if (/\b(curl|wget|nc|ncat|ssh|scp|sftp|ftp|telnet|python3?|node|deno|bun|ruby|perl|osascript|php)\b/.test(c)
		|| /\brsync\b.*\S+:/.test(c) || /\bgit\s+(push|pull|fetch|clone)\b/.test(c) || /\b(npm|pnpm|yarn)\s+(i|install|add|publish)\b/.test(c)
		|| /\bpip3?\s+install\b/.test(c) || /\bbrew\b/.test(c) || /\bhttps?:\/\//.test(c) || /\bopen\s+(-a\s+)?\S/.test(c)) return "network";
	if (/(^|[\s;&|(])(rm|rmdir|unlink|shred|srm)\s/.test(c) || /\bfind\b.*\s-delete\b/.test(c) || /\bfind\b.*-exec(dir)?\s+rm\b/.test(c)) return "delete";
	if (lookOnly(command)) return "look";
	return "command";
}

/**
 * `mkdir Archiv`, `mkdir -p Belege/2026 Archiv`: only the options `-p`/`-v` and names without shell special
 * characters (no quotes, variables, wildcards, redirections, second commands; `~/` only at the start). Then the guard
 * knows exactly which folders appear, and undo moves them to the trash while they are empty. Anything else:
 * `undefined` (stays "command" and asks).
 */
export function mkdirTargets(command: string): { parents: boolean; paths: string[] } | undefined {
	const words = command.trim().split(/[ \t]+/);
	if (words[0] !== "mkdir" || /[\n\r]/.test(command)) return undefined;
	let parents = false;
	const paths: string[] = [];
	for (const word of words.slice(1)) {
		if (/^-[pv]+$/.test(word)) { parents ||= word.includes("p"); continue; }
		if (!/^(~\/)?[\p{L}\p{N}._+,@%=\/-]+$/u.test(word) || word.startsWith("-")) return undefined;
		paths.push(word);
	}
	return paths.length ? { parents, paths } : undefined;
}

/**
 * Read-only commands (ls, cat, wc, ...) without redirection, substitution or dangerous options: what they do, in
 * words (German, shown to the person). `undefined` as soon as any part could be something else.
 */
export function lookOnly(command: string): string | undefined {
	// Discarding output or merging stderr writes nothing: `find ~ -name "*.md" 2>/dev/null | head -50` is the usual
	// way models search, and it must not ask.
	command = command.replace(/\s*(?:[12&]?>>?)\s*\/dev\/null(?=$|[\s|;&)])/g, " ").replace(/\s*2>&1(?=$|[\s|;&)])/g, " ");
	if (/[>`]|\$\(|<\(|(^|\s)-(delete|exec|execdir|ok|fprint\w*)\b/.test(command)) return undefined;
	const words: Record<string, string> = {
		ls: "Dateien auflisten", find: "Dateien suchen", cat: "Dateien lesen", head: "Dateien lesen", tail: "Dateien lesen",
		less: "Dateien lesen", wc: "zählen", grep: "Text suchen", rg: "Text suchen", pwd: "Ordner anzeigen", stat: "Dateiangaben lesen",
		file: "Dateiart prüfen", du: "Größe messen", sort: "sortieren", uniq: "zusammenfassen", date: "Datum anzeigen", echo: "Text anzeigen",
		fd: "Dateien suchen", mdfind: "mit Spotlight suchen", mdls: "Dateiangaben lesen",
	};
	const seen = new Set<string>();
	for (const part of command.split(/\|\|?|&&|;/)) {
		const first = part.trim().split(/\s+/)[0];
		if (!first) continue;
		const meaning = words[first];
		if (!meaning) return undefined;
		// fd -x/-X/--exec(-batch) and rg --pre run other programs; mdfind -live never ends.
		if (first === "fd" && /(^|\s)(-[a-zA-Z]*[xX]\b|--exec)/.test(part)) return undefined;
		if (first === "rg" && /(^|\s)--pre\b/.test(part)) return undefined;
		if (first === "mdfind" && /(^|\s)-live\b/.test(part)) return undefined;
		seen.add(meaning);
	}
	return seen.size ? [...seen].join(", ") : undefined;
}

/** Size of a folder (file sizes, symlinks not followed). */
async function size(path: string): Promise<number> {
	const info = await stat(path).catch(() => undefined);
	if (!info) return 0;
	if (!info.isDirectory()) return info.size;
	let total = 0;
	for (const name of await readdir(path).catch(() => [] as string[])) total += await size(join(path, name));
	return total;
}

/**
 * Remove old undo entries: older than `keepDays` or, oldest first, until all together are below `keepBytes`. Only
 * folders with a manifest.json (Pippa's own entries). Returns the removed names. Pippa then shows "undo no longer
 * possible" on the receipt instead of a button.
 */
export async function pruneUndo(root: string, policy: Policy, now = Date.now()): Promise<string[]> {
	const entries: { name: string; created: number; bytes: number }[] = [];
	for (const name of await readdir(root).catch(() => [] as string[])) {
		const dir = join(root, name);
		let created: number;
		try {
			const manifest = JSON.parse(await readFile(join(dir, "manifest.json"), "utf8"));
			created = Date.parse(manifest.createdAt) || (await stat(dir)).mtimeMs;
		} catch {
			continue;
		}
		entries.push({ name, created, bytes: await size(dir) });
	}
	entries.sort((a, b) => a.created - b.created);
	let total = entries.reduce((sum, e) => sum + e.bytes, 0);
	const removed: string[] = [];
	for (const entry of entries) {
		const tooOld = now - entry.created > policy.keepDays * 86_400_000;
		if (!tooOld && total <= policy.keepBytes) continue;
		await rm(join(root, entry.name), { recursive: true, force: true });
		total -= entry.bytes;
		removed.push(entry.name);
	}
	return removed;
}
