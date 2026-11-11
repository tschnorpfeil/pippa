/**
 * Pippa's file tools for Pi. Loaded by Pippa:
 *
 *   pi --mode rpc --extension runtime/pippa-tools/pippa-tools.ts --extension runtime/pippa-tools/pippa-assist.ts …
 *
 * - `search_files`: the person's own files by content, file name or folder name with Spotlight's index (search.mjs),
 *   anywhere in the home folder and iCloud Drive, read-only.
 * - `list_folder`: one folder, read-only (list-folder.ts).
 *   Both return facts (facts.mjs): at most 20 entries with name, full path, kind, size, full modification time and a
 *   Markdown file's front-matter `updated`; sorted, the newest file marked, the rest counted; JSON that always fits
 *   the result cap (budget.ts).
 * - `move_files`: rename or move one item (`from`, `to`; `to: "trash"` moves it to the macOS Trash), or sort many
 *   files into (new) subfolders in one call (`folder`, `groups: [{into, files}]`). Never overwrites, never deletes for
 *   good; every move can be undone (pippa-assist.ts `changesOf`).
 * - `read`: Pi's own read, with documents (PDF, Word, …) returned as text in the same call (document.ts).
 * - `bash`: Pi's own shell tool, run inside a macOS sandbox (shell.ts): writing outside Pippa's working folder and the
 *   internet need the person's OK; app control stays blocked. Pi's direct RPC shell is refused (it would bypass it).
 *
 * Two hooks keep what the model reads small (budget.ts): shorter parameter texts of Pi's built-in tools in every
 * provider request, and a cap on each tool result from the model's context window.
 */
import { mkdir, rename } from "node:fs/promises";
import { basename, dirname } from "node:path";
import { Type } from "@earendil-works/pi-ai";
import { createBashToolDefinition, createReadToolDefinition } from "@earendil-works/pi-coding-agent";
import { backupDirectory, backUp } from "./pippa-assist.ts";
import { capResult, FACT_RESULT_CHARS, resultLimit, shortenParameters } from "./budget.ts";
import { exists, folderLabel, isTrash, moveOne, planMoves, resolvePath, trashOne } from "./files.ts";
import { search } from "./search.mjs";
import { shellTool } from "./shell.ts";
import { listFolder } from "./list-folder.ts";
import { readTool } from "./document.ts";

type ExtensionAPI = any;


/** Short versions for Pi's built-in tools (Pi 1.1.0: read 303, bash 270, edit 330, write 141 characters). */
export const BUILTIN_DESCRIPTIONS: Record<string, string> = {
	read: "Read a file: text, image, or a document (PDF, Word, Excel, RTF, Pages …) as text; long files in parts by line (offset/limit).",
	write: "Save text to a file; create or overwrite.",
	edit: "Replace exact, unique text passages in a file.",
	bash: "Run a command when no dedicated tool fits; save text with write.",
};

export default function (pi: ExtensionAPI) {
	pi.on("before_provider_request", (event: any) => shortenParameters(event?.payload));
	const backups = backupDirectory();
	const shell = shellTool(createBashToolDefinition, { keep: backups ? (file) => backUp(file, backups) : undefined });
	pi.on("agent_start", () => shell.resetAnswer());
	pi.registerTool(shell.definition(process.cwd()));
	pi.registerTool(readTool(createReadToolDefinition).definition(process.cwd()));
	// Pi's direct RPC shell (`!command`) bypasses the tool wrapper and its sandbox; Pippa never offers it.
	pi.on("user_bash", () => ({ result: { output: "Direct shell execution is disabled in Pippa.", exitCode: 1, cancelled: false, truncated: false } }));
	// One result must not fill a 16k window (Pi's read and bash allow 50 KB, ~14k tokens).
	pi.on("tool_result", (event: any, ctx: any) => {
		const content = capResult(String(event?.toolName ?? ""), event?.content, resultLimit(ctx?.model?.contextWindow), event?.input);
		return content ? { content } : undefined;
	});

	pi.registerTool({
		name: "search_files",
		label: "Dateien suchen",
		description: "Find the person's own files by content, file name or folder name (Spotlight), anywhere in their home folder and iCloud Drive. Newest first.",
		parameters: Type.Object({
			query: Type.String({ description: "1-3 topic words, e.g. Zahnarzt or Rechnung/invoice; omit generic words like Dokument and PDF." }),
			year: Type.Optional(Type.String({ description: "Only when the person names a year; never guess one." })),
			kind: Type.Optional(Type.String({ description: "Only when the person names a file type: pdf, image, word, excel, presentation, text, video, audio." })),
			sort: Type.Optional(Type.Union([Type.Literal("newest"), Type.Literal("name")])),
		}),
		annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: false },
		async execute(_id: string, params: any) {
			const result = await search(String(params?.query ?? ""), params?.year ? String(params.year) : undefined, undefined,
				{ kind: params?.kind ? String(params.kind) : undefined, sort: params?.sort === "name" ? "name" : "newest", maxChars: FACT_RESULT_CHARS });
			return { content: [{ type: "text", text: JSON.stringify(result) }], details: result };
		},
	});

	pi.registerTool({
		name: "list_folder",
		label: "Ordner ansehen",
		description: "List a folder: subfolders first, then files newest first. To find documents by topic use search_files.",
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
		description: "Rename or move one item: from, to (new name, folder, or \"trash\" for the Trash). Sort many: folder, groups (subfolders, created if missing). Never overwrites.",
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
			const cwd = ctx?.cwd ?? process.cwd();
			if (params?.from && isTrash(params?.to) && !params?.groups) return trashOne(params.from, cwd);
			if (params?.from && params?.to && !params?.groups) return moveOne(params.from, params.to, cwd);
			const plan = await planMoves(params?.folder, params?.groups, cwd);
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
}
