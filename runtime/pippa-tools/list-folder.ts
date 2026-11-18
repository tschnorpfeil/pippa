/**
 * `list_folder` (pippa-tools.ts): one folder as facts. Folders first, then files newest first; at most 20 entries with
 * name, full path, kind, size (files) or item count (folders), full modification time, and a Markdown file's front-matter
 * `updated`. The newest file is named and marked; what did not fit is counted, never silently dropped.
 */
import { readdir, stat } from "node:fs/promises";
import { join } from "node:path";
import { entryFacts, fitting } from "./facts.mjs";
import { FACT_RESULT_CHARS } from "./budget.ts";

/** Keep real filesystem denial separate from absence; the app chooses a privacy pane, never the model. */
/** `keep`: entries to show; Pippa's own and Pi's folders (also behind a symlink) are left out (protected.ts). */
export async function listFolder(folder: string, io = { readdir, stat }, maxChars = FACT_RESULT_CHARS, keep: (path: string) => boolean = () => true) {
	let names: string[];
	try {
		names = (await io.readdir(folder)).filter((name) => !name.startsWith("."));
	} catch (error) {
		const code = (error as NodeJS.ErrnoException)?.code;
		if (code === "EACCES" || code === "EPERM") {
			return { isError: true, content: [{ type: "text", text: "Access to this folder was denied. Tell the person access must be repaired before trying again; do not claim it is empty or missing and do not try other routes." }],
				details: { pippaFileAccess: { schema: 1, code, path: folder } } };
		}
		if (code === "ENOENT") throw new Error(`There is no folder at ${folder}.`);
		if (code === "ENOTDIR") throw new Error(`This path is not a folder: ${folder}.`);
		throw error;
	}
	const all: { path: string; info: any }[] = [];
	for (const name of names) {
		const path = join(folder, name);
		if (!keep(path)) continue;
		try { all.push({ path, info: await io.stat(path) }); } catch { /* vanished or unreadable: not listed */ }
	}
	all.sort((a, b) => Number(b.info.isDirectory()) - Number(a.info.isDirectory())
		|| b.info.mtimeMs - a.info.mtimeMs || a.path.localeCompare(b.path));
	const newest = all.filter((item) => !item.info.isDirectory()).reduce<typeof all[number] | undefined>(
		(best, item) => !best || item.info.mtimeMs > best.info.mtimeMs ? item : best, undefined);
	const entries: any[] = [];
	for (const item of all.slice(0, 20)) {
		const entry: any = await entryFacts(item.path, item.info);
		if (item === newest) entry.newest = true;
		entries.push(entry);
	}
	const folders = all.filter((item) => item.info.isDirectory()).length;
	const result = fitting((count: number) => ({
		folder,
		total: all.length,
		folders,
		files: all.length - folders,
		...(newest ? { newest_file: newest.path } : {}),
		sorted: "folders first, then newest first",
		entries: entries.slice(0, count),
		...(all.length > count ? { left_out: all.length - count } : {}),
	}), entries.length, maxChars);
	return { content: [{ type: "text", text: JSON.stringify(result) }], details: result };
}
