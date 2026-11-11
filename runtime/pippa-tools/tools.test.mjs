// Pippa's file tools (pippa-tools.ts) and what they keep small (budget.ts), without Pi and without a model.
//
//   node --experimental-strip-types --test runtime/pippa-tools/tools.test.mjs
import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const here = fileURLToPath(new URL(".", import.meta.url));
await mkdir(join(here, "../../.build"), { recursive: true });
const root = await mkdtemp(join(here, "../../.build/pippa-tools-test-"));
const { planMoves, folderLabel } = await import("./files.ts");
const { capResult, resultLimit, shortenParameters } = await import("./budget.ts");

test("move_files plan: grouped by subfolder, new folders, per-item errors, never overwrites, targets stay inside", async () => {
	const dir = join(root, "plan");
	await mkdir(join(dir, "PDFs"), { recursive: true });
	for (const f of ["a.pdf", "b.jpg", "c.txt", "d.txt"]) await writeFile(join(dir, f), f);
	await writeFile(join(dir, "PDFs", "c.txt"), "schon da");
	const plan = await planMoves(dir, [
		{ into: "PDFs", files: ["a.pdf", "c.txt"] }, { into: "Bilder/2026", files: ["b.jpg"] }, { into: "Texte", files: ["fehlt.doc"] },
		{ into: "PDFs/innen", files: ["PDFs"] }, { into: join(root, "plan-abs"), files: ["d.txt"] }, { into: "~/Irgendwo", files: ["d.txt"] },
		{ into: "../daneben", files: ["d.txt"] }, { into: join(dir, "Einzeln"), files: "d.txt" },
	], root);
	assert.deepEqual(plan.items.map((i) => [i.name, i.to.replace(`${root}/`, "").replace(`${homedir()}/`, "~/"), i.error]), [
		["a.pdf", "plan/PDFs/a.pdf", undefined],
		["c.txt", "plan/PDFs/c.txt", "'c.txt' already exists there"],
		["b.jpg", "plan/Bilder/2026/b.jpg", undefined],
		["fehlt.doc", "plan/Texte/fehlt.doc", "not found"],
		["PDFs", "plan/PDFs/innen/PDFs", "cannot move a folder into itself"],
		["d.txt", "plan-abs/d.txt", "target must be a subfolder of folder; for other places use from and to"],
		["d.txt", "~/Irgendwo/d.txt", "target must be a subfolder of folder; for other places use from and to"],
		["d.txt", "daneben/d.txt", "target must be a subfolder of folder; for other places use from and to"],
		["d.txt", "plan/Einzeln/d.txt", undefined],
	]);
	assert.deepEqual(plan.folders, [join(dir, "Bilder"), join(dir, "Einzeln")]);
	assert.deepEqual(plan.created, [join(dir, "Bilder"), join(dir, "Bilder/2026"), join(dir, "Einzeln")]);
	assert.equal(folderLabel(join(dir, "Bilder/2026"), dir), "Bilder/2026/");
	const twice = await planMoves(dir, [{ into: "X", files: ["a.pdf", "PDFs/../a.pdf"] }], root);
	assert.deepEqual(twice.items.map((i) => i.error), [undefined, "'a.pdf' already exists there"], "two items, same target");
	const map = await planMoves(dir, { X: ["a.pdf"] }, root);
	assert.deepEqual(map.items.map((i) => [i.to.replace(`${root}/`, ""), i.error]), [["plan/X/a.pdf", undefined]], "a map is accepted too");
	assert.deepEqual((await planMoves(dir, [{ name: "a.pdf", into: "X" }], root)).items, [], "the old item shape plans nothing");
});

test("result cap follows the context window; bash keeps the end, MCP results stay whole, short ones untouched", () => {
	assert.deepEqual([resultLimit(16_384), resultLimit(32_768), resultLimit(8_192), resultLimit(undefined)], [12_288, 24_000, 6_144, 12_288]);
	const long = "x".repeat(20_000);
	const read = capResult("read", [{ type: "text", text: `Anfang${long}Ende` }], 12_288);
	assert.equal(read.length, 1);
	assert.ok(read[0].text.startsWith("Anfang") && !read[0].text.includes("Ende"));
	assert.match(read[0].text, /\[Shown: lines 1-1 of 1; .* Line 1 is too long and was cut\. .* offset 2 \(offset counts lines, not characters\)\.\]$/);
	const other = capResult("grep", [{ type: "text", text: long }], 12_288);
	assert.match(other[0].text, /\[Only the first 12288 of 20000 characters are shown; the rest did not fit the conversation\.\]$/);
	const bash = capResult("bash", [{ type: "text", text: `Anfang${long}Ende` }], 12_288);
	assert.ok(bash[0].text.endsWith("Ende") && !bash[0].text.includes("Anfang"));
	assert.match(bash[0].text, /^\[Only the last 12288 of 20010 characters/);
	const image = { type: "image", data: "AAAA", mimeType: "image/png" };
	assert.deepEqual(capResult("read", [image, { type: "text", text: long }], 12_288).map((p) => p.type), ["image", "text"]);
	assert.equal(capResult("mcp__pippa__read_document", [{ type: "text", text: long }], 12_288), undefined);
	assert.equal(capResult("read", [{ type: "text", text: "kurz" }], 12_288), undefined);
});

test("a cut read ends after a whole line and names the line offset to read on with, never a character count", () => {
	const doc = Array.from({ length: 1931 }, (_, i) => `Zeile ${i + 1} ` + "x".repeat(100)).join("\n");
	const first = capResult("read", [{ type: "text", text: doc }], 24_000, { path: "/a/Thesis.docx" });
	const shown = first[0].text.split("\n[Shown:")[0].split("\n");
	assert.equal(shown.at(-1), `Zeile ${shown.length} ` + "x".repeat(100), "the last line is whole");
	assert.match(first[0].text, new RegExp(`\\[Shown: lines 1-${shown.length} of 1931; .*offset ${shown.length + 1} \\(offset counts lines`));
	// Read on from that offset: Pi's read hands lines offset… onwards, and the note counts from there.
	const rest = doc.split("\n").slice(shown.length).join("\n");
	const second = capResult("read", [{ type: "text", text: rest }], 24_000, { path: "/a/Thesis.docx", offset: shown.length + 1 });
	assert.match(second[0].text, new RegExp(`\\[Shown: lines ${shown.length + 1}-\\d+ of 1931;`));
	const asked = capResult("read", [{ type: "text", text: rest.split("\n").slice(0, 400).join("\n") }], 24_000, { offset: 300, limit: 400 });
	assert.match(asked[0].text, /of the requested lines 300-699;/);
});

test("parameter texts of Pi's built-in tools get shorter in the request; schema, other tools and odd payloads stay", () => {
	const editSchema = { type: "object", required: ["path", "edits"], properties: {
		path: { type: "string", description: "Path to the file to edit (relative or absolute)" },
		edits: { type: "array", description: "One or more targeted replacements. Long text.", items: { type: "object", required: ["oldText", "newText"], properties: {
			oldText: { type: "string", description: "Exact text for one targeted replacement. Long text." }, newText: { type: "string", description: "Replacement text." } } } } } };
	const other = { type: "function", function: { name: "mcp__pippa__read_document", parameters: { type: "object", properties: { path: { type: "string", description: "keep" } } } } };
	const payload = { model: "m", tools: [{ type: "function", function: { name: "edit", description: "d", parameters: editSchema } }, other] };
	const out = shortenParameters(payload);
	const edit = out.tools[0].function.parameters;
	assert.equal(edit.properties.path.description, undefined, "a text the name already says is dropped");
	assert.equal(edit.properties.path.type, "string");
	assert.equal(edit.properties.edits.items.properties.oldText.description, "Exact text, unique in the file.");
	assert.deepEqual(edit.required, ["path", "edits"]);
	assert.deepEqual(edit.properties.edits.items.required, ["oldText", "newText"]);
	assert.equal(out.tools[1], other, "other tools unchanged");
	assert.equal(payload.tools[0].function.parameters.properties.path.description, "Path to the file to edit (relative or absolute)", "input not mutated");
	assert.equal(out.tools[0].function.description, "d");
	const anthropic = shortenParameters({ tools: [{ name: "read", input_schema: { type: "object", properties: { path: { type: "string", description: "Long" } } } }] });
	assert.equal(anthropic.tools[0].input_schema.properties.path.description, undefined);
	assert.equal(shortenParameters({ messages: [] }), undefined);
	assert.equal(shortenParameters(out), undefined, "already short: nothing to change");
});

test("move_files with from/to: rename or move one item, including case-only renames, never overwriting files or broken symlinks", async () => {
	const { moveOne, exists } = await import("./files.ts");
	const { existsSync, linkSync, mkdirSync, readdirSync, symlinkSync, writeFileSync } = await import("node:fs");
	const dir = await mkdtemp(join(root, "move-"));
	writeFileSync(join(dir, "brief.pdf"), "x");
	writeFileSync(join(dir, "da.pdf"), "y");
	mkdirSync(join(dir, "Ablage"));
	await moveOne("brief.pdf", "Mietvertrag.pdf", dir);
	assert.ok(existsSync(join(dir, "Mietvertrag.pdf")));
	// Case-only rename on case-insensitive APFS (or case-sensitive FS)
	writeFileSync(join(dir, "rechnung.pdf"), "r");
	await moveOne("rechnung.pdf", "Rechnung.pdf", dir);
	assert.ok(readdirSync(dir).includes("Rechnung.pdf"));
	linkSync(join(dir, "Rechnung.pdf"), join(dir, "hard-link.pdf"));
	await assert.rejects(moveOne("Rechnung.pdf", "hard-link.pdf", dir), /already exists/);
	assert.ok(existsSync(join(dir, "Rechnung.pdf")));
	// Broken symlink at destination is detected and never silently overwritten
	symlinkSync(join(dir, "nowhere-target"), join(dir, "broken-link.pdf"));
	assert.equal(await exists(join(dir, "broken-link.pdf")), true);
	await assert.rejects(moveOne("Rechnung.pdf", "broken-link.pdf", dir), /already exists/);
	await moveOne(join(dir, "Mietvertrag.pdf"), join(dir, "Ablage"), dir);
	assert.ok(existsSync(join(dir, "Ablage", "Mietvertrag.pdf")));
	writeFileSync(join(dir, "Mietvertrag.pdf"), "z");
	await assert.rejects(moveOne("Mietvertrag.pdf", "Ablage", dir), /already exists/);
	await assert.rejects(moveOne("fehlt.pdf", "neu.pdf", dir), /Not found/);
});

test("move_files to \"trash\": into the Trash (never deleted), with the place for undo; only that exact word", async () => {
	const { isTrash, trashOne } = await import("./files.ts");
	const { existsSync, mkdirSync, writeFileSync } = await import("node:fs");
	const dir = await mkdtemp(join(root, "trash-"));
	writeFileSync(join(dir, "alt.pdf"), "x");
	mkdirSync(join(dir, "sub"));
	writeFileSync(join(dir, "sub", "alt.pdf"), "y");
	process.env.PIPPA_TRASH_DIR = join(dir, ".Trash");
	try {
		const [result, second] = await Promise.all([trashOne("alt.pdf", dir), trashOne("sub/alt.pdf", dir)]);
		assert.equal(existsSync(join(dir, "alt.pdf")), false);
		assert.equal(result.details.from, join(dir, "alt.pdf"));
		assert.equal(result.details.trash, true);
		assert.ok(existsSync(result.details.to), "the file is in the Trash, not gone");
		assert.ok(existsSync(second.details.to) && second.details.to !== result.details.to, "two files trashed in the same millisecond never collide");
		await assert.rejects(trashOne("alt.pdf", dir), /Not found/);
	} finally { delete process.env.PIPPA_TRASH_DIR; }
	assert.ok(isTrash("trash") && isTrash(" Trash "));
	assert.ok(!isTrash("trash.txt") && !isTrash("~/trash") && !isTrash(undefined));
});
