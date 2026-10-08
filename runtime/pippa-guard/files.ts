/**
 * Shared file helpers for the Pippa guard (pippa-guard.ts) and Pippa's narrow file tools (pippa-tools.ts).
 * Both must compute the same paths: the guard asks and backs up, the tool executes.
 */
import { execFile } from "node:child_process";
import { copyFile, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, dirname, isAbsolute, join, resolve } from "node:path";

/** Like Pi itself: leading @ dropped, ~ expanded, relative to the working folder. */
export function resolvePath(raw: unknown, cwd: string): string {
	let p = String(raw ?? "").trim().replace(/^@/, "");
	if (p === "~") p = homedir();
	else if (p.startsWith("~/")) p = join(homedir(), p.slice(2));
	return isAbsolute(p) ? resolve(p) : resolve(cwd, p);
}

export async function exists(path: string): Promise<boolean> {
	try {
		await stat(path);
		return true;
	} catch {
		return false;
	}
}

export async function isFolder(path: string): Promise<boolean> {
	try {
		return (await stat(path)).isDirectory();
	} catch {
		return false;
	}
}

/** German phrase for the person, e.g. "die Datei „Notizen.txt“ im Ordner „Test“": folder name instead of a long path; the path goes in the detail line. */
export function fileWords(path: string, folder = false): string {
	const parent = basename(dirname(path)) || dirname(path);
	return `${folder ? "den Ordner" : "die Datei"} „${basename(path)}“ im Ordner „${parent}“`;
}

/**
 * Target of "rename or move": if `to` is an existing folder, `from` ends up inside it (like Finder and mv); otherwise
 * `to` is the new name or path. A relative `to` without a folder part stays in the folder of `from`
 * ("Einkauf.txt" -> "Liste.txt" means rename, not move to the working folder).
 */
export async function moveTarget(from: string, rawTo: unknown, cwd: string): Promise<string> {
	const text = String(rawTo ?? "").trim();
	const plainName = text !== "" && !text.includes("/") && !text.startsWith("~") && !text.startsWith("@");
	const to = plainName ? join(dirname(from), text) : resolvePath(text, cwd);
	if (await isFolder(to)) return join(to, basename(from));
	// "Move it to Archiv": a folder of that name in the working folder counts too.
	if (plainName && (await isFolder(resolvePath(text, cwd)))) return join(resolvePath(text, cwd), basename(from));
	return to;
}

/**
 * Copy as an APFS clone (takes no space until one side changes). Node 22-25 does not clone on macOS even with
 * `COPYFILE_FICLONE` (measured: different blocks; `COPYFILE_FICLONE_FORCE` -> ENOSYS), hence `/bin/cp -c`
 * (clonefile). If that fails (other volume, no APFS), an ordinary copy. `dest` must not exist yet.
 */
export async function cloneFile(source: string, dest: string): Promise<"clone" | "copy"> {
	const cloned = await new Promise<boolean>((done) => {
		execFile("/bin/cp", ["-c", "--", source, dest], { timeout: 60_000 }, (error) => done(!error));
	});
	if (cloned) return "clone";
	await copyFile(source, dest);
	return "copy";
}

/** One planned item of `move_files`: `from` → `to` (target folder `into`), or why it cannot move. */
export interface PlannedMove {
	name: string;
	from: string;
	to: string;
	into: string;
	error?: string;
}

/**
 * Plan of `move_files` (pippa-tools.ts), computed the same way by the guard (question, undo manifest) and the tool.
 * `rawGroups` groups the files by target, `[{ into: "Bilder", files: ["a.jpg", "b.png"] }, { into: "PDFs/2026", files: [...] }]`,
 * so every target name is written once (fewer output tokens than one `{name, into}` object per file). A list of typed
 * objects rather than a map `{"Bilder": [...]}`: some chat templates drop `additionalProperties`, so the model saw
 * an untyped object and wrote comma-separated strings (r7 sort). A map is still accepted. A target is a subfolder of
 * `folder`: relative (may be nested) or a path that lands inside `folder`; a target outside `folder` gets a per-item
 * error (other places: rename_or_move). A name is a file or folder in `folder`.
 * Never overwrites: an existing target, a missing source or a second item with the same target gets an `error`.
 * `created`: target folders (and folders in between) that do not exist yet and will be created; `folders`: the topmost
 * of those (undo moves them to the trash while empty), like a plain `mkdir -p` (pippa-guard.ts `plannedFolders`).
 */
export async function planMoves(rawFolder: unknown, rawGroups: unknown, cwd: string): Promise<{ folder: string; items: PlannedMove[]; folders: string[]; created: string[] }> {
	const folder = resolvePath(rawFolder || ".", cwd);
	const items: PlannedMove[] = [];
	const targets = new Set<string>();
	const folders: string[] = [];
	const created: string[] = [];
	const groups: [unknown, unknown][] = Array.isArray(rawGroups)
		? rawGroups.map((group: any) => [group?.into, group?.files])
		: rawGroups && typeof rawGroups === "object" ? Object.entries(rawGroups as Record<string, unknown>) : [];
	for (const [rawTarget, rawNames] of groups) {
		const intoText = String(rawTarget ?? "").trim();
		// Written as a path ("~/Downloads/Bilder") is fine as long as it lands inside folder (r7: models do that).
		const into = resolvePath(intoText, folder);
		const outside = !into.startsWith(`${folder}/`);
		for (const raw of Array.isArray(rawNames) ? rawNames : rawNames == null ? [] : [rawNames]) {
			const name = String(raw ?? "").trim();
			const from = resolvePath(name, folder);
			const to = join(into, basename(from));
			const item: PlannedMove = { name: name || "?", from, to, into };
			items.push(item);
			if (!name || !intoText) item.error = "needs a file name and a target folder";
			else if (outside) item.error = "target must be a subfolder of folder; use rename_or_move for other places";
			else if (!(await exists(from))) item.error = "not found";
			else if (from === to) item.error = "already there";
			else if (into === from || into.startsWith(`${from}/`)) item.error = "cannot move a folder into itself";
			else if (targets.has(to) || (await exists(to))) item.error = `'${basename(to)}' already exists there`;
			else if ((await exists(into)) && !(await isFolder(into))) item.error = `'${basename(into)}' is a file, not a folder`;
			if (item.error) continue;
			targets.add(to);
			const missing: string[] = [];
			for (let dir = into; dir !== dirname(dir) && !(await exists(dir)); dir = dirname(dir)) missing.unshift(dir);
			for (const dir of missing) if (!created.includes(dir)) created.push(dir);
			if (missing.length && !folders.some((f) => missing[0] === f || missing[0].startsWith(`${f}/`))) folders.push(missing[0]);
		}
	}
	return { folder, items, folders, created };
}

/** Short label of a target folder for results: relative to `folder` with a trailing slash, otherwise the path with ~. */
export function folderLabel(into: string, folder: string): string {
	if (into.startsWith(`${folder}/`)) return `${into.slice(folder.length + 1)}/`;
	const home = homedir();
	return into === home || into.startsWith(`${home}/`) ? `~${into.slice(home.length)}/` : `${into}/`;
}
