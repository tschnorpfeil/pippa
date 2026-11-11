// Notes on a document that does not fit one tool result (digest.ts), through `read` (document.ts) with a stand-in for
// the model call.
//
//   node --experimental-strip-types --test runtime/pippa-tools/digest.test.mjs
import assert from "node:assert/strict";
import { mkdtemp, readdir, readFile, rm, utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { resultLimit } from "./budget.ts";
import { digestDirectory, shardChars, shards } from "./digest.ts";
import { readTool } from "./document.ts";

const builtin = { name: "read", description: "Pi's read", execute: async () => ({ content: [{ type: "text", text: "pi read" }] }) };
/** A thesis: 1931 lines, about 240,000 characters. */
const thesis = Array.from({ length: 1931 }, (_, i) => `Zeile ${i + 1} ` + "x".repeat(113)).join("\n");

/** A folder with Thesis.docx (its text comes from the stand-in for textutil) and a model that answers `reply(call)`. */
async function setup(reply = (call) => `Thema ${call.first}\n- Aussage (L${call.first}-${call.first + 3})`) {
	const dir = await mkdtemp(join(tmpdir(), "pippa-digest-"));
	const path = join(dir, "Thesis.docx");
	await writeFile(path, "docx bytes");
	const calls = [];
	const complete = async (system, user, maxTokens) => {
		const call = { system, user, maxTokens, merge: system.startsWith("These are notes"), first: Number(/^(\d+): /.exec(user)?.[1] ?? 0) };
		calls.push(call);
		return reply(call);
	};
	const tool = readTool(() => builtin, async () => thesis, { complete, digestDirectory: join(dir, "digests") }).definition("/");
	const read = (window, params = {}, onUpdate) => tool.execute("r", { path, ...params }, undefined, onUpdate, { cwd: dir, model: { contextWindow: window } });
	return { dir, path, calls, read, done: () => rm(dir, { recursive: true, force: true }) };
}

test("parts follow the context window, are cut after whole lines and carry line numbers", () => {
	assert.deepEqual([shardChars(16_384), shardChars(32_768), shardChars(undefined), shardChars(1_000_000)], [19_661, 39_322, 19_661, 60_000]);
	const parts = shards(thesis, shardChars(16_384));
	assert.ok(parts.every((part) => part.text.length <= 19_661));
	assert.equal(parts[0].first, 1);
	assert.equal(parts.at(-1).last, 1931);
	parts.slice(1).forEach((part, i) => assert.equal(part.first, parts[i].last + 1, "no line lost between parts"));
	assert.ok(parts[1].text.startsWith(`${parts[1].first}: Zeile ${parts[1].first} `));
	const long = shards("kurz\n" + "y".repeat(10_000) + "\nende", 4_000);
	assert.deepEqual(long.map((part) => [part.first, part.last]), [[1, 1], [2, 2], [2, 2], [2, 3]], "a line longer than a part is cut and keeps its number");
	assert.match(digestDirectory({}), /pippa-digests$/);
	assert.equal(digestDirectory({ PIPPA_DIGEST_DIR: "/x/digests" }), "/x/digests");
});

test("A1: a document over the limit comes back as notes on all parts; 16k makes more parts than 32k", async () => {
	const small = await setup(), large = await setup();
	try {
		const updates = [];
		const result = await small.read(16_384, {}, (update) => updates.push(update));
		const text = result.content[0].text;
		const parts = shards(thesis, shardChars(16_384));
		assert.equal(small.calls.length, parts.length);
		assert.deepEqual(small.calls.map((call) => call.first), parts.map((part) => part.first), "every part was sent, in order");
		for (const part of parts) assert.ok(text.includes(`## Lines ${part.first}-${part.last}\nThema ${part.first}`), `notes on lines ${part.first}-${part.last}`);
		assert.match(text, /^\[Notes on Thesis\.docx: lines 1-1931 \(\d{3},\d{3} characters\), taken from \d+ parts .* These are notes, not the full text\. .* call read with offset \(first line\) and limit/);
		assert.ok(!text.includes("Only the first") && !text.includes("[Shown: lines"));
		assert.ok(text.length <= resultLimit(16_384));
		assert.ok(small.calls.every((call) => call.maxTokens > 0 && call.maxTokens <= 800), "short answers");
		// A6: one update per part, before its call.
		assert.deepEqual(updates.map((update) => update.details.pippaProgress), parts.map((_, i) => ({ part: i + 1, of: parts.length, phase: "notes" })));
		assert.equal(updates[2].content[0].text, `Part 3 of ${parts.length}`);
		assert.equal(result.details.pippaDocument.via, "textutil");
		assert.equal(result.details.pippaDigest.parts, parts.length);

		await large.read(32_768);
		assert.equal(large.calls.length, shards(thesis, shardChars(32_768)).length);
		assert.ok(small.calls.length > large.calls.length, `${small.calls.length} parts at 16k, ${large.calls.length} at 32k`);
	} finally { await small.done(); await large.done(); }
});

test("A2: the same file again makes no model call; a changed modification time takes the notes again", async () => {
	const t = await setup();
	try {
		const first = await t.read(16_384);
		const made = t.calls.length;
		const saved = await readdir(join(t.dir, "digests"));
		assert.equal(saved.length, 1);
		assert.match(saved[0], /^Thesis\.docx\.[0-9a-f]{10}\.md$/);
		assert.equal(first.details.pippaDigest.notes, join(t.dir, "digests", saved[0]));
		assert.ok((await readFile(first.details.pippaDigest.notes, "utf8")).includes(first.content[0].text));
		const second = await t.read(16_384);
		assert.equal(t.calls.length, made, "no model call");
		assert.equal(second.content[0].text, first.content[0].text);
		assert.equal(second.details.pippaDigest.cached, true);
		await utimes(t.path, new Date(), new Date(Date.now() + 60_000));
		await t.read(16_384);
		assert.equal(t.calls.length, made * 2, "taken again");
		assert.equal((await readdir(join(t.dir, "digests"))).length, 1, "the old notes are replaced");
	} finally { await t.done(); }
});

test("A3: offset and limit return exactly those lines, without notes or a model call", async () => {
	const t = await setup();
	try {
		const some = await t.read(16_384, { offset: 300, limit: 2 });
		assert.equal(some.content[0].text, thesis.split("\n").slice(299, 301).join("\n"));
		const rest = await t.read(16_384, { offset: 1900 });
		assert.equal(rest.content[0].text, thesis.split("\n").slice(1899).join("\n"));
		const start = await t.read(16_384, { limit: 5 });
		assert.equal(start.content[0].text, thesis.split("\n").slice(0, 5).join("\n"));
		assert.equal(t.calls.length, 0);
		assert.equal(some.details.pippaDigest, undefined);
		await assert.rejects(readdir(join(t.dir, "digests")), "no notes file");
		// Lines that do not fit are cut by budget.ts with its note, as before.
		const { capResult } = await import("./budget.ts");
		const many = await t.read(16_384, { offset: 300, limit: 400 });
		assert.match(capResult("read", many.content, resultLimit(16_384), { offset: 300, limit: 400 })[0].text, /\[Shown: lines 300-\d+ of the requested lines 300-699;/);
	} finally { await t.done(); }
});

test("A4: a failed part is named with its lines; when every call fails the text comes back to be cut as before", async () => {
	let failing = (call) => call.first > 1 && call.first < 300;
	const t = await setup((call) => { if (failing(call)) throw new Error("model down"); return `Thema ${call.first}`; });
	try {
		const parts = shards(thesis, shardChars(16_384));
		const result = await t.read(16_384);
		const gap = parts[1];
		assert.ok(result.content[0].text.includes(`## Lines ${gap.first}-${gap.last}\n[Lines ${gap.first}-${gap.last} are not in these notes. Read them with read, offset ${gap.first}, limit ${gap.last - gap.first + 1}.]`));
		assert.ok(result.content[0].text.includes(`## Lines ${parts[2].first}-${parts[2].last}\nThema ${parts[2].first}`), "the parts after the gap are there");
		assert.deepEqual(result.details.pippaDigest.gaps, [{ first: gap.first, last: gap.last }]);

		failing = () => true;
		await utimes(t.path, new Date(), new Date(Date.now() + 120_000));
		const all = await t.read(16_384);
		assert.equal(all.content[0].text, thesis);
		assert.equal(all.details.pippaDigest, undefined);
		const { capResult } = await import("./budget.ts");
		assert.match(capResult("read", all.content, resultLimit(16_384), {})[0].text, /\[Shown: lines 1-\d+ of 1931; the rest did not fit the conversation\./);
	} finally { await t.done(); }
});

test("A5: notes longer than the limit are merged until they fit; a model that never shortens is cut, and the header says so", async () => {
	const long = (call) => `Thema ${call.first}\n` + "- lange Aussage ".repeat(150);
	const t = await setup((call) => call.merge ? `Kurzfassung ab ${/## Lines (\d+)/.exec(call.user)[1]}` : long(call));
	const stubborn = await setup((call) => call.merge ? call.user : long(call));
	try {
		const result = await t.read(16_384);
		const text = result.content[0].text;
		assert.ok(t.calls.some((call) => call.merge), "a merge round ran");
		assert.ok(t.calls.filter((call) => call.merge).every((call) => call.user.length <= shardChars(16_384)), "each merge call fits a part");
		assert.ok(text.length <= resultLimit(16_384), `${text.length} characters`);
		assert.match(text, /## Lines 1-\d+\nKurzfassung ab 1/);
		assert.ok(text.includes("-1931\n"), "the last lines are covered");
		assert.ok(!text.includes("shortened to fit"));

		const cut = (await stubborn.read(16_384)).content[0].text;
		assert.ok(cut.length <= resultLimit(16_384), `${cut.length} characters`);
		assert.match(cut, /The notes were shortened to fit\.\]/);
		assert.ok(cut.includes(" […]") && cut.includes("-1931\n"));
	} finally { await t.done(); await stubborn.done(); }
});
