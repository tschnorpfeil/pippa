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
		["d.txt", "plan-abs/d.txt", "target must be a subfolder of folder; use rename_or_move for other places"],
		["d.txt", "~/Irgendwo/d.txt", "target must be a subfolder of folder; use rename_or_move for other places"],
		["d.txt", "daneben/d.txt", "target must be a subfolder of folder; use rename_or_move for other places"],
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
	assert.match(read[0].text, /\[Only the first 12288 of 20010 characters are shown; .* offset\/limit\.\]$/);
	const bash = capResult("bash", [{ type: "text", text: `Anfang${long}Ende` }], 12_288);
	assert.ok(bash[0].text.endsWith("Ende") && !bash[0].text.includes("Anfang"));
	assert.match(bash[0].text, /^\[Only the last 12288 of 20010 characters/);
	const image = { type: "image", data: "AAAA", mimeType: "image/png" };
	assert.deepEqual(capResult("read", [image, { type: "text", text: long }], 12_288).map((p) => p.type), ["image", "text"]);
	assert.equal(capResult("mcp__pippa__read_document", [{ type: "text", text: long }], 12_288), undefined);
	assert.equal(capResult("read", [{ type: "text", text: "kurz" }], 12_288), undefined);
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
