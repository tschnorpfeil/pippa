/**
 * Pippa's narrow file tools for the real Pi (bash stays available but is not the default
 * path). Loaded next to the guard:
 *
 *   pi --mode rpc --extension runtime/pippa-guard/pippa-guard.ts --extension runtime/pippa-guard/pippa-tools.ts
 *
 * - `list_folder`: look at a folder, read-only (no question).
 * - `rename_or_move`: rename or move one file or folder. Never overwrites.
 * - `move_files`: sort many files into (new) subfolders in one call, e.g. tidying a folder, grouped by target
 *   (`groups: [{into: "Bilder", files: [...]}]`). Never overwrites; one undo entry for the whole batch. One call instead of one model
 *   turn per file (r7: 16 turns, 211 s for 15 files).
 * - `move_to_trash`: to the trash, never permanently delete.
 *
 * Question, undo entry and receipt are the guard's job (pippa-guard.ts), not this file's: all changing tools take the
 * same path. Paths always go to programs as a single argument, never into script text.
 *
 * Two hooks keep what the model reads small (budget.ts): shorter parameter texts of Pi's built-in tools in every
 * provider request, and a cap on each tool result from the model's context window.
 *
 * Descriptions are deliberately short: tool descriptions were the largest block of the first request (~990 tokens).
 * `list_folder` also shortens the descriptions of Pi's built-in tools via Pi's `prepareLoadout`
 * (`BUILTIN_DESCRIPTIONS`); their parameter descriptions stay as Pi delivers them.
 */
import { execFile } from "node:child_process";
import { mkdir, readdir, rename, stat } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import { Type } from "@earendil-works/pi-ai";
import { capResult, resultLimit, shortenParameters } from "./budget.ts";
import { exists, folderLabel, moveTarget, planMoves, resolvePath } from "./files.ts";

type ExtensionAPI = any;

const LIST_LIMIT = 200;

/** Short versions for Pi's built-in tools (Pi 1.0.4: read 303, bash 270, edit 330, write 141 characters). */
export const BUILTIN_DESCRIPTIONS: Record<string, string> = {
	read: "Read a text file or image; long files with offset/limit.",
	write: "Create or overwrite a file.",
	edit: "Replace exact, unique text passages in a file.",
	bash: "Run a shell command in the working folder.",
};

/** The Mac's trash via /usr/bin/trash (macOS 15+, FileManager.trashItem; no Finder automation, no system prompt).
 * For tests: `PIPPA_TRASH_DIR` instead of the real trash. Returns the location inside the trash. */
export async function moveToTrash(path: string): Promise<string | undefined> {
	const fake = process.env.PIPPA_TRASH_DIR;
	if (fake) {
		const dir = join(fake, `${Date.now()}`);
		await mkdir(dir, { recursive: true });
		const target = join(dir, basename(path));
		await rename(path, target);
		return target;
	}
	// Absolute path (starts with "/"): can never be read as an option; /usr/bin/trash has no "--".
	const output = await new Promise<string>((done, fail) => {
		execFile("/usr/bin/trash", ["-v", path], { timeout: 30_000 }, (error, stdout, stderr) => {
			if (error) fail(new Error(String(stderr || error.message).trim().split("\n").pop() || "trash failed"));
			else done(`${stdout}\n${stderr}`);
		});
	});
	return output.match(/Moved ".*" to "(.*)"\s*$/m)?.[1];
}

function size(bytes: number): string {
	if (bytes < 1024) return `${bytes} B`;
	if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`;
	return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

export default function (pi: ExtensionAPI) {
	pi.on("before_provider_request", (event: any) => shortenParameters(event?.payload));
	// One result must not fill a 16k window (Pi's read and bash allow 50 KB, ~14k tokens).
	pi.on("tool_result", (event: any, ctx: any) => {
		const content = capResult(String(event?.toolName ?? ""), event?.content, resultLimit(ctx?.model?.contextWindow));
		return content ? { content } : undefined;
	});

	pi.registerTool({
		name: "list_folder",
		label: "Ordner ansehen",
		description: "List a folder's files and subfolders.",
		parameters: Type.Object({
			path: Type.Optional(Type.String({ description: "Exact path as given; default: working folder." })),
		}),
		annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: false },
		// Applies while list_folder is active (always): shorter descriptions of the built-in tools.
		prepareLoadout: (loadout: any) => ({
			descriptions: Object.fromEntries(
				Object.entries(BUILTIN_DESCRIPTIONS).filter(([name]) => loadout?.declared?.some((tool: any) => tool.name === name)),
			),
		}),
		async execute(_id: string, params: any, _signal: AbortSignal | undefined, _onUpdate: unknown, ctx: any) {
			const folder = resolvePath(params?.path || ".", ctx?.cwd ?? process.cwd());
			// A wrongly shortened path must not be retried ten times in a row (seen with a 12B model).
			if (!(await exists(folder))) throw new Error(`There is no folder at ${folder}. Use the exact path from the message (starting with / or ~), not a shortened one.`);
			const names = (await readdir(folder)).filter((name) => !name.startsWith(".")).sort((a, b) => a.localeCompare(b));
			const lines: string[] = [];
			for (const name of names.slice(0, LIST_LIMIT)) {
				try {
					const info = await stat(join(folder, name));
					lines.push(info.isDirectory() ? `${name}/` : `${name} (${size(info.size)}, ${info.mtime.toISOString().slice(0, 10)})`);
				} catch {
					lines.push(name);
				}
			}
			const more = names.length > LIST_LIMIT ? `\n… and ${names.length - LIST_LIMIT} more` : "";
			const text = names.length === 0 ? `${folder} is empty.` : `${folder}:\n${lines.join("\n")}${more}`;
			return { content: [{ type: "text", text }], details: { folder, count: names.length } };
		},
	});

	pi.registerTool({
		name: "rename_or_move",
		label: "Umbenennen oder verschieben",
		description: "Rename or move one file or folder. Never overwrites.",
		parameters: Type.Object({
			from: Type.String(),
			to: Type.String({ description: "New name or target folder." }),
		}),
		annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
		executionMode: "sequential",
		async execute(_id: string, params: any, _signal: AbortSignal | undefined, _onUpdate: unknown, ctx: any) {
			const cwd = ctx?.cwd ?? process.cwd();
			const from = resolvePath(params.from, cwd);
			const to = await moveTarget(from, params.to, cwd);
			if (!(await exists(from))) throw new Error(`Not found: ${from}`);
			if (await exists(to)) throw new Error(`Something named '${basename(to)}' already exists in ${dirname(to)}. Nothing was changed.`);
			if (!(await exists(dirname(to)))) throw new Error(`The folder ${dirname(to)} does not exist. Nothing was changed.`);
			await rename(from, to);
			return { content: [{ type: "text", text: `Moved to ${to}.` }], details: { from, to } };
		},
	});

	pi.registerTool({
		name: "move_files",
		label: "Dateien einsortieren",
		description: "Sort many files of a folder into its subfolders in one call; missing ones are created. Never overwrites.",
		parameters: Type.Object({
			folder: Type.String(),
			// Grouped by target: each subfolder name is written once (output tokens). Typed objects, not a map (files.ts planMoves).
			groups: Type.Array(Type.Object({ into: Type.String(), files: Type.Array(Type.String()) })),
		}),
		annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
		executionMode: "sequential",
		async execute(_id: string, params: any, _signal: AbortSignal | undefined, _onUpdate: unknown, ctx: any) {
			const plan = await planMoves(params?.folder, params?.groups, ctx?.cwd ?? process.cwd());
			if (!(await exists(plan.folder))) throw new Error(`There is no folder at ${plan.folder}. Nothing was changed.`);
			const moved: { from: string; to: string }[] = [];
			const failed: { name: string; error: string }[] = [];
			for (const item of plan.items) {
				if (item.error) { failed.push({ name: item.name, error: item.error }); continue; }
				try {
					// Checked again right before the move: never overwrite, even if something appeared since planning.
					if (await exists(item.to)) throw new Error(`'${basename(item.to)}' already exists there`);
					await mkdir(item.into, { recursive: true });
					await rename(item.from, item.to);
					moved.push({ from: item.from, to: item.to });
				} catch (error) {
					failed.push({ name: item.name, error: String((error as Error)?.message ?? error) });
				}
			}
			const counts = new Map<string, number>();
			for (const m of moved) {
				const label = folderLabel(dirname(m.to), plan.folder);
				counts.set(label, (counts.get(label) ?? 0) + 1);
			}
			const summary = [...counts].map(([label, n]) => `${n} → ${label}`).join(", ");
			const errors = failed.map((f) => `${f.name}: ${f.error}`).join("; ");
			const text = [moved.length ? `${moved.length} moved: ${summary}.` : "", failed.length ? `Not moved: ${errors}.` : ""].filter(Boolean).join(" ");
			// Nothing moved: an error, so the receipt says "not moved" (partial success stays a normal result).
			if (moved.length === 0) throw new Error(`${text || "No files given."} Nothing was changed.`);
			return { content: [{ type: "text", text }], details: { folder: plan.folder, moved, failed } };
		},
	});

	pi.registerTool({
		name: "move_to_trash",
		label: "In den Papierkorb",
		description: "Move a file or folder to the Trash. Use instead of bash rm.",
		parameters: Type.Object({
			path: Type.String(),
		}),
		annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false },
		executionMode: "sequential",
		async execute(_id: string, params: any, _signal: AbortSignal | undefined, _onUpdate: unknown, ctx: any) {
			const path = resolvePath(params.path, ctx?.cwd ?? process.cwd());
			if (!(await exists(path))) throw new Error(`Not found: ${path}`);
			const trashedTo = await moveToTrash(path);
			return { content: [{ type: "text", text: `Moved ${path} to the Trash.` }], details: { path, trashedTo } };
		},
	});
}
