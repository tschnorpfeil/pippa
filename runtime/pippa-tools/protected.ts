/**
 * Places no tool the model calls may read, list, change or move (issue #196 review): Pippa's own folder (settings and
 * the online AI's Mac access, conversations, Pi sessions of every route, the notes file, pinned credential folders,
 * backups, the local server's key) and Pi's agent folders (`~/.pi`: auth.json, models.json, terminal sessions). Pippa's
 * code and Pi itself still use them; only model-facing tools are refused. The working folder inside Pippa's folder
 * (`pi-work`) stays open. File modes are no help here: everything belongs to the same user.
 *
 * - The app passes the places it knows (`PIPPA_PROTECTED_PATHS`, a JSON list; `PIPPA_WORK_DIR`, the working folder);
 *   `~/.pi`, `~/Library/Application Support/Pippa`, `PI_CODING_AGENT_DIR` and the notes file are always added,
 *   so a run without the app's environment fails closed.
 * - A path counts by the folder it really is in: symlinks are resolved and every folder on the way up is compared by
 *   device and inode with the protected ones, so other letter case, `..`, `/private`, and the `/System/Volumes/Data`
 *   firmlink all name the same place.
 * - pippa-tools.ts refuses a call that names such a place before any tool runs (`toolCallReason`) and checks the path
 *   again where `read` and `write` run; shell.ts denies reading and writing there inside the sandbox
 *   (`sandboxRules`), whatever the person granted; `list_folder` and `search_files` leave such entries out.
 */
import { realpathSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, isAbsolute, join, resolve } from "node:path";
import { resolvePath } from "./files.ts";

export const PROTECTED_VARIABLE = "PIPPA_PROTECTED_PATHS";
export const WORK_VARIABLE = "PIPPA_WORK_DIR";

export interface Protection {
	/** Protected places, as given (resolved when checked). */
	roots: string[];
	/** Places inside a protected one that stay open (the working folder). */
	open: string[];
}

/** The protected places for this process, from the app's environment and the fixed defaults. */
export function protection(env: Record<string, string | undefined> = process.env, home = env.HOME || homedir()): Protection {
	const support = join(home, "Library", "Application Support", "Pippa");
	let given: unknown = [];
	try { given = JSON.parse(env[PROTECTED_VARIABLE] || "[]"); } catch { given = []; }
	const roots = [join(home, ".pi"), support, ...(Array.isArray(given) ? given : []), env.PI_CODING_AGENT_DIR, env.PIPPA_MEMORY_FILE]
		.filter((path): path is string => typeof path === "string" && isAbsolute(path));
	const open = [env[WORK_VARIABLE] || join(support, "pi-work")].filter((path) => isAbsolute(path))
		// An open place never contains a protected one.
		.filter((path) => !roots.some((root) => within(fold(real(root)), fold(real(path)))));
	return { roots: [...new Set(roots)], open };
}

/** The real path, with the part that does not exist yet appended as written. */
export function real(path: string): string {
	const rest: string[] = [];
	let current = resolve(path);
	for (;;) {
		try { return join(realpathSync.native(current), ...rest.reverse()); } catch { /* not there (yet) */ }
		const up = dirname(current);
		if (up === current) return resolve(path);
		rest.push(basename(current));
		current = up;
	}
}

/** APFS compares names without case and Unicode form. */
function fold(path: string): string {
	return path.normalize("NFC").toLowerCase();
}

function within(path: string, folder: string): boolean {
	return path === folder || path.startsWith(folder.endsWith("/") ? folder : folder + "/");
}

function identity(path: string): string | undefined {
	try { const info = statSync(path, { bigint: true }); return `${info.dev}:${info.ino}`; } catch { return undefined; }
}

/** Whether `path` (absolute) lies in a protected place, by real location: the nearest of open or protected wins. */
export function isProtected(path: string, where: Protection = protection()): boolean {
	const target = real(path);
	const ids = (paths: string[]) => new Set(paths.map((p) => identity(real(p))).filter(Boolean));
	const names = (paths: string[]) => paths.flatMap((p) => [fold(resolve(p)), fold(real(p))]);
	const rootIds = ids(where.roots), openIds = ids(where.open);
	const rootNames = names(where.roots), openNames = names(where.open);
	for (let current = target; ; current = dirname(current)) {
		const id = identity(current);
		const name = fold(current);
		if ((id && openIds.has(id)) || openNames.includes(name)) return false;
		if ((id && rootIds.has(id)) || rootNames.includes(name)) return true;
		if (dirname(current) === current) return false;
	}
}

export const PROTECTED_REASON = "Not done: this is Pippa's own folder (her settings, conversations, notes and sign-ins) or Pi's sign-in folder. "
	+ "No tool may read or change it. Do not try another way; tell the person in one short sentence that Pippa keeps it to herself.";

/** Keys whose string values (or lists of them) name files or folders in a tool's arguments. The app's MCP tools name
 * files only as `path`/`paths` (`read_document`, `prepare_files`); their `from` is a mail sender. */
const PATH_KEYS = new Set(["path", "paths", "file_path", "file", "files", "from", "to", "folder", "into", "directory", "dir", "cwd"]);
const MCP_PATH_KEYS = new Set(["path", "paths"]);

/** Every path a tool call names, resolved the ways the tool could resolve it (relative to the working folder, to
 * `folder`, and a plain name next to `from`). Over-inclusive on purpose. */
export function namedPaths(input: unknown, cwd: string, keys: ReadonlySet<string> = PATH_KEYS): string[] {
	const raw: string[] = [];
	const visit = (value: unknown, key?: string) => {
		if (typeof value === "string") { if (key && keys.has(key)) raw.push(value); return; }
		if (Array.isArray(value)) { for (const item of value) visit(item, key); return; }
		if (value && typeof value === "object") for (const [name, item] of Object.entries(value)) visit(item, name);
	};
	visit(input);
	const object = input && typeof input === "object" ? input as Record<string, unknown> : {};
	const bases = [cwd];
	if (typeof object.folder === "string" && object.folder.trim()) bases.push(resolvePath(object.folder, cwd));
	if (typeof object.from === "string" && object.from.trim()) bases.push(dirname(resolvePath(object.from, cwd)));
	const found = new Set<string>();
	for (const text of raw) {
		const trimmed = text.trim().replace(/^file:\/\//, "");
		if (!trimmed || trimmed.toLowerCase() === "trash") continue;
		for (const base of bases) found.add(resolvePath(trimmed, base));
	}
	return [...found];
}

/** Why a tool call is refused, or `undefined`. `bash` is left to its sandbox, which sees what a command really opens. */
export function toolCallReason(tool: string, input: unknown, cwd: string, where: Protection = protection()): string | undefined {
	if (tool === "bash") return undefined;
	const keys = tool.startsWith("mcp__") ? MCP_PATH_KEYS : PATH_KEYS;
	return namedPaths(input, cwd, keys).some((path) => isProtected(path, where)) ? PROTECTED_REASON : undefined;
}

/** A tool definition whose `execute` checks its path again right before it runs (a symlink may appear meanwhile). */
export function guarded(definition: any, where: () => Protection = () => protection()): any {
	return {
		...definition,
		async execute(id: string, params: any, signal: AbortSignal | undefined, onUpdate: unknown, ctx: any) {
			const reason = toolCallReason(definition.name, params, ctx?.cwd || process.cwd(), where());
			if (reason) return { content: [{ type: "text", text: reason }], isError: true, details: { pippaProtected: true } };
			return definition.execute(id, params, signal, onUpdate, ctx);
		},
	};
}

/** SBPL string literal. */
function lit(path: string): string {
	return `"${path.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
}

/** The shell's sandbox rules: no reading or writing in protected places, the open ones excepted. Last in the profile,
 * after every grant, since in SBPL the last matching rule wins. The sandbox compares real paths. */
export function sandboxRules(where: Protection = protection()): string[] {
	const roots = [...new Set(where.roots.map(real))];
	if (!roots.length) return [];
	const lines = [`(deny file-read* file-write* ${roots.map((root) => `(subpath ${lit(root)})`).join(" ")})`];
	const open = [...new Set(where.open.map(real))];
	if (open.length) lines.push(`(allow file-read* file-write* ${open.map((path) => `(subpath ${lit(path)})`).join(" ")})`);
	return lines;
}
