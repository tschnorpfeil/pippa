/**
 * Pippa's `bash`: the full shell, inside a macOS sandbox the system enforces (`sandbox-exec`), so no command text, quote
 * or detour can get around it. The model keeps every program on the Mac (python, sips, qpdf, ffmpeg, mdfind, …);
 * what a command may touch is decided by the sandbox, not by reading the command. Wired up in pippa-tools.ts.
 *
 * Always, without asking:
 * - read everything the person can read;
 * - write in Pippa's working folder (Pi's `cwd`), the temporary folders and the programs' caches, delete there too.
 *
 * Only after the person's OK (one card per kind and answer, `ctx.ui.confirm`):
 * - `net`: the internet. Asked before a command that plainly goes online (curl, pip, git clone, …), and after one
 *   that failed for lack of it.
 * - `apps`: other apps (Apple Events, `open`, `shortcuts`), e.g. Mail could send. Asked before `osascript`, `open`,
 *   `shortcuts`.
 * - `write`: change files in the person's folders and on external drives. Asked after a command failed because it
 *   was not allowed to write there. The failed command is never replayed: partial effects must be checked before a
 *   later call does the remaining work. Before an approved write call runs, every existing file it names gets a
 *   copy (pippa-assist.ts `backUp`), so it can be undone.
 *
 * Never, not even after an OK: delete anything outside the working and temporary folders (the Trash is
 * `move_to_trash`), or write to `~/Library` (except iCloud Drive and cloud folders), dot folders such as `~/.ssh` or
 * `~/.pi`, and Pippa's own folder. So a planted instruction in a letter cannot wipe a folder, send a file or install
 * something that starts with the Mac.
 */
import { existsSync, realpathSync } from "node:fs";
import { stat } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { isAbsolute, join, relative, resolve, sep } from "node:path";

export type Grant = "net" | "apps" | "write";

export const SANDBOX_EXEC = "/usr/bin/sandbox-exec";

/** The folders the profile is built from, as real paths (the sandbox compares resolved paths: /var is /private/var). */
export interface Places {
	home: string;
	/** Pi's working folder: always writable. */
	work: string;
	/** Pippa's own folder (memory, backups, settings): never writable by bash, except `work` inside it. */
	support?: string;
	temporary: string[];
}

function real(path: string): string {
	try { return realpathSync(path); } catch { return resolve(path); }
}

export function places(work: string, env: Record<string, string | undefined> = process.env, home = homedir()): Places {
	const memory = env.PIPPA_MEMORY_FILE;
	const temporary = [...new Set([tmpdir(), env.TMPDIR ?? "", "/private/tmp", "/private/var/tmp"].filter(Boolean).map(real))];
	return { home: real(home), work: real(work), support: memory ? real(join(memory, "..")) : undefined, temporary };
}

/** An SBPL string literal. */
function lit(path: string): string {
	return `"${path.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
}

/** A POSIX regex for everything directly below `folder` whose name starts with a dot (`~/.ssh`, `~/.zshrc`). */
function dotEntries(folder: string): string {
	return `#"^${folder.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}/\\."`;
}

/**
 * The sandbox profile for this set of grants. In SBPL the last matching rule wins, so the order is: broad denies,
 * what a grant allows, what stays forbidden anyway, and the working folders last.
 */
export function sandboxProfile(grants: ReadonlySet<Grant>, where: Places): string {
	const home = where.home;
	const lines = ["(version 1)", "(allow default)"];
	if (!grants.has("net")) lines.push("(deny network*)");
	if (!grants.has("apps")) {
		lines.push("(deny appleevent-send)");
		lines.push(`(deny process-exec (literal "/usr/bin/open") (literal "/usr/bin/shortcuts") (literal "/usr/bin/automator"))`);
	}
	lines.push(`(deny file-write* (subpath ${lit(home)}) (subpath "/Volumes") (subpath "/Users/Shared") (subpath "/Applications") (subpath "/Library"))`);
	if (grants.has("write")) {
		lines.push(`(allow file-write* (subpath ${lit(home)}) (subpath "/Volumes") (subpath "/Users/Shared"))`);
		lines.push(`(deny file-write* (subpath ${lit(join(home, "Library"))}) (regex ${dotEntries(home)}))`);
		lines.push(`(allow file-write* (subpath ${lit(join(home, "Library", "Mobile Documents"))}) (subpath ${lit(join(home, "Library", "CloudStorage"))}))`);
	}
	// Caches are the programs' own business (Python, Homebrew, Swift); nothing of the person's lives there.
	lines.push(`(allow file-write* (subpath ${lit(join(home, "Library", "Caches"))}) (subpath ${lit(join(home, ".cache"))}))`);
	lines.push(`(deny file-write-unlink (subpath ${lit(home)}) (subpath "/Volumes") (subpath "/Users/Shared"))`);
	if (where.support) lines.push(`(deny file-write* (subpath ${lit(where.support)}))`);
	lines.push(`(allow file-write* (subpath ${lit(where.work)})${where.temporary.map((t) => ` (subpath ${lit(t)})`).join("")})`);
	return lines.join("\n") + "\n";
}

/** `'…'` for bash. */
export function quote(text: string): string {
	return `'${text.replace(/'/g, `'\\''`)}'`;
}

/** What Pi runs instead of the command: the same command, in a bash inside the sandbox. */
export function sandboxedCommand(command: string, grants: ReadonlySet<Grant>, where: Places, sandbox = SANDBOX_EXEC): string {
	return `exec ${sandbox} -p ${quote(sandboxProfile(grants, where))} /bin/bash -c ${quote(command)}`;
}

/** The words a command runs: the first word of every part of a pipe or chain, and of `$( … )`. */
function programs(command: string): string[] {
	return command.split(/[;&|\n`()]|\$\(/).map((part) => {
		const words = part.trim().split(/\s+/).filter(Boolean);
		while (words.length && (/^\w+=/.test(words[0]) || ["sudo", "env", "command", "exec", "nohup", "time", "nice", "xargs"].includes(words[0]))) words.shift();
		return (words[0] ?? "").replace(/^["'\\]+|["']+$/g, "").split("/").pop() ?? "";
	}).filter(Boolean);
}

const NETWORK = new Set(["curl", "wget", "pip", "pip3", "brew", "npm", "npx", "yarn", "pnpm", "gem", "cargo", "ssh", "scp", "sftp",
	"ftp", "telnet", "nc", "ncat", "netcat", "ping", "dig", "nslookup", "host", "whois", "softwareupdate", "mas", "uv", "pipx"]);
const APPS = new Set(["osascript", "open", "shortcuts", "automator"]);

/**
 * Grants a command plainly needs, to ask before it runs. Only a convenience: a command that hides its intent simply
 * fails in the sandbox and is asked about afterwards (`missingGrants`), or not at all.
 */
export function neededGrants(command: string): Set<Grant> {
	const needs = new Set<Grant>();
	const words = programs(command);
	if (words.some((w) => NETWORK.has(w)) || /\bgit\s+(clone|pull|fetch|push|ls-remote)\b/.test(command)
		|| /\brsync\b[^|;&]*\s[\w.-]+@?[\w.-]+:/.test(command)) needs.add("net");
	if (words.some((w) => APPS.has(w))) needs.add("apps");
	return needs;
}

const NETWORK_FAILURE = /Could not resolve host|Couldn't connect|Failed to connect|nodename nor servname|Network is unreachable|getaddrinfo|Name or service not known|Temporary failure in name resolution|Failed to establish a new connection|URLError|unable to access '|Connection refused|No route to host/i;
const APPS_FAILURE = /Not authorized to send Apple events|\(-1743\)|errAEEventNotPermitted|\(-600\)/i;
const WRITE_FAILURE = /Operation not permitted/i;

/** Grants a failed command lacked, judged from its output. */
export function missingGrants(command: string, output: string, grants: ReadonlySet<Grant>): Set<Grant> {
	const missing = new Set<Grant>();
	if (!grants.has("net") && NETWORK_FAILURE.test(output)) missing.add("net");
	if (!grants.has("apps") && (APPS_FAILURE.test(output) || (/Operation not permitted/i.test(output) && programs(command).some((w) => APPS.has(w))))) missing.add("apps");
	if (!grants.has("write") && !missing.size && WRITE_FAILURE.test(output)) missing.add("write");
	return missing;
}

/** Paths a command names (absolute or `~/…`), resolved. Only for the question and for copies; never for deciding. */
export function namedPaths(command: string, cwd: string, home = homedir()): string[] {
	const found = new Set<string>();
	const token = /(["'])((?:~|\/)[^"']*)\1|((?:~|\/)(?:\\ |[^\s;&|<>()"'`$])+)/g;
	for (const match of command.matchAll(token)) {
		let path = (match[2] ?? match[3] ?? "").replace(/\\ /g, " ");
		if (path === "~" || path.startsWith("~/")) path = join(home, path.slice(1));
		if (!isAbsolute(path)) path = resolve(cwd, path);
		found.add(path.replace(/\/+$/, "") || "/");
	}
	return [...found];
}

/** Everyday names for the folders a command would change: "Schreibtisch", "Dokumente/Steuer", "USB-Stick". */
export function folderNames(paths: string[], home: string, language = process.env.PIPPA_LANGUAGE ?? ""): string[] {
	const de = language.startsWith("de");
	const names: Record<string, string> = de
		? { Desktop: "Schreibtisch", Documents: "Dokumente", Downloads: "Downloads", Pictures: "Bilder", Movies: "Filme", Music: "Musik" }
		: { Desktop: "Desktop", Documents: "Documents", Downloads: "Downloads", Pictures: "Pictures", Movies: "Movies", Music: "Music" };
	const out = new Set<string>();
	for (const path of paths) {
		if (path.startsWith("/Volumes/")) { out.add(path.split("/").slice(0, 3).join("/")); continue; }
		const rel = relative(home, path);
		if (!rel || rel.startsWith("..") || isAbsolute(rel)) continue;
		const parts = rel.split(sep);
		if (parts[0].startsWith(".") || parts[0] === "Library") continue;
		const first = names[parts[0]] ?? parts[0];
		out.add(parts.length > 2 ? `${first}/${parts[1]}` : first);
	}
	return [...out].slice(0, 4);
}

/** The question for the person, in the app's language: everyday words first, the command only at the end. */
export function grantAskText(grants: ReadonlySet<Grant>, command: string, folders: string[], language = process.env.PIPPA_LANGUAGE ?? ""): { title: string; message: string } {
	const de = language.startsWith("de");
	const parts: string[] = [];
	if (grants.has("net")) parts.push(de ? "ins Internet gehen" : "go online");
	if (grants.has("apps")) parts.push(de ? "andere Programme steuern (zum Beispiel Mail)" : "control other apps (for example Mail)");
	if (grants.has("write")) {
		const where = folders.length ? folders.join(", ") : (de ? "deinen Ordnern" : "your folders");
		parts.push(de ? `Dateien in ${where} ändern (vorher legt Pippa Kopien an)` : `change files in ${where} (Pippa keeps copies first)`);
	}
	const list = parts.length > 1 ? `${parts.slice(0, -1).join(", ")} ${de ? "und" : "and"} ${parts[parts.length - 1]}` : parts[0];
	const shown = command.length > 300 ? command.slice(0, 299) + "…" : command;
	return de
		? { title: grants.has("net") ? "Darf Pippa ins Internet?" : grants.has("apps") ? "Darf Pippa andere Programme steuern?" : "Darf Pippa deine Dateien ändern?",
			message: `Für diese Antwort möchte Pippa mit einem Befehl ${list}.\n\nDetails:\n${shown}` }
		: { title: grants.has("net") ? "May Pippa go online?" : grants.has("apps") ? "May Pippa control other apps?" : "May Pippa change your files?",
			message: `For this answer Pippa wants to use a command to ${list}.\n\nDetails:\n${shown}` };
}

export const SHELL_DECLINED_REASON = "Not run: the person said no. Do not try another way; tell them in one short sentence what you could not do.";
export const NO_SANDBOX_REASON = "Not run: Pippa's safe shell (sandbox-exec) is missing on this Mac. Use Pippa's other tools instead.";

/** A note appended to a failed command, so the model knows the limits instead of guessing. */
export function limitsNote(grants: ReadonlySet<Grant>, work: string): string {
	const no: string[] = [];
	if (!grants.has("write")) no.push(`write only in ${work} and temporary folders (save results there, then move_files them where they belong; for one text file use write)`);
	no.push("never delete outside that folder (use move_to_trash)");
	if (!grants.has("net")) no.push("no internet (use web_search and fetch_content)");
	if (!grants.has("apps")) no.push("no other apps");
	return `Note: bash runs in Pippa's sandbox: ${no.join("; ")}. Do not retry the same command.`;
}

/** Existing files of up to `limit` bytes among `paths`, under the person's folders: what gets a copy before a `write` run. */
export async function filesToKeep(paths: string[], where: Places, limit = 1024 ** 3): Promise<string[]> {
	const keep: string[] = [];
	for (const path of paths) {
		const inside = (folder: string) => path === folder || path.startsWith(folder + "/");
		if (!(inside(where.home) || inside("/Volumes"))) continue;
		if (inside(where.work) || where.temporary.some(inside)) continue;
		try { const info = await stat(path); if (info.isFile() && info.size <= limit) keep.push(path); } catch { /* not there yet */ }
	}
	return keep.slice(0, 50);
}

export function sandboxAvailable(sandbox = SANDBOX_EXEC): boolean {
	return existsSync(sandbox);
}

/** The text of a tool result. */
function textOf(result: any): string {
	return (result?.content ?? []).filter((p: any) => p?.type === "text").map((p: any) => String(p.text ?? "")).join("\n");
}

function withNote(result: any, note: string): any {
	return { ...result, content: [...(result?.content ?? []), { type: "text", text: note }] };
}

export interface ShellDeps {
	sandbox?: string;
	available?: () => boolean;
	/** Keeps a copy of a file before a `write` run; the copy's path (pippa-assist.ts `backUp`). */
	keep?: (file: string) => Promise<string | undefined>;
	env?: Record<string, string | undefined>;
	home?: string;
}

/**
 * Pi's own bash tool (`create` = `createBashToolDefinition`), run through the sandbox. Grants hold for one answer
 * (`resetAnswer` at each agent start). The model sees the same tool, the transcript the person's command unchanged.
 */
export function shellTool(create: (cwd: string, options?: any) => any, deps: ShellDeps = {}) {
	const sandbox = deps.sandbox ?? SANDBOX_EXEC;
	const available = deps.available ?? (() => sandboxAvailable(sandbox));
	const env = deps.env ?? process.env;
	const home = deps.home ?? homedir();
	let grants = new Set<Grant>();

	return {
		resetAnswer() { grants = new Set(); },
		get grants(): ReadonlySet<Grant> { return grants; },
		definition(defaultCwd: string) {
			const base = create(defaultCwd);
			return {
				...base,
				async execute(id: string, params: any, signal: AbortSignal | undefined, onUpdate: unknown, ctx: any) {
					const cwd = ctx?.cwd || defaultCwd;
					const notRun = (reason: string) => ({ content: [{ type: "text", text: reason }], isError: true,
						details: { pippaExecution: "not_dispatched" } });
					if (signal?.aborted) return notRun("Stopped before running the command.");
					if (!available()) return notRun(NO_SANDBOX_REASON);
					const where = places(cwd, env, home);
					const command = String(params?.command ?? "");
					// Retain copies through failures and interruptions as well as successful completion.
					const kept = new Map<string, string>();
					const ask = async (need: Set<Grant>): Promise<boolean> => {
						if (!ctx?.hasUI || !ctx?.ui?.confirm) return false;
						const outside = namedPaths(command, cwd, where.home).filter((p) => !(p === where.work || p.startsWith(where.work + "/")));
						const { title, message } = grantAskText(need, command, folderNames(outside, where.home, env.PIPPA_LANGUAGE ?? ""), env.PIPPA_LANGUAGE ?? "");
						return Boolean(await ctx.ui.confirm(title, message));
					};
					const run = async () => {
						const now = new Set(grants);
						if (signal?.aborted) return notRun("Stopped before running the command.");
						if (now.has("write") && deps.keep) {
							for (const file of await filesToKeep(namedPaths(command, cwd, where.home), where)) {
								if (kept.has(file)) continue;
								const copy = await deps.keep(file);
								if (copy) kept.set(file, copy);
							}
						}
						let dispatched = false;
						const tool = create(cwd, { spawnHook: (spawn: any) => {
							dispatched = true;
							return { ...spawn, command: sandboxedCommand(spawn.command, now, where, sandbox) };
						} });
						try {
							const result = await tool.execute(id, params, signal, onUpdate, ctx);
							return { ...result, details: { ...(result.details ?? {}), pippaExecution: "attempted" } };
						} catch (error) {
							// Pi throws on abort/timeout after a command may have changed files. Return the error together
							// with our effect evidence instead of letting Pi replace it and lose the undo copies.
							return { content: [{ type: "text", text: error instanceof Error ? error.message : String(error) }],
								isError: true, details: { pippaExecution: dispatched ? "uncertain" : "not_dispatched" } };
						}
					};

					const before = new Set([...neededGrants(command)].filter((g) => !grants.has(g)));
					if (before.size) {
						if (!(await ask(before))) return notRun(SHELL_DECLINED_REASON);
						for (const g of before) grants.add(g);
					}
					let result = await run();
					if (result?.isError) {
						const missing = missingGrants(command, textOf(result), grants);
						if (!signal?.aborted && result.details?.pippaExecution !== "uncertain" && missing.size && (await ask(missing))) {
							for (const g of missing) grants.add(g);
							// A compound command can have completed earlier steps before the permission error.
							// Granting access cannot make replay safe; return the original failure for recovery.
							result = withNote(result, "Permission is now available for this answer, but the failed command was not rerun. It may already have changed something before failing. Check its effects, then use a separate, narrowly scoped call for only the remaining work. Do not repeat completed steps.");
						}
						if (result?.isError) result = withNote(result, limitsNote(grants, where.work));
					}
					if (kept.size) {
						const copies = [...kept].map(([file, copy]) => ({ file, copy }));
						result = withNote(result, copies.map(({ file, copy }) => `The previous version of ${file} is kept at ${copy}.`).join("\n"));
						result = { ...result, details: { ...(result.details ?? {}), pippaKept: copies } };
					}
					return result;
				},
			};
		},
	};
}
