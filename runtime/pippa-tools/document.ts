/**
 * Pi's `read`, extended so a document comes back as text in the same call (registered in pippa-tools.ts under the
 * name `read`, which replaces Pi's built-in tool; everything else goes to Pi's own `read` unchanged).
 *
 * - PDF: the text layer through PDFKit (`osascript -l JavaScript`, macOS's own framework; no app, no network), with a
 *   `[Page n]` line before each page.
 * - Word, RTF, OpenDocument text, HTML archives: `textutil -convert txt` (macOS).
 * - Everything macOS cannot turn into text without the app (Excel, Numbers, Pages, Keynote, PowerPoint, Outlook mail,
 *   PDFs without a text layer, and images when the model cannot see images): Pippa's MCP reader
 *   `mcp__pippa__read_document` (text recognition included), run as a nested call when the app serves it. Without the
 *   app the call fails with what could not be read.
 *
 * `offset`/`limit` count lines of the text, as for any other file. A PDF or Word text read whole (no `offset`, no
 * `limit`) that is longer than one result may be comes back as notes on the whole document (digest.ts), with one
 * progress update per part; the lines themselves stay readable with `offset`/`limit`.
 */
import { execFile } from "node:child_process";
import { readFile } from "node:fs/promises";
import { extname } from "node:path";
import { resultLimit } from "./budget.ts";
import { digest, piComplete, type Complete } from "./digest.ts";
import { resolvePath } from "./files.ts";

const PDF = new Set(["pdf"]);
const TEXTUTIL = new Set(["doc", "docx", "rtf", "rtfd", "odt", "wordml", "webarchive"]);
const NEEDS_APP = new Set(["xlsx", "xlsm", "xls", "numbers", "pages", "key", "pptx", "ppt", "odp", "ods", "msg"]);
const IMAGES = new Set(["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "webp", "bmp"]);
export const DOCUMENT_READER = "mcp__pippa__read_document";

/** Decodes a `.csv` file as Windows-1252 when its bytes are not valid UTF-8; `undefined` when UTF-8 or unreadable. */
async function windows1252Csv(path: string): Promise<string | undefined> {
	let bytes: Buffer;
	try { bytes = await readFile(path); } catch { return undefined; }
	try {
		new TextDecoder("utf-8", { fatal: true }).decode(bytes);
		return undefined;
	} catch {
		return new TextDecoder("windows-1252").decode(bytes).replace(/\r\n/g, "\n");
	}
}

/** How `read` handles a path: "pdf" | "textutil" | "app" | "image" | undefined (Pi's own read). */
export function documentKind(path: string): "pdf" | "textutil" | "app" | "image" | undefined {
	const ext = extname(path).toLowerCase().slice(1);
	if (PDF.has(ext)) return "pdf";
	if (TEXTUTIL.has(ext)) return "textutil";
	if (NEEDS_APP.has(ext)) return "app";
	if (IMAGES.has(ext)) return "image";
	return undefined;
}

type Run = (file: string, args: string[]) => Promise<string>;

const run: Run = (file, args) => new Promise((done, fail) => {
	execFile(file, args, { timeout: 60_000, maxBuffer: 64 * 1024 * 1024 }, (error, stdout, stderr) => {
		if (error) fail(new Error(String(stderr || error.message).trim().split("\n").pop() || `${file} failed`));
		else done(String(stdout));
	});
});

/** PDFKit through JavaScript for Automation; the path is an argument, never script text. */
const PDF_SCRIPT = `ObjC.import("PDFKit");
function run(argv) {
	const doc = $.PDFDocument.alloc.initWithURL($.NSURL.fileURLWithPath(argv[0]));
	if (!doc || doc.isNil()) throw new Error("not a readable PDF");
	if (doc.isLocked) throw new Error("the PDF is protected by a password");
	const pages = [];
	for (let i = 0; i < doc.pageCount; i++) {
		const text = ObjC.unwrap(doc.pageAtIndex(i).string) || "";
		pages.push("[Page " + (i + 1) + "]\\n" + text.trim());
	}
	return pages.join("\\n\\n");
}`;

/** The text of a PDF or a textutil document; "" when it has none (a scan). */
export async function localText(path: string, kind: "pdf" | "textutil", exec: Run = run): Promise<string> {
	if (kind === "pdf") return exec("/usr/bin/osascript", ["-l", "JavaScript", "-e", PDF_SCRIPT, path]);
	// An absolute path (starts with "/") can never be read as an option.
	return exec("/usr/bin/textutil", ["-convert", "txt", "-stdout", path]);
}

/** `offset` (1-based) and `limit` lines of `text`, like Pi's read. */
export function lines(text: string, offset?: number, limit?: number): string {
	if (!offset && !limit) return text;
	const all = text.split("\n");
	const start = Math.max(0, (Number(offset) || 1) - 1);
	if (start >= all.length) throw new Error(`Offset ${offset} is beyond the end of the text (${all.length} lines).`);
	return all.slice(start, limit ? start + Number(limit) : undefined).join("\n");
}

/** Has the text a layer worth reading? Page markers alone are no text. */
function hasText(text: string): boolean {
	return text.replace(/\[Page \d+\]/g, "").trim().length > 0;
}

/** Pi's read (`create` = `createReadToolDefinition`) with documents read to text in the same call.
 * `options` (tests): the model call and the folder digest.ts uses; by default Pi's model registry and PIPPA_DIGEST_DIR. */
export function readTool(create: (cwd: string, options?: any) => any, exec: Run = run, options: { complete?: Complete; digestDirectory?: string } = {}) {
	return {
		definition(defaultCwd: string) {
			const base = create(defaultCwd);
			return {
				...base,
				description: "Read a file: text, image, or a document (PDF, Word, Excel, RTF, Pages …) as text; long files in parts by line (offset/limit).",
				async execute(id: string, params: any, signal: AbortSignal | undefined, onUpdate: any, ctx: any) {
					const path = resolvePath(params?.path ?? params?.file_path, ctx?.cwd || defaultCwd);
					if (extname(path).toLowerCase() === ".csv") {
						const decoded = await windows1252Csv(path);
						if (decoded !== undefined) {
							return { content: [{ type: "text", text: lines(decoded, params?.offset, params?.limit) }],
								details: { pippaDocument: { path, via: "windows-1252" } } };
						}
					}
					const kind = documentKind(path);
					const sees = Array.isArray(ctx?.model?.input) ? ctx.model.input.includes("image") : false;
					if (!kind || (kind === "image" && sees)) return base.execute(id, params, signal, onUpdate, ctx);
					const name = path.split("/").pop();
					if (kind === "pdf" || kind === "textutil") {
						const text = await localText(path, kind, exec);
						if (hasText(text)) {
							const details = { pippaDocument: { path, via: kind === "pdf" ? "pdfkit" : "textutil" } };
							const complete = options.complete ?? piComplete(ctx);
							const limit = resultLimit(ctx?.model?.contextWindow);
							// Read whole and too long for one result: notes on all of it instead of its first lines.
							if (!params?.offset && !params?.limit && text.length > limit && complete) {
								const notes = await digest({ path, text, contextWindow: ctx?.model?.contextWindow, limit, complete,
									directory: options.digestDirectory, signal: signal ?? ctx?.signal,
									onProgress: (progress) => {
										if (typeof onUpdate !== "function") return;
										const what = progress.phase === "merge" ? "Merging notes" : "Part";
										onUpdate({ content: [{ type: "text", text: `${what} ${progress.part} of ${progress.of}` }], details: { pippaProgress: progress } });
									} });
								if (notes) {
									return { content: [{ type: "text", text: notes.text }],
										details: { ...details, pippaDigest: { notes: notes.file, lines: notes.lines, parts: notes.parts, gaps: notes.gaps, cached: notes.cached } } };
								}
							}
							return { content: [{ type: "text", text: lines(text, params?.offset, params?.limit) }], details };
						}
					}
					const reader = ctx?.tools?.some?.((tool: any) => tool?.name === DOCUMENT_READER);
					if (!reader || typeof ctx?.executeTool !== "function") {
						if (kind === "image") return base.execute(id, params, signal, onUpdate, ctx);
						throw new Error(kind === "app"
							? `${name}: this file type can only be read to text inside the Pippa app.`
							: `${name} has no text layer (a scan); text recognition needs the Pippa app.`);
					}
					const outcome = await ctx.executeTool(DOCUMENT_READER, { path }, { signal });
					const content = outcome?.result?.content ?? [];
					if (outcome?.isError) {
						throw new Error(content.filter((part: any) => part?.type === "text").map((part: any) => part.text).join("\n") || `${name} could not be read.`);
					}
					const sliced = (params?.offset || params?.limit)
						? content.map((part: any) => part?.type === "text" ? { ...part, text: lines(String(part.text ?? ""), params?.offset, params?.limit) } : part)
						: content;
					return { content: sliced, details: { pippaDocument: { path, via: DOCUMENT_READER } } };
				},
			};
		},
	};
}
