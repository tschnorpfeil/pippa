/**
 * Pippa's narrow file tools for the real Pi (bash stays available but is not the default
 * path). Loaded by Pippa:
 *
 *   pi --mode rpc --extension runtime/pippa-tools/pippa-tools.ts --extension runtime/pippa-tools/pippa-assist.ts …
 *
 * - `search_files`: find the person's own documents by content, file name or folder name with Spotlight's index
 *   (search.mjs), anywhere in the home folder and iCloud Drive, read-only. One
 *   call instead of reading a skill and building a bash command (one model round less, and the step that failed).
 * - `list_folder`: look at a folder, read-only (no question).
 * - `move_files`: rename or move one file or folder (`from`, `to`), or sort many files into (new) subfolders in one
 *   call, grouped by target (`groups: [{into: "Bilder", files: [...]}]`). Never overwrites. One call instead of one
 *   model turn per file (r7: 16 turns, 211 s for 15 files); one tool instead of two (fewer declaration tokens).
 * - `move_to_trash`: to the trash, never permanently delete.
 * - `bash`: Pi's own shell tool, run inside a macOS sandbox (shell.ts): every program, but writing outside Pippa's
 *   working folder and the internet require the person's OK; generic app control stays blocked. Never deletes for good.
 *
 * Pi runs these tools without asking (as all its tools). They never overwrite and never delete for good; paths always
 * go to programs as a single argument, never into script text.
 *
 * Two hooks keep what the model reads small (budget.ts): shorter parameter texts of Pi's built-in tools in every
 * provider request, and a cap on each tool result from the model's context window.
 *
 * Descriptions are deliberately short: tool descriptions were the largest block of the first request (~990 tokens).
 * `list_folder` also shortens the descriptions of Pi's built-in tools via Pi's `prepareLoadout`
 * (`BUILTIN_DESCRIPTIONS`); their parameter descriptions stay as Pi delivers them.
 */
import { execFile } from "node:child_process";
import { mkdir, rename } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import { Type } from "@earendil-works/pi-ai";
import { createBashToolDefinition } from "@earendil-works/pi-coding-agent";
import { backupDirectory, backUp } from "./pippa-assist.ts";
import { capResult, resultLimit, shortenParameters } from "./budget.ts";
import { exists, folderLabel, moveOne, planMoves, resolvePath } from "./files.ts";
import { search } from "./search.mjs";
import { shellTool } from "./shell.ts";
import { listFolder } from "./list-folder.ts";

type ExtensionAPI = any;


/** Short versions for Pi's built-in tools (Pi 1.1.0: read 303, bash 270, edit 330, write 141 characters). */
export const BUILTIN_DESCRIPTIONS: Record<string, string> = {
	read: "Read a text file or image; long files with offset/limit.",
	write: "Save text to a file; create or overwrite.",
	edit: "Replace exact, unique text passages in a file.",
	bash: "Run a command when no dedicated tool fits; save text with write.",
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

export default function (pi: ExtensionAPI) {
	pi.on("before_provider_request", (event: any) => shortenParameters(event?.payload));
	const backups = backupDirectory();
	const shell = shellTool(createBashToolDefinition, { keep: backups ? (file) => backUp(file, backups) : undefined });
	pi.on("agent_start", () => shell.resetAnswer());
	pi.registerTool(shell.definition(process.cwd()));
	// One result must not fill a 16k window (Pi's read and bash allow 50 KB, ~14k tokens).
	pi.on("tool_result", (event: any, ctx: any) => {
		const content = capResult(String(event?.toolName ?? ""), event?.content, resultLimit(ctx?.model?.contextWindow));
		return content ? { content } : undefined;
	});

	pi.registerTool({
		name: "search_files",
		label: "Dateien suchen",
		description: "Find the person's own files by content, file name or folder name (Spotlight), anywhere in their home folder and iCloud Drive.",
		parameters: Type.Object({
			query: Type.String({ description: "1-3 topic words, e.g. Zahnarzt or Rechnung/invoice; omit generic words like Dokument and PDF." }),
			year: Type.Optional(Type.String({ description: "Only when the person names a year; never guess one." })),
			kind: Type.Optional(Type.String({ description: "Only when the person names a file type: pdf, image, word, excel, presentation, text, video, audio." })),
		}),
		annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: false },
		async execute(_id: string, params: any) {
			const result = await search(String(params?.query ?? ""), params?.year ? String(params.year) : undefined, undefined,
				{ kind: params?.kind ? String(params.kind) : undefined });
			// How to pass the result on, only when there is one (the skill text used to cost every search a read).
			const guide = "Best matches come first. Name each file as [name](file:///path), never as code. Found is not read: for content use mcp__pippa__read_document. "
				+ "No files: nothing indexed was found; never say the files do not exist. Do not repeat the same search.";
			return { content: [{ type: "text", text: JSON.stringify({ ...result, guide }) }], details: { query: result.query, total: result.total } };
		},
	});

	pi.registerTool({
		name: "list_folder",
		label: "Ordner ansehen",
		description: "List a folder for listing or sorting. To find documents by topic use search_files.",
		parameters: Type.Object({
			path: Type.Optional(Type.String({ description: "Exact path as given; default: working folder." })),
		}),
		annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: false },
		// Applies while list_folder is active: short descriptions through Pi's existing loadout hook.
		prepareLoadout: (loadout: any) => ({
			descriptions: Object.fromEntries(
				Object.entries(BUILTIN_DESCRIPTIONS).filter(([name]) => loadout?.declared?.some((tool: any) => tool.name === name)),
			),
		}),
		async execute(_id: string, params: any, _signal: AbortSignal | undefined, _onUpdate: unknown, ctx: any) {
			const folder = resolvePath(params?.path || ".", ctx?.cwd ?? process.cwd());
			return listFolder(folder);
		},
	});

	pi.registerTool({
		name: "move_files",
		label: "Dateien einsortieren",
		description: "Rename or move one item: from, to (new name or folder). Sort many: folder, groups (subfolders, created if missing). Never overwrites.",
		parameters: Type.Object({
			from: Type.Optional(Type.String()),
			to: Type.Optional(Type.String()),
			folder: Type.Optional(Type.String()),
			// Grouped by target: each subfolder name is written once (output tokens). Typed objects, not a map (files.ts planMoves).
			groups: Type.Optional(Type.Array(Type.Object({ into: Type.String(), files: Type.Array(Type.String()) }))),
		}),
		annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
		executionMode: "sequential",
		async execute(_id: string, params: any, _signal: AbortSignal | undefined, _onUpdate: unknown, ctx: any) {
			if (params?.from && params?.to && !params?.groups) return moveOne(params.from, params.to, ctx?.cwd ?? process.cwd());
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
		description: "Move a given path directly to Trash; checks existence. Use instead of bash rm.",
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
