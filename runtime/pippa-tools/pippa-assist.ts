/**
 * Small helps that keep a small local model on track, and a quiet safety net. No permissions: Pi runs every tool
 * without asking; this file steers, keeps old versions and stops a few shell commands. Loaded by Pippa next to its file tools:
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
 * - Safety net, without asking: Pi runs every tool, and the people using Pippa have no Git and often no Time Machine.
 *   Before `edit` or `write` changes an existing file, a copy goes to Pippa's backup folder (APFS clone, free on the
 *   same disk) and the tool result says where, so "mach das rückgängig" can copy it back; copies older than
 *   `BACKUP_DAYS` go. `bash` never deletes for good (`move_to_trash` puts things in the Trash instead) and never
 *   reaches the network or other apps (the web tools and Pippa's MCP tools do that, visibly): text from a web page or
 *   document must not be able to turn into `rm` or `curl`.
 */
import { constants } from "node:fs";
import { copyFile, mkdir, readdir, rm, stat, utimes } from "node:fs/promises";
import { basename, isAbsolute, join, dirname, resolve } from "node:path";
import { homedir } from "node:os";

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

/** Shell commands that delete for good, and those that reach the network or script other apps. */
const DELETES = new Set(["rm", "rmdir", "unlink", "shred", "srm"]);
const OUTSIDE = new Set(["curl", "wget", "nc", "ncat", "netcat", "ssh", "scp", "sftp", "ftp", "telnet", "osascript"]);
/** Words in front of the actual command: `sudo rm`, `xargs -0 rm`, `FOO=1 curl`. */
const PREFIXES = new Set(["sudo", "env", "command", "exec", "nohup", "time", "nice", "xargs"]);

/** Why a `bash` command must not run, or `undefined`. Looks at every command in a chain (`;`, `&&`, `|`, `$( )`). */
export function riskyCommand(command: string): string | undefined {
	for (const segment of command.split(/[;&|\n`()]|\$\(/)) {
		const words = segment.trim().split(/\s+/).filter(Boolean);
		while (words.length && (PREFIXES.has(words[0]) || /^\w+=/.test(words[0]) || words[0].startsWith("-"))) words.shift();
		const name = (words[0] ?? "").replace(/^["']|["']$/g, "").split("/").pop() ?? "";
		const execs = words.flatMap((word, i) => (word === "-exec" || word === "-execdir" ? [words[i + 1]?.split("/").pop() ?? ""] : []));
		if (DELETES.has(name) || (name === "find" && (words.includes("-delete") || execs.some((e) => DELETES.has(e))))) {
			return "Not run: Pippa never deletes for good. Use move_to_trash for those files; the person can get them back from the Trash.";
		}
		if (OUTSIDE.has(name)) {
			return "Not run: the shell does not go online or control other apps. Use web_search or fetch_content for the web, and Pippa's own mcp__pippa__ tools for Mail, Calendar and Reminders.";
		}
	}
	return undefined;
}

export const BACKUP_DAYS = 30;
/** Larger files are not copied (a clone is free on APFS, a real copy of a huge file is not). */
const BACKUP_MAX_BYTES = 1024 ** 3;

/** Where old versions go: `PIPPA_BACKUP_DIR`, else `Backups` next to Pippa's memory file; none in trial runs. */
export function backupDirectory(env: Record<string, string | undefined> = process.env): string | undefined {
	if (env.PIPPA_BACKUP_DIR) return env.PIPPA_BACKUP_DIR;
	return env.PIPPA_MEMORY_FILE ? join(dirname(env.PIPPA_MEMORY_FILE), "Backups") : undefined;
}

/** The absolute path an `edit`/`write` call targets (Pi resolves `~` and relative paths the same way). */
export function targetPath(raw: unknown, cwd: string, home = homedir()): string | undefined {
	const path = typeof raw === "string" ? raw.trim() : "";
	if (!path) return undefined;
	if (path === "~" || path.startsWith("~/")) return join(home, path.slice(1));
	return isAbsolute(path) ? path : resolve(cwd, path);
}

/** Copies an existing file into `directory` before it changes; the copy's path, or `undefined` (new file, folder, too big). */
export async function backUp(file: string, directory: string, now = new Date()): Promise<string | undefined> {
	let info;
	try { info = await stat(file); } catch { return undefined; }
	if (!info.isFile() || info.size > BACKUP_MAX_BYTES) return undefined;
	const pad = (n: number) => String(n).padStart(2, "0");
	const stamp = `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())} ${pad(now.getHours())}.${pad(now.getMinutes())}.${pad(now.getSeconds())}`;
	await mkdir(directory, { recursive: true });
	for (let n = 1; n < 100; n++) {
		const copy = join(directory, `${stamp}${n > 1 ? ` (${n})` : ""} ${basename(file)}`);
		try {
			await copyFile(file, copy, constants.COPYFILE_FICLONE | constants.COPYFILE_EXCL);
			// On macOS the copy keeps the file's own dates; the age that counts for pruning is the copy's.
			await utimes(copy, now, now);
			return copy;
		}
		catch (error: any) { if (error?.code !== "EEXIST") throw error; }
	}
	return undefined;
}

/** Removes copies older than `days` (by the time they were made, set in `backUp`). */
export async function pruneBackups(directory: string, days = BACKUP_DAYS, now = Date.now()): Promise<void> {
	let names: string[];
	try { names = await readdir(directory); } catch { return; }
	for (const name of names) {
		const path = join(directory, name);
		try { if (now - (await stat(path)).mtimeMs > days * 86_400_000) await rm(path, { force: true }); } catch { /* next one */ }
	}
}

export default function (pi: ExtensionAPI) {
	const backups = backupDirectory();
	const kept = new Map<string, { copy: string; file: string }>();
	if (backups) void pruneBackups(backups);
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
		if (tool === "bash") {
			const risky = riskyCommand(String(event.input?.command ?? ""));
			if (risky) return { block: true, reason: risky };
		}
		if (backups && (tool === "edit" || tool === "write")) {
			const file = targetPath(event.input?.path ?? event.input?.file_path, ctx?.cwd ?? process.cwd());
			try {
				const copy = file ? await backUp(file, backups) : undefined;
				if (copy && file) kept.set(event.toolCallId, { copy, file });
			} catch {
				return { block: true, reason: "Not changed: Pippa could not keep a copy of the old version first. Tell the person in one short sentence that the file stays as it was." };
			}
		}
		if (tool === "search_files" || (tool === "bash" && /(^|\s)mdfind\b/.test(String(event.input?.command ?? "")))) {
			searchCalls.add(event.toolCallId);
			searched = true;
		}
		return undefined;
	});

	pi.on("tool_result", async (event: any) => {
		const backup = kept.get(event.toolCallId);
		kept.delete(event.toolCallId);
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
		if (backup && !event.isError) {
			const note = `The previous version of ${basename(backup.file)} is kept at ${backup.copy}. To undo, copy it back over ${backup.file}.`;
			return { content: [...(event.content ?? []), { type: "text", text: note }] };
		}
		return undefined;
	});
}
