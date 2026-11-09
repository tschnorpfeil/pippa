/**
 * Pippa's `bash` runs inside a macOS sandbox the system enforces (`sandbox-exec`). The model can use local utilities (sips, qpdf, ffmpeg, mdfind, …, and python where Apple's developer tools are installed);
 * the sandbox bounds ordinary shell execution; explicit app-control calls are refused before execution.
 * This is not a sandbox around Pi's built-in file tools or all capabilities of a standard task. Wired up in pippa-tools.ts.
 *
 * Always, without asking:
 * - read everything the person can read;
 * - write in Pippa's working folder (Pi's `cwd`), the temporary folders and the programs' caches, delete there too.
 *
 * Only after the person's OK (one card per kind and answer, `ctx.ui.confirm`):
 * - `net`: the internet. Asked before a command that plainly goes online (curl, pip, git clone, …), and after one
 *   that failed for lack of it.
 * - `write`: change files in the person's folders and on external drives. Asked after a command failed because it
 *   was not allowed to write there. The failed command is never replayed: partial effects must be checked before a
 *   later call does the remaining work. Before an approved write call runs, every existing file it names gets a
 *   copy (pippa-assist.ts `backUp`), so it can be undone.
 *
 * Without Apple's developer tools, /usr/bin/python3, git, make and the like are placeholders that open an install dialog
 * when started. Such a command is refused before it runs, and the profile forbids executing them (`env python3`,
 * scripts, `xargs git`), so the person never sees that dialog from Pippa.
 *
 * Never, not even after an OK: delete anything outside the working and temporary folders (the Trash is
 * `move_files` with `to: "trash"`), or write to `~/Library` (except iCloud Drive and cloud folders), dot folders such as `~/.ssh` or
 * `~/.pi`, and Pippa's own folder. An approved network grant still permits network requests; these rules are not
 * a universal no-send guarantee for standard tasks. Other executors have their own policies.
 */
import { spawnSync } from "node:child_process";
import { accessSync, constants, existsSync, readdirSync, realpathSync, statSync } from "node:fs";
import { stat } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { isAbsolute, join, relative, resolve, sep } from "node:path";

export type Grant = "net" | "write";

export const SANDBOX_EXEC = "/usr/bin/sandbox-exec";
/** Where Apple keeps the developer-tool placeholders. */
export const SHIM_DIR = "/usr/bin";
const SHIM_NAMES = ["python3", "pip3", "git", "make", "clang", "clang++", "cc", "c++", "gcc", "g++", "swift", "swiftc", "ld", "lldb",
	"strings", "otool", "nm", "m4", "xcrun", "xcodebuild", "xcode-select"];

/**
 * Whether Apple's developer tools are installed. `xcode-select -p` only prints the folder (it never opens the install
 * dialog); `xcrun` and the placeholders themselves would. Remembered for the process.
 */
let installed: boolean | undefined;
export function developerToolsInstalled(env: Record<string, string | undefined> = process.env): boolean {
	if (process.platform !== "darwin") return true;
	if (env.DEVELOPER_DIR && existsSync(env.DEVELOPER_DIR)) return true;
	if (installed === undefined) {
		const run = spawnSync("/usr/bin/xcode-select", ["-p"], { encoding: "utf8", timeout: 3000 });
		const folder = run.status === 0 ? String(run.stdout).trim() : "";
		installed = Boolean(folder) && existsSync(join(folder, "usr/bin/git"));
	}
	return installed;
}

/**
 * The placeholder names in `dir`: every entry that is the same file as git or one of Apple's launchers (hard links on
 * macOS: 78 share git's file, 16 xcodebuild's), plus the launchers. Without git there, the known names. Inode numbers
 * on the system volume lie near 2^60, past a double's precision, where neighbouring files such as afplay would compare
 * equal: they are compared as bigints.
 */
export function developerShims(dir = SHIM_DIR): string[] {
	const launchers = ["xcrun", "xcodebuild", "xcode-select"];
	const file = (name: string) => statSync(join(dir, name), { bigint: true });
	try {
		const anchors = [file("git"), ...launchers.flatMap((name) => { try { return [file(name)]; } catch { return []; } })];
		const same = readdirSync(dir).filter((name) => {
			try { const info = file(name); return anchors.some((shim) => shim.ino === info.ino && shim.dev === info.dev); } catch { return false; }
		});
		return [...new Set([...same, ...launchers])];
	} catch { return [...SHIM_NAMES]; }
}

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
export function sandboxProfile(grants: ReadonlySet<Grant>, where: Places, shims: readonly string[] = [], shimDir = SHIM_DIR): string {
	const home = where.home;
	const lines = ["(version 1)", "(allow default)"];
	if (!grants.has("net")) lines.push("(deny network*)");
	// No broad app-control grant: only Pippa's narrow native tools may change apps.
	lines.push("(deny appleevent-send)");
	lines.push(`(deny process-exec (literal "/usr/bin/osascript") (literal "/usr/bin/open") (literal "/usr/bin/shortcuts") (literal "/usr/bin/automator"))`);
	if (shims.length) lines.push(`(deny process-exec ${shims.map((name) => `(literal ${lit(join(shimDir, name))})`).join(" ")})`);
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
export function sandboxedCommand(command: string, grants: ReadonlySet<Grant>, where: Places, sandbox = SANDBOX_EXEC, shims: readonly string[] = [], shimDir = SHIM_DIR): string {
	return `exec ${sandbox} -p ${quote(sandboxProfile(grants, where, shims, shimDir))} /bin/bash -c ${quote(command)}`;
}

/** The first word of every part of a pipe or chain, and of `$( … )`, as written (with its folder, if any). */
function programWords(command: string): string[] {
	return command.split(/[;&|\n`()]|\$\(/).map((part) => {
		const words = part.trim().split(/\s+/).filter(Boolean);
		while (words.length && (/^\w+=/.test(words[0]) || ["sudo", "env", "command", "exec", "nohup", "time", "nice", "xargs"].includes(words[0]))) words.shift();
		return (words[0] ?? "").replace(/^["'\\]+|["']+$/g, "");
	}).filter(Boolean);
}

/** The programs a command runs, without their folders. */
function programs(command: string): string[] {
	return programWords(command).map((word) => word.split("/").pop() ?? "").filter(Boolean);
}

/** The folder a bare program name is found in first along `PATH`, as the shell would. */
function firstOnPath(name: string, env: Record<string, string | undefined>): string | undefined {
	for (const folder of (env.PATH ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(":")) {
		if (!folder) continue;
		const file = join(folder, name);
		try {
			accessSync(file, constants.X_OK);
			if (statSync(file).isFile()) return resolve(folder);
		} catch { /* not here */ }
	}
	return undefined;
}

/** The placeholder a command would start (the first match along `PATH` lives in `shimDir`), if any. */
export function shimStarted(command: string, shims: readonly string[], env: Record<string, string | undefined>, shimDir = SHIM_DIR): string | undefined {
	for (const word of programWords(command)) {
		const name = word.split("/").pop() ?? "";
		if (!shims.includes(name)) continue;
		if (word.includes("/") ? word === join(shimDir, name) : firstOnPath(name, env) === resolve(shimDir)) return name;
	}
	return undefined;
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
	return needs;
}

const NETWORK_FAILURE = /Could not resolve host|Couldn't connect|Failed to connect|nodename nor servname|Network is unreachable|getaddrinfo|Name or service not known|Temporary failure in name resolution|Failed to establish a new connection|URLError|unable to access '|Connection refused|No route to host/i;
const APPS_FAILURE = /Not authorized to send Apple events|\(-1743\)|errAEEventNotPermitted|\(-600\)|\/usr\/bin\/(?:osascript|open|shortcuts|automator): (?:Operation not permitted|Permission denied)/i;
export const APP_CONTROL_REASON = "Not run: app control is not available in Pippa’s shell. Use Pippa's native tools; Mail replies remain unsent drafts. Do not bypass this with another shell command, shortcut or URL.";
export function noDeveloperToolsReason(name: string): string {
	return `Not run: ${name} is not on this Mac. It comes with Apple's developer tools, which are not installed, and starting it would only open an install dialog. Use bash, awk, sed, sips, textutil or Pippa's own tools instead, or tell the person in one short sentence what you could not do. Do not install anything.`;
}
// A placeholder the profile forbids to start: `/bin/bash: /usr/bin/python3: Operation not permitted`, `env: python3: Operation not permitted`, `xargs: git: Operation not permitted`,
// and as a script's interpreter `/bin/bash: ./x.py: /usr/bin/python3: bad interpreter: Operation not permitted`.
const SHIM_FAILURE = /(?:\/usr\/bin\/|\b(?:env|xargs|find): )[\w+.-]+: (?:bad interpreter: )?Operation not permitted/;
const WRITE_FAILURE = /Operation not permitted/i;

/** Grants a failed command lacked, judged from its output. */
export function missingGrants(command: string, output: string, grants: ReadonlySet<Grant>): Set<Grant> {
	const missing = new Set<Grant>();
	if (!grants.has("net") && NETWORK_FAILURE.test(output)) missing.add("net");
	if (APPS_FAILURE.test(output) || SHIM_FAILURE.test(output) || programs(command).some((word) => APPS.has(word))) return missing;
	if (!grants.has("write") && !missing.size && WRITE_FAILURE.test(output)) missing.add("write");
	return missing;
}

/** Paths a command names (absolute, `~/…`, or existing relative paths in `cwd`), resolved. Only for the question and for copies; never for deciding. */
export function namedPaths(command: string, cwd: string, home = homedir()): string[] {
	const found = new Set<string>();
	const base = resolve(cwd);
	const token = /(["'])([^"']*)\1|((?:\\ |[^\s;&|<>()"'`$])+)/g;
	for (const match of command.matchAll(token)) {
		const raw = (match[2] ?? match[3] ?? "").replace(/\\ /g, " ");
		const cleaned = match[2] !== undefined ? raw : raw.replace(/^(?:--?[\w-]+=|\w+=)@?/, "");
		if (cleaned === "~" || cleaned.startsWith("~/") || cleaned.startsWith("/")) {
			const expanded = cleaned === "~" || cleaned.startsWith("~/") ? join(home, cleaned.slice(1)) : cleaned;
			const full = isAbsolute(expanded) ? expanded : resolve(base, expanded);
			found.add(full.replace(/\/+$/, "") || "/");
		} else if (cleaned && cleaned !== "." && cleaned !== ".." && !cleaned.startsWith("-") && !/^[A-Za-z_]\w*=/.test(cleaned) && !cleaned.includes("://")) {
			const full = resolve(base, cleaned);
			if (full !== base && existsSync(full)) found.add(full.replace(/\/+$/, "") || "/");
		}
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
	if (grants.has("write")) {
		const where = folders.length ? folders.join(", ") : (de ? "deinen Ordnern" : "your folders");
		parts.push(de ? `Dateien in ${where} ändern (vorher legt Pippa Kopien an)` : `change files in ${where} (Pippa keeps copies first)`);
	}
	const list = parts.length > 1 ? `${parts.slice(0, -1).join(", ")} ${de ? "und" : "and"} ${parts[parts.length - 1]}` : parts[0];
	const shown = command.length > 300 ? command.slice(0, 299) + "…" : command;
	return de
		? { title: grants.has("net") ? "Darf Pippa ins Internet?" : "Darf Pippa deine Dateien ändern?",
			message: `Für diese Antwort möchte Pippa mit einem Befehl ${list}.\n\nDetails:\n${shown}` }
		: { title: grants.has("net") ? "May Pippa go online?" : "May Pippa change your files?",
			message: `For this answer Pippa wants to use a command to ${list}.\n\nDetails:\n${shown}` };
}

export const SHELL_DECLINED_REASON = "Not run: the person said no. Do not try another way; tell them in one short sentence what you could not do.";
export const NO_SANDBOX_REASON = "Not run: Pippa's safe shell (sandbox-exec) is missing on this Mac. Use Pippa's other tools instead.";

/** A note appended to a failed command, so the model knows the limits instead of guessing. */
export function limitsNote(grants: ReadonlySet<Grant>, work: string, noDeveloperTools = false): string {
	const no: string[] = [];
	if (!grants.has("write")) no.push(`write only in ${work} and temporary folders (save results there, then move_files them where they belong; for one text file use write)`);
	no.push("never delete outside that folder (move_files to \"trash\" moves to the Trash)");
	if (!grants.has("net")) no.push("no internet (use web_search and fetch_content)");
	no.push("no app control (Pippa’s native tools cover Mail, Calendar, Reminders and Photos)");
	if (noDeveloperTools) no.push("no developer tools (python3, git, make, …): use bash, awk, sed");
	return `Note: bash runs in Pippa's sandbox: ${no.join("; ")}. Do not retry the same command.`;
}

/** Existing files of up to `limit` bytes among `paths`, under the person's folders: what gets a copy before a `write` run. */
export async function filesToKeep(paths: string[], where: Places, limit = 1024 ** 3): Promise<string[]> {
	const keep: string[] = [];
	const home = real(where.home), work = real(where.work), temps = where.temporary.map(real);
	for (const path of paths) {
		const resolved = real(path);
		const inside = (folder: string) => resolved === folder || resolved.startsWith(folder + "/");
		if (!(inside(home) || inside("/Volumes"))) continue;
		if (inside(work) || temps.some(inside)) continue;
		try { const info = await stat(resolved); if (info.isFile() && info.size <= limit) keep.push(path); } catch { /* not there yet */ }
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
	/** Whether Apple's developer tools are installed (default: asks `xcode-select -p` once). */
	developerTools?: () => boolean;
	/** Where the placeholders live (default /usr/bin). */
	shimDir?: string;
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
	const developerTools = deps.developerTools ?? (() => developerToolsInstalled(env));
	const shimDir = deps.shimDir ?? SHIM_DIR;
	let shims: string[] | undefined;
	/** The placeholders to keep out, or none when the tools are installed. */
	const lockedShims = (): string[] => developerTools() ? [] : (shims ??= developerShims(shimDir));
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
					if (programs(command).some((word) => APPS.has(word))) return notRun(APP_CONTROL_REASON);
					const locked = lockedShims();
					const shim = locked.length ? shimStarted(command, locked, env, shimDir) : undefined;
					if (shim) return notRun(noDeveloperToolsReason(shim));
					// Retain copies through failures and interruptions as well as successful completion.
					const kept = new Map<string, string>();
					const ask = async (need: Set<Grant>): Promise<boolean> => {
						if (!ctx?.hasUI || !ctx?.ui?.confirm) return false;
						const named = namedPaths(command, cwd, where.home);
						const candidates = named.length ? named : [real(cwd)];
						const outside = candidates.filter((p) => !(p === where.work || p.startsWith(where.work + "/")));
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
							return { ...spawn, command: sandboxedCommand(spawn.command, now, where, sandbox, locked, shimDir) };
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
						if (result?.isError) result = withNote(result, limitsNote(grants, where.work, locked.length > 0));
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
