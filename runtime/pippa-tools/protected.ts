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
import { lstatSync, realpathSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, isAbsolute, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { resolvePath } from "./files.ts";

export const PROTECTED_VARIABLE = "PIPPA_PROTECTED_PATHS";
export const WORK_VARIABLE = "PIPPA_WORK_DIR";
const WORK_ID_VARIABLE = "PIPPA_WORK_ID";

export interface Protection {
	/** Protected places, as given (resolved when checked). */
	roots: string[];
	/** Places inside a protected one that stay open (the working folder). */
	open: { path: string; target: string; id: string }[];
	work?: string;
}

/** The protected places for this process, from the app's environment and the fixed defaults. */
export function protection(env: Record<string, string | undefined> = process.env, home = env.HOME || homedir()): Protection {
	const support = join(home, "Library", "Application Support", "Pippa");
	let given: unknown = [];
	try { given = JSON.parse(env[PROTECTED_VARIABLE] || "[]"); } catch { given = []; }
	const roots = [join(home, ".pi"), support, ...(Array.isArray(given) ? given : []), env.PI_CODING_AGENT_DIR, env.PIPPA_MEMORY_FILE]
		.filter((path): path is string => typeof path === "string" && isAbsolute(path));
	const configured = env[WORK_VARIABLE] ?? join(support, "pi-work");
	const path = isAbsolute(configured) ? resolve(configured) : undefined;
	const id = path && directoryEntryID(path);
	const open = path && id && (env[WORK_ID_VARIABLE] === undefined || env[WORK_ID_VARIABLE] === id) ? [{ path, target: real(path), id }] : [];
	const where = { roots: [...new Set(roots)], open, work: path };
	where.open = validOpenEntries(where);
	return where;
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

function identity(path: string, follow = true): string | undefined {
	try { const info = (follow ? statSync : lstatSync)(path, { bigint: true }); return `${info.dev}:${info.ino}`; } catch { return undefined; }
}

function directoryEntryID(path: string): string | undefined {
	try {
		const info = lstatSync(path, { bigint: true });
		if (info.isDirectory()) return `${info.dev}:${info.ino}`;
	} catch { /* an absent entry cannot open an exception */ }
}

function validOpenEntries(where: Protection): Protection["open"] {
	return where.open.filter(({ path, target, id }) =>
		directoryEntryID(path) === id && directoryEntryID(target) === id
		// The working folder must never contain a protected root.
		&& !where.roots.some((root) => [resolve(root), real(root)].some((name) => within(fold(name), fold(target)))));
}

export function invalidWorkTarget(cwd: string, where: Protection): boolean {
	return Boolean(where.work && real(where.work) === real(cwd) && validOpenEntries(where).length === 0);
}

function protectedLocation(target: string, where: Protection, follow = true): boolean {
	const ids = (paths: string[]) => new Set(paths.map((path) => identity(path)).filter(Boolean));
	const rootPaths = where.roots.flatMap((p) => [resolve(p), real(p)]);
	const rootIds = ids(where.roots), openIds = new Set(validOpenEntries(where).map((entry) => entry.id));
	const rootNames = rootPaths.map(fold);
	for (let current = target; ; current = dirname(current)) {
		const id = identity(current, follow);
		const name = fold(current);
		if ((id && rootIds.has(id)) || rootNames.includes(name)) return true;
		if (id && openIds.has(id)) return false;
		if (dirname(current) === current) return false;
	}
}

/** Whether an absolute path lies in a protected place, by the path it actually opens. */
export function isProtected(path: string, where: Protection = protection()): boolean {
	const target = real(path);
	// A hard link has no canonical parent. Refuse multiply linked regular files rather than trusting an open alias.
	try { const info = statSync(target); if (info.isFile() && info.nlink > 1) return true; } catch { /* not there yet */ }
	return protectedLocation(target, where);
}

/** A rename or trash changes directory entries, even when the last component is an outward-pointing symlink. */
export function assertMovableEntry(path: string, where: Protection): void {
	const entries = [resolve(path), join(real(dirname(path)), basename(path))];
	const candidates = [...entries, real(path)];
	const roots = where.roots.flatMap((root) => [resolve(root), real(root)]);
	if (isProtected(path, where) || entries.some((entry) => protectedLocation(entry, where, false))
		|| candidates.some((candidate) => roots.some((root) => within(fold(root), fold(candidate)) || isAncestorByIdentity(candidate, root)))) {
		throw new Error(PROTECTED_REASON);
	}
}

function isAncestorByIdentity(path: string, child: string): boolean {
	const id = identity(path);
	if (!id) return false;
	for (let current = child; ; current = dirname(current)) {
		if (identity(current) === id) return true;
		if (dirname(current) === current) return false;
	}
}

/** Base spelling used by Pi 1.5. Pi's read may then pick an existing alternate spelling. */
export function fileToolPath(path: string, cwd: string): string {
	const normalized = path.replace(/[\u00A0\u2000-\u200A\u202F\u205F\u3000]/g, " ").replace(/^@/, "");
	if (normalized.startsWith("file://")) return resolve(fileURLToPath(normalized));
	if (normalized === "~") return homedir();
	if (normalized.startsWith("~/")) return resolve(homedir(), normalized.slice(2));
	return resolve(cwd, normalized);
}

/** Authorize the effective operation path and return the same canonical target to the filesystem caller. */
export function checkedFile(path: string, where: Protection): string {
	const target = real(path);
	if (isProtected(target, where) || protectedLocation(path, where, false)) throw new Error(PROTECTED_REASON);
	// An existing component that realpath could not resolve must not be followed by a later write.
	for (let candidate = target; ; candidate = dirname(candidate)) {
		try {
			const info = lstatSync(candidate);
			if (info.isSymbolicLink()) throw new Error(PROTECTED_REASON);
			break;
		} catch (error: any) {
			if (error.code !== "ENOENT") throw error;
		}
	}
	return target;
}

export const PROTECTED_REASON = "Not done: this path is protected, or the file has multiple hard links and its origin cannot be verified. Pippa keeps her settings, conversations, notes and sign-ins private. "
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
		const trimmed = text.trim();
		if (!trimmed || trimmed.toLowerCase() === "trash") continue;
		for (const base of bases) {
			found.add(trimmed.startsWith("file://") ? resolve(fileURLToPath(trimmed)) : resolvePath(trimmed, base));
		}
	}
	return [...found];
}

/** Why a tool call is refused, or `undefined`. `bash` is left to its sandbox, which sees what a command really opens. */
export function toolCallReason(tool: string, input: unknown, cwd: string, where: Protection = protection()): string | undefined {
	if (tool === "bash") return undefined;
	const keys = tool.startsWith("mcp__") ? MCP_PATH_KEYS : PATH_KEYS;
	try {
		if (["read", "write", "edit"].includes(tool)) {
			const params = input as { path?: string; file_path?: string } | undefined;
			const path = params?.path ?? params?.file_path;
			return typeof path === "string" && isProtected(fileToolPath(path, cwd), where) ? PROTECTED_REASON : undefined;
		}
		return namedPaths(input, cwd, keys).some((path) => isProtected(path, where)) ? PROTECTED_REASON : undefined;
	} catch { return "Not done: invalid file path."; }
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
	const open = [...new Set(validOpenEntries(where).map((entry) => entry.target))];
	if (open.length) lines.push(`(allow file-read* file-write* ${open.map((path) => `(subpath ${lit(path)})`).join(" ")})`);
	return lines;
}
