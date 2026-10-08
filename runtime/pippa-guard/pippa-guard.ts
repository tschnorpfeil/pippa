/**
 * Pippa guard extension for the real Pi.
 *
 * Loaded with `pi --mode rpc --extension runtime/pippa-guard/pippa-guard.ts`. Before every tool call:
 * - Read-only tools (read, grep, find, ls, list_folder) run without asking.
 * - Whether everything else asks is set by the policy preset in policy.ts (`PIPPA_GUARD_POLICY`). `undo-first`
 *   (default) lets Pippa's file tools and look-only commands run without a question and asks for sending, network,
 *   deleting, other commands and foreign tools, with a third answer "allow for this task" (`ctx.ui.select`).
 *   `ask-all` asks for every change via `ctx.ui.confirm`. The question says in plain language what would happen; the
 *   raw command appears at most as a detail below. Backup and receipt are the same in both presets.
 * - Backups are APFS clones (no space until the original changes); newly created files and the trash need none.
 *   The guard prunes old entries at start and after every answer (policy.ts: 7 days, 500 MB).
 * - Declined: the tool is blocked, with a reason the model understands.
 * - Before an approved write/edit, the affected file goes into the undo folder
 *   ($PIPPA_UNDO_DIR/<timestamp>-<id>/, with manifest.json); `restore.mjs` restores it. Rename, move and trash need
 *   no copy: the manifest records where the file went and `restore.mjs` brings it back.
 * - `move_files` (many moves in one call): ONE manifest for the whole batch with `moves` and, like mkdir, the new target
 *   folders (`folders`/`created`); one undo brings every file back and trashes the new folders while empty. Written
 *   before the change with everything planned, rewritten after the result with what really moved.
 * - bash cannot be backed up in general (the command can touch anything). The folder then gets only a log with the
 *   command and working folder, explicitly marked "not restorable".
 *   Exception: a plain `mkdir` without special characters (policy.ts `mkdirTargets`) counts as a file change; the
 *   manifest lists the new folders and undo moves them to the trash as long as nothing else is inside.
 *
 * Receipts: for every changing call the guard writes a session entry `pippa-receipt` (`pi.appendEntry`; arrives in
 * the RPC stream as `entry_appended`, never in the model context): declined, blocked, done (with undo entry) or
 * failed. Pippa builds the "what happened" line from it, never from the model's text.
 * Pippa's calendar, reminder and mail-draft tools (kind "appEntry", self-asking.ts) are backed up by Pippa's server,
 * not by the guard; the guard takes over the server's receipt (name, mail state, undo entry) from `tool_result`.
 *
 * Without a UI (print/json mode) everything that changes something is blocked.
 *
 * Foreign extensions (test: bypass.test.mjs): Pi calls the `tool_call` handlers in load order, `--extension` (this
 * guard) before the person's extensions; another handler cannot "allow", only "block". Three ways a foreign
 * extension could otherwise get around the guard are closed here:
 * - A later handler changes the arguments after approval (different path than asked): the guard freezes the
 *   arguments before asking; a later change throws and Pi blocks the call.
 * - A foreign tool is named like a read-only one (`read`; Pi lets extensions replace built-in tools): it runs
 *   without asking only if the tool really comes from Pi itself or from Pippa (`--extension`).
 * - A foreign tool declares itself read-only via `readOnlyHint`: only Pi, Pippa and the MCP servers in
 *   `PIPPA_GUARD_TRUSTED_MCP` (default: `pippa`) are believed.
 * What an extension does in its own code (outside a model tool call) the guard cannot see: extensions are programs
 * with the person's permissions.
 */
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { cloneFile, exists, fileWords, folderLabel, isFolder, moveTarget, planMoves, resolvePath } from "./files.ts";
import { type Category, classify, currentPolicy, lookOnly, mkdirTargets, pruneUndo } from "./policy.ts";
import { type AppEntry, appEntry, asksItself, serverReceipt } from "./self-asking.ts";

// Types only; at runtime this file needs nothing from Pi.
type ExtensionAPI = any;

/** Tools that only read (if they come from Pi or Pippa, see `trustedSource`). Everything else needs approval. */
const READ_ONLY = new Set(["read", "grep", "find", "ls", "list_folder"]);

/** MCP servers whose `readOnlyHint` the guard believes (the app's own Pippa server). */
const TRUSTED_MCP = new Set((process.env.PIPPA_GUARD_TRUSTED_MCP ?? "pippa").split(",").map((s) => s.trim().replace(/-/g, "_")).filter(Boolean));

/**
 * Does the tool come from Pi itself (`builtin:`) or from a launch-time `--extension`? Pippa starts Pi only with its
 * own `--extension`s (PippaPiLaunch), so "cli" means Pippa here. The person's extensions have `auto`/`local`,
 * packages have `package`.
 */
export function trustedSource(source: any): boolean {
	return source?.source === "builtin" || source?.source === "cli" || (typeof source?.path === "string" && source.path.startsWith("builtin:"));
}

/** May the call run without asking? Only read-only tools from a trusted source. `info`: entry from `pi.getAllTools()`. */
export function readsOnly(tool: string, info: any): boolean {
	if (!info) return false; // unknown: ask
	const source = info.sourceInfo;
	if (READ_ONLY.has(tool)) return trustedSource(source);
	const hints = info.annotations;
	if (hints?.readOnlyHint !== true || hints?.openWorldHint !== false) return false;
	const mcp = tool.match(/^mcp__(.+?)__/);
	if (mcp) return trustedSource(source) && TRUSTED_MCP.has(mcp[1]);
	return source?.source === "cli";
}

/** Freeze the arguments: what is asked and backed up is exactly what runs afterwards. */
function deepFreeze<T>(value: T): T {
	if (value && typeof value === "object" && !Object.isFrozen(value)) {
		Object.freeze(value);
		for (const inner of Object.values(value as Record<string, unknown>)) deepFreeze(inner);
	}
	return value;
}

const UNDO_ROOT = process.env.PIPPA_UNDO_DIR || join(tmpdir(), "pippa-undo");

/** Session entry for Pippa's receipt (schema `v: 1`, read by app/Sources/PiRPC/PiActionReceipt.swift). */
export const RECEIPT_TYPE = "pippa-receipt";

/** What the call is meant to do, in Pippa's terms (for receipt and undo). */
type Action = "create" | "createFolder" | "overwrite" | "change" | "rename" | "move" | "trash" | "delete" | "look" | "command" | "tool" | AppEntry;

/**
 * What Pippa's calendar, reminder and draft tools would do, as a sentence for `ask-all` (`undo-first` does not ask).
 * Built from the model's arguments; Pippa's server resolves date and time later, hence they are quoted verbatim.
 */
export function describeAppEntry(action: AppEntry, input: any): { name: string; sentence: string } {
	const one = (value: unknown, max = 80) => {
		const text = String(value ?? "").replace(/\s+/g, " ").trim();
		return text.length > max ? `${text.slice(0, max - 1)}…` : text;
	};
	const when = [one(input?.date, 30), one(input?.time, 10)].filter(Boolean).join(", ");
	switch (action) {
		case "calendarAdd": {
			const name = one(input?.title) || "Termin";
			return { name, sentence: `Pippa möchte in deinem Kalender den Termin ‚${name}‘ eintragen${when ? ` (${when})` : ""}. Das lässt sich rückgängig machen. OK?` };
		}
		case "reminderAdd": {
			const name = one(input?.title) || "Erinnerung";
			return { name, sentence: `Pippa möchte die Erinnerung ‚${name}‘ anlegen${when ? ` (fällig ${when})` : ""}. Das lässt sich rückgängig machen. OK?` };
		}
		default: {
			if (input?.reply_to) return { name: "Antwort", sentence: "Pippa möchte in Mail eine Antwort als Entwurf anlegen. Gesendet wird nichts. OK?" };
			const name = one(input?.subject) || "Mail";
			return { name, sentence: `Pippa möchte in Mail eine neue Mail ‚${name}‘ als Entwurf öffnen. Gesendet wird nichts. OK?` };
		}
	}
}

interface Planned {
	action: Action;
	/** Display name (file or folder name) without path. */
	name?: string;
	path?: string;
	/** New name (rename) or target folder (move), also without path. */
	toName?: string;
	to?: string;
}

/**
 * What a shell command probably does, as an everyday sentence. Rough and deliberately cautious: when in doubt it
 * says Pippa cannot tell for sure. Safety comes from asking, not from this guessing.
 */
export function describeCommand(command: string, cwd = ""): string {
	const looks = lookOnly(command);
	if (looks) {
		const folder = basename(cwd) || cwd;
		return `Pippa möchte im Ordner ‚${folder}‘ nur nachsehen (${looks}). Dabei wird nach Pippas Einschätzung nichts verändert.`;
	}
	// Common single cases with file names in the sentence: `rm Einkauf.txt`, `mv Einkauf.txt Liste.txt`.
	const simple = command.trim().match(/^(rm|mv)\s+((?:-\w+\s+)*)([^\s;&|<>'"`$*?]+)(?:\s+([^\s;&|<>'"`$*?]+))?$/);
	if (simple) {
		const [, verb, , a, b] = simple;
		if (verb === "rm" && !b) return `Pippa möchte ${fileWords(resolve(cwd, a))} löschen. Sie landet nicht im Papierkorb.`;
		if (verb === "mv" && b) {
			const from = resolve(cwd, a);
			const to = resolve(cwd, b);
			return dirname(from) === dirname(to)
				? `Pippa möchte ${fileWords(from)} in ‚${basename(to)}‘ umbenennen.`
				: `Pippa möchte ${fileWords(from)} nach ‚${to}‘ verschieben.`;
		}
	}
	const effects: string[] = [];
	const c = ` ${command} `;
	if (/\brm\b|\brmdir\b|\bunlink\b|\btrash\b|\s-delete\b/.test(c)) effects.push("Dateien oder Ordner löschen");
	if (/\bmv\b/.test(c)) effects.push("Dateien verschieben oder umbenennen");
	if (/\bcp\b|\brsync\b|\bditto\b/.test(c)) effects.push("Dateien kopieren");
	if (/[^<>2&]>{1,2}\s*[^&\s]|\btee\b|\btouch\b|\bmkdir\b|\bsed\s+-i|\bchmod\b|\bchown\b/.test(c))
		effects.push("Dateien anlegen oder ändern");
	if (/\bcurl\b|\bwget\b|\bssh\b|\bscp\b|\bnc\b|\bgit\s+(push|pull|fetch|clone)\b|\bnpm\s+(i|install|publish)\b|\bpip3?\s+install\b|\bbrew\b|\bhttps?:\/\//.test(c))
		effects.push("ins Internet gehen");
	if (/\bmail\b|\bsendmail\b|\bosascript\b|\bopen\b/.test(c)) effects.push("andere Programme steuern oder etwas versenden");
	if (/\bsudo\b|\bkill(all)?\b|\blaunchctl\b|\bdefaults\s+write\b/.test(c)) effects.push("Einstellungen oder laufende Programme dieses Macs verändern");
	if (effects.length === 0) {
		return "Pippa möchte einen Befehl auf diesem Mac ausführen. Was er genau bewirkt, kann Pippa nicht sicher sagen; er könnte Dateien ändern.";
	}
	return `Pippa möchte einen Befehl auf diesem Mac ausführen, der ${effects.join(", ").replace(/, ([^,]*)$/, " und $1")} kann.`;
}

/** Source file of `rm file` or `mv old new` (no wildcards, one file), otherwise `undefined`. */
function simpleFileCommand(command: string, cwd: string): string | undefined {
	const m = command.trim().match(/^(rm|mv)\s+((?:-\w+\s+)*)([^\s;&|<>'"`$*?]+)(?:\s+([^\s;&|<>'"`$*?]+))?$/);
	if (!m || (m[1] === "rm" && m[4]) || (m[1] === "mv" && !m[4])) return undefined;
	return resolvePath(m[3], cwd);
}

/** Short command as a detail line; long commands are truncated so the sentence above stays the main point. */
function commandDetail(command: string): string {
	const one = command.length > 300 ? `${command.slice(0, 300)} …` : command;
	return `Befehl (für Fachleute): ${one}`;
}

function declineReason(tool: string, style = "v3"): string {
	const v1 = `The user declined this action ('${tool}'). Nothing was changed. Do not retry the same action; tell the user briefly in German that you did not do it, and ask what they would like instead.`;
	if (style === "v1") return v1;
	if (style === "v2") {
		return `The user said no to this one action ('${tool}'), so it was not carried out and nothing changed. Tell the user in one short German sentence that you did not do it because they said no. Do not try it again in this turn. The tool still works: if the user asks for it again later, call it normally; they will be asked again.`;
	}
	return `${v1} If the user asks for it again in a later message, you may call the tool again.`;
}


interface Entry {
	path: string;
	existed: boolean;
	snapshot?: string;
}

function undoFolder(callId: string): string {
	const stamp = new Date().toISOString().replace(/[:.]/g, "-");
	return join(UNDO_ROOT, `${stamp}-${callId.replace(/[^A-Za-z0-9_-]/g, "").slice(0, 24) || "call"}`);
}

async function writeManifest(dir: string, body: Record<string, unknown>): Promise<void> {
	await mkdir(dir, { recursive: true });
	const manifest = { version: 1, createdAt: new Date().toISOString(), ...body };
	await writeFile(join(dir, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`);
}

/** Backs up the files before the change. Returns the folder (for receipt and restore). */
async function snapshot(tool: string, callId: string, cwd: string, paths: string[], note?: Record<string, unknown>): Promise<string> {
	const dir = undoFolder(callId);
	await mkdir(dir, { recursive: true });
	const entries: Entry[] = [];
	for (const [i, path] of paths.entries()) {
		if (await exists(path)) {
			const copy = join(dir, "files", `${i}-${basename(path)}`);
			// APFS clone: takes no space until the original changes (otherwise an ordinary copy).
			await mkdir(join(dir, "files"), { recursive: true });
			await cloneFile(path, copy);
			entries.push({ path, existed: true, snapshot: copy });
		} else {
			entries.push({ path, existed: false });
		}
	}
	await writeManifest(dir, { tool, toolCallId: callId, cwd, entries, ...note });
	return dir;
}

/** What a shell command does, for the receipt: "look", the simple rm/mv cases by name, otherwise "command". */
function bashPlan(command: string, cwd: string): Planned {
	if (lookOnly(command)) return { action: "look", name: basename(cwd) || cwd, path: cwd };
	const m = command.trim().match(/^(rm|mv)\s+((?:-\w+\s+)*)([^\s;&|<>'"`$*?]+)(?:\s+([^\s;&|<>'"`$*?]+))?$/);
	if (m?.[1] === "rm" && !m[4]) {
		const path = resolvePath(m[3], cwd);
		return { action: "delete", name: basename(path), path };
	}
	if (m?.[1] === "mv" && m[4]) {
		const from = resolvePath(m[3], cwd);
		const to = resolve(cwd, m[4]);
		return dirname(from) === dirname(to)
			? { action: "rename", name: basename(from), path: from, toName: basename(to), to }
			: { action: "move", name: basename(from), path: from, toName: basename(dirname(to)), to };
	}
	return { action: "command" };
}

/**
 * Which folders a plain `mkdir` (policy.ts `mkdirTargets`) will create, computed before the command: `folders` are
 * the topmost new folders (undo moves those to the trash), `created` are all new ones, including those in between
 * with `-p` (undo uses them to check that everything is still empty). Folders that already exist are in neither.
 */
export async function plannedFolders(target: { parents: boolean; paths: string[] }, cwd: string): Promise<{ folders: string[]; created: string[] }> {
	const folders: string[] = [];
	const created: string[] = [];
	for (const raw of target.paths) {
		const path = resolvePath(raw, cwd);
		if (await exists(path)) continue;
		const missing = [path];
		for (let parent = dirname(path); target.parents && parent !== dirname(parent) && !(await exists(parent)); parent = dirname(parent)) {
			missing.unshift(parent);
		}
		for (const folder of missing) if (!created.includes(folder)) created.push(folder);
		if (!folders.some((f) => missing[0] === f || missing[0].startsWith(`${f}/`))) folders.push(missing[0]);
	}
	return { folders, created };
}

/** Answers of the three-way question (`undo-first`). */
export const ALLOW = "Erlauben";
export const ALLOW_FOR_TASK = "Für diese Aufgabe erlauben";
export const DENY = "Nicht erlauben";

export default function (pi: ExtensionAPI) {
	const policy = currentPolicy();
	/** Approved calls until their result: what was planned and where the undo entry is. */
	const approved = new Map<string, { tool: string; plan: Planned; undo?: string; restorable: boolean; category: Category; asked: boolean }>();
	/** "Allow for this task": these categories stop asking until the current answer ends. */
	const allowedForTask = new Set<Category>();

	async function prune() {
		try { await pruneUndo(UNDO_ROOT, policy); } catch { /* Pruning must never hold up an answer. */ }
	}
	pi.on("session_start", async () => { await prune(); });
	pi.on("agent_start", async () => { allowedForTask.clear(); });
	pi.on("agent_end", async () => { allowedForTask.clear(); await prune(); });

	function receipt(toolCallId: string, tool: string, plan: Planned, outcome: string, extra: Record<string, unknown> = {}) {
		try {
			pi.appendEntry(RECEIPT_TYPE, { v: 1, toolCallId, tool, outcome, ...plan, ...extra });
		} catch {
			// No entry possible: Pippa falls back to the tool events (done/failed without a reason).
		}
	}

	pi.on("tool_call", async (event: any, ctx: any) => {
		const tool: string = event.toolName;
		const info = pi.getAllTools?.().find((t: any) => t.name === tool);
		if (readsOnly(tool, info)) return undefined;
		// Online lookup via Pippa's server: kind "network"; Pippa asks the one question per request itself (self-asking.ts).
		if (asksItself(tool, info, TRUSTED_MCP, trustedSource)) return undefined;
		// Calendar, reminder, mail draft via Pippa's server (kind "appEntry", receipt from the server).
		const entryAction = appEntry(tool, info, TRUSTED_MCP, trustedSource);
		// From here on, what is asked is what runs: a later handler (foreign extension) can no longer change the arguments.
		deepFreeze(event.input);

		const cwd: string = ctx.cwd ?? process.cwd();
		let sentence: string;
		let detail: string;
		let files: string[] = [];
		let plan: Planned;
		/** move_files: the planned batch (files.ts `planMoves`, the same computation as the tool's). */
		let batch: Awaited<ReturnType<typeof planMoves>> | undefined;
		switch (tool) {
			case "write": {
				const path = resolvePath(event.input?.path, cwd);
				files = [path];
				const existed = await exists(path);
				plan = { action: existed ? "overwrite" : "create", name: basename(path), path };
				sentence = `Pippa möchte ${fileWords(path)} ${existed ? "überschreiben" : "anlegen"}. OK?`;
				const size = String(event.input?.content ?? "").length;
				detail = `Ort: ${path} (${size} Zeichen). Eine Kopie des alten Stands wird vorher gesichert.`;
				break;
			}
			case "edit": {
				const path = resolvePath(event.input?.path, cwd);
				files = [path];
				plan = { action: "change", name: basename(path), path };
				const n = Array.isArray(event.input?.edits) ? event.input.edits.length : 1;
				sentence = `Pippa möchte ${fileWords(path)} ändern (${n === 1 ? "eine Stelle" : `${n} Stellen`}). OK?`;
				detail = `Ort: ${path}. Eine Kopie des alten Stands wird vorher gesichert.`;
				break;
			}
			case "rename_or_move": {
				const from = resolvePath(event.input?.from, cwd);
				const to = await moveTarget(from, event.input?.to, cwd);
				const folder = await isFolder(from);
				const same = dirname(from) === dirname(to);
				plan = same
					? { action: "rename", name: basename(from), path: from, toName: basename(to), to }
					: { action: "move", name: basename(from), path: from, toName: basename(dirname(to)), to };
				sentence = same
					? `Pippa möchte ${fileWords(from, folder)} in ‚${basename(to)}‘ umbenennen. OK?`
					: `Pippa möchte ${fileWords(from, folder)} in den Ordner ‚${basename(dirname(to))}‘ verschieben. OK?`;
				detail = `Von: ${from}\nNach: ${to}\nLässt sich rückgängig machen.`;
				break;
			}
			case "move_files": {
				batch = await planMoves(event.input?.folder, event.input?.groups, cwd);
				const ok = batch.items.filter((item) => !item.error);
				const where = (into: string) => folderLabel(into, batch!.folder).replace(/\/$/, "");
				const targets = [...new Set(ok.map((item) => where(item.into)))];
				const n = ok.length;
				plan = { action: "move", name: `${n} ${n === 1 ? "Datei" : "Dateien"}`, path: batch.folder, toName: targets.join(", ") || basename(batch.folder) };
				sentence = `Pippa möchte im Ordner ‚${basename(batch.folder)}‘ ${n === 1 ? "eine Datei" : `${n} Dateien`} in ${targets.length === 1 ? `den Ordner ‚${targets[0]}‘` : `${targets.length} Ordner (${targets.join(", ")})`} einsortieren. OK?`;
				const lines = ok.slice(0, 12).map((item) => `${item.name} → ${where(item.into)}`);
				if (ok.length > 12) lines.push(`… und ${ok.length - 12} weitere`);
				detail = `${lines.join("\n")}\nOrdner: ${batch.folder}. Lässt sich rückgängig machen.`;
				break;
			}
			case "move_to_trash": {
				const path = resolvePath(event.input?.path, cwd);
				const folder = await isFolder(path);
				plan = { action: "trash", name: basename(path), path };
				sentence = `Pippa möchte ${fileWords(path, folder)} in den Papierkorb legen. Du kannst ${folder ? "ihn" : "sie"} dort wieder herausholen. OK?`;
				detail = `Ort: ${path}`;
				break;
			}
			case "bash":
			case "powershell": {
				const command = String(event.input?.command ?? "");
				const folders = tool === "bash" ? mkdirTargets(command) : undefined;
				if (folders) {
					// Plain mkdir: a file change with a way back (new, empty folders go to the trash).
					const path = resolvePath(folders.paths[0], cwd);
					const more = folders.paths.length > 1 ? ` (und ${folders.paths.length - 1} weitere)` : "";
					plan = { action: "createFolder", name: basename(path), path };
					sentence = `Pippa möchte ${fileWords(path, true)}${more} anlegen. OK?`;
					detail = `${commandDetail(command)}\nLässt sich rückgängig machen, solange der Ordner leer ist.`;
					break;
				}
				plan = bashPlan(command, cwd);
				sentence = `${describeCommand(command, cwd)} OK?`;
				const undo = simpleFileCommand(command, cwd)
					? "Eine Kopie der Datei wird vorher gesichert."
					: "Was dieser Befehl ändert, kann Pippa nicht automatisch rückgängig machen.";
				detail = `${commandDetail(command)}\nOrdner: ${cwd}. ${undo}`;
				break;
			}
			default: {
				if (entryAction) {
					const described = describeAppEntry(entryAction, event.input);
					plan = { action: entryAction, name: described.name };
					sentence = described.sentence;
					detail = `Angaben (für Fachleute): ${JSON.stringify(event.input ?? {}).slice(0, 300)}`;
					break;
				}
				plan = { action: "tool", name: tool };
				sentence = `Pippa möchte das Werkzeug ‚${tool}‘ benutzen. Es könnte etwas verändern, verschicken oder ins Internet gehen. OK?`;
				detail = `Angaben (für Fachleute): ${JSON.stringify(event.input ?? {}).slice(0, 300)}`;
			}
		}

		const category: Category = entryAction ? "appEntry" : classify(tool, event.input);
		const ask = policy.rules[category] === "ask" && !allowedForTask.has(category);
		if (ask && !ctx.hasUI) {
			receipt(event.toolCallId, tool, plan, "blocked", { reason: "noUI", category, asked: false });
			return { block: true, reason: `Blocked: '${tool}' needs the user's approval, and no one can be asked right now. Do not retry; explain what you wanted to do.` };
		}
		let yes = true;
		if (ask && policy.allowForTask) {
			// Pi's `select` has only a title and options: sentence and detail go in the title, Pippa splits at "\n\n".
			const choice = await ctx.ui.select(`Darf Pippa das?\n\n${sentence}\n\n${detail}`, [ALLOW, ALLOW_FOR_TASK, DENY]);
			yes = choice === ALLOW || choice === ALLOW_FOR_TASK;
			if (choice === ALLOW_FOR_TASK) allowedForTask.add(category);
		} else if (ask) {
			yes = await ctx.ui.confirm("Darf Pippa das?", `${sentence}\n\n${detail}`);
		}
		if (!yes) {
			receipt(event.toolCallId, tool, plan, "declined", { category, asked: true });
			return {
				block: true,
				// The wording decides whether Gemma 12B stays honest afterwards (measured, scenario h):
				// v1 honest 5/5, but once "writing doesn't work here" for the rest of the conversation;
				// v2 (verbose, "the tool still works ...") 0/5 honest: claimed every time that the file was created.
				// v3 = v1 plus a short sentence for a repeated request. PIPPA_GUARD_DECLINE only selects for comparison.
				// The receipt does not depend on it: Pippa shows "Not created" from the entry above.
				reason: declineReason(tool, process.env.PIPPA_GUARD_DECLINE),
			};
		}

		let undo: string | undefined;
		let restorable = false;
		try {
			if (tool === "write" || tool === "edit") {
				undo = await snapshot(tool, event.toolCallId, cwd, files);
				restorable = true;
			} else if (tool === "rename_or_move") {
				// No copy needed: renaming back restores the old state. The manifest is written before the change.
				undo = undoFolder(event.toolCallId);
				await writeManifest(undo, { tool, toolCallId: event.toolCallId, cwd, moves: [{ from: plan.path, to: plan.to }], restorable: true });
				restorable = true;
			} else if (tool === "move_files" && batch) {
				// One manifest for the whole batch, before the change: every planned move plus the new target folders.
				undo = undoFolder(event.toolCallId);
				const moves = batch.items.filter((item) => !item.error).map((item) => ({ from: item.from, to: item.to }));
				await writeManifest(undo, { tool, toolCallId: event.toolCallId, cwd, moves, folders: batch.folders, created: batch.created, restorable: true });
				restorable = true;
			} else if (plan.action === "createFolder") {
				// mkdir: no copy, only which folders are new. If all existed already, there is nothing to restore.
				const command = String(event.input?.command ?? "");
				const planned = await plannedFolders(mkdirTargets(command)!, cwd);
				undo = undoFolder(event.toolCallId);
				restorable = planned.folders.length > 0;
				await writeManifest(undo, { tool, toolCallId: event.toolCallId, cwd, command, ...planned, restorable });
			} else if (tool === "bash" || tool === "powershell") {
				// Only the simple case `rm file` / `mv old new` can be backed up (the one source file). Everything else
				// is just a log: the guard cannot know what an arbitrary command touches.
				const command = String(event.input?.command ?? "");
				const simple = simpleFileCommand(command, cwd);
				const sources = simple ? [simple] : [];
				undo = await snapshot(tool, event.toolCallId, cwd, sources, { command, restorable: sources.length > 0 });
				restorable = sources.length > 0;
			}
			// move_to_trash: the trash is the backup; where it went is only known after the tool ran (tool_result).
		} catch (error) {
			// No backup, no change: better to block than to allow something irreversible.
			receipt(event.toolCallId, tool, plan, "blocked", { reason: "noUndo", category, asked: ask });
			return { block: true, reason: `Pippa could not save an undo copy first (${String(error)}). Nothing was changed. Tell the user.` };
		}
		approved.set(event.toolCallId, { tool, plan, undo, restorable, category, asked: ask });
		return undefined;
	});

	pi.on("tool_result", async (event: any, ctx: any) => {
		const entry = approved.get(event.toolCallId);
		if (!entry) return undefined;
		approved.delete(event.toolCallId);
		if (entry.category === "appEntry") {
			// What happened is told by Pippa's server (name with resolved date, mail state, undo entry).
			// Without its receipt (e.g. invalid arguments) only what Pi knows: done or failed.
			const told = serverReceipt(event, UNDO_ROOT);
			const outcome = told?.outcome ?? (event.isError ? "failed" : "done");
			const plan = { ...entry.plan, ...(told?.name ? { name: told.name } : {}) };
			const extra: Record<string, unknown> = { undo: told?.undo, restorable: told?.restorable ?? false, category: entry.category, asked: entry.asked };
			if (told?.reason) extra.reason = told.reason;
			if (event.isError && !told) {
				extra.error = (event.content ?? []).map((c: any) => (c?.type === "text" ? c.text : "")).join(" ").slice(0, 300);
			}
			receipt(event.toolCallId, entry.tool, plan, outcome, extra);
			return undefined;
		}
		let { undo, restorable } = entry;
		if (event.isError) {
			const message = (event.content ?? []).map((c: any) => (c?.type === "text" ? c.text : "")).join(" ").slice(0, 300);
			receipt(event.toolCallId, entry.tool, entry.plan, "failed", { error: message, category: entry.category, asked: entry.asked });
			return undefined;
		}
		if (entry.tool === "move_files" && undo) {
			// Partial success: only what really moved goes back (a planned but failed move would make undo report
			// "not there anymore"). Only moves that were planned and approved count.
			try {
				const manifest = JSON.parse(await readFile(join(undo, "manifest.json"), "utf8"));
				const planned = new Set((manifest.moves ?? []).map((m: any) => `${m.from}\n${m.to}`));
				const moved = (Array.isArray(event.details?.moved) ? event.details.moved : []).filter((m: any) => planned.has(`${m?.from}\n${m?.to}`));
				await writeManifest(undo, { ...manifest, moves: moved.map((m: any) => ({ from: m.from, to: m.to })) });
			} catch {
				// Keep the planned manifest: undo then brings back what is there and reports the rest.
			}
		}
		if (entry.tool === "move_to_trash") {
			undo = undefined;
			if (event.details?.trashedTo) {
				try {
					undo = undoFolder(event.toolCallId);
					await writeManifest(undo, {
						tool: entry.tool, toolCallId: event.toolCallId, cwd: ctx?.cwd ?? process.cwd(),
						moves: [{ from: event.details.path, to: event.details.trashedTo }], restorable: true,
					});
				} catch {
					undo = undefined;
				}
			}
			// Even without an entry it stays in the trash, so it can be undone (by hand).
			restorable = true;
		}
		receipt(event.toolCallId, entry.tool, entry.plan, "done", { undo, restorable, category: entry.category, asked: entry.asked });
		return undefined;
	});
}
