import { readdir, stat } from "node:fs/promises";
import { join } from "node:path";

const LIST_LIMIT = 200;
function size(bytes: number): string {
	if (bytes < 1024) return `${bytes} B`;
	if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`;
	return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

/** Keep real filesystem denial separate from absence; the app chooses a privacy pane, never the model. */
export async function listFolder(folder: string, io = { readdir, stat }) {
	let names: string[];
	try {
		names = (await io.readdir(folder)).filter((name) => !name.startsWith(".")).sort((a, b) => a.localeCompare(b));
	} catch (error) {
		const code = (error as NodeJS.ErrnoException)?.code;
		if (code === "EACCES" || code === "EPERM") {
			return { isError: true, content: [{ type: "text", text: "Access to this folder was denied. Tell the person access must be repaired before trying again; do not claim it is empty or missing and do not try other routes." }],
				details: { pippaFileAccess: { schema: 1, code, path: folder } } };
		}
		if (code === "ENOENT") throw new Error(`There is no folder at ${folder}. Use the exact path from the message (starting with / or ~), not a shortened one.`);
		if (code === "ENOTDIR") throw new Error(`This path is not a folder: ${folder}.`);
		throw error;
	}
	const lines: string[] = [];
	for (const name of names.slice(0, LIST_LIMIT)) {
		try {
			const info = await io.stat(join(folder, name));
			lines.push(info.isDirectory() ? `${name}/` : `${name} (${size(info.size)}, ${info.mtime.toISOString().slice(0, 10)})`);
		} catch { lines.push(name); }
	}
	const more = names.length > LIST_LIMIT ? `\n… and ${names.length - LIST_LIMIT} more` : "";
	const text = names.length === 0 ? `${folder} is empty.` : `${folder}:\n${lines.join("\n")}${more}`;
	return { content: [{ type: "text", text }], details: { folder, count: names.length } };
}
