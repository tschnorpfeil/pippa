import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile, rm, utimes } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { listFolder } from "./list-folder.ts";
import { frontMatterDate, isoLocal } from "./facts.mjs";
import { FACT_RESULT_CHARS, SMALLEST_RESULT_LIMIT } from "./budget.ts";

test("folder denial stays typed and never becomes a missing or empty folder", async () => {
	for (const code of ["EACCES", "EPERM"]) {
		let metadataCalls = 0;
		const result = await listFolder("/Users/fixture/Documents/Private", {
			readdir: async () => { throw Object.assign(new Error("private error text"), { code }); },
			stat: async () => { metadataCalls++; },
		});
		assert.equal(result.isError, true);
		assert.deepEqual(result.details, { pippaFileAccess: { schema: 1, code, path: "/Users/fixture/Documents/Private" } });
		assert.doesNotMatch(result.content[0].text, /private error text/);
		assert.equal(metadataCalls, 0);
	}
});

test("missing, not-a-folder and unrelated errors do not invent privacy evidence", async () => {
	for (const code of ["ENOENT", "ENOTDIR", "EIO", undefined]) {
		const error = Object.assign(new Error("EACCES in an error message is not evidence"), { code });
		await assert.rejects(listFolder("/fixture", { readdir: async () => { throw error; }, stat: async () => {} }),
			code === "ENOENT" ? /There is no folder/ : code === "ENOTDIR" ? /not a folder/ : /not evidence/);
	}
});

test("an actual folder: valid JSON facts, folders first, then newest first, the newest file marked", async () => {
	const root = await mkdtemp(join(tmpdir(), "pippa-folder-access-"));
	try {
		const empty = await listFolder(root);
		assert.deepEqual(JSON.parse(empty.content[0].text), { folder: root, total: 0, folders: 0, files: 0, sorted: "folders first, then newest first", entries: [] });
		await mkdir(join(root, "z-folder"));
		await writeFile(join(root, "z-folder", "inside.txt"), "x");
		await writeFile(join(root, "a.txt"), "hello");
		await writeFile(join(root, "b.txt"), "newer");
		await writeFile(join(root, ".hidden"), "hidden");
		await utimes(join(root, "a.txt"), new Date(2026, 0, 2, 9, 30), new Date(2026, 0, 2, 9, 30));
		await utimes(join(root, "b.txt"), new Date(2026, 5, 1, 18, 5, 7), new Date(2026, 5, 1, 18, 5, 7));
		const result = await listFolder(root);
		assert.equal(result.isError, undefined);
		const facts = JSON.parse(result.content[0].text);
		assert.deepEqual(result.details, facts);
		assert.deepEqual(facts.entries.map((e) => [e.name, e.kind]), [["z-folder", "folder"], ["b.txt", "file"], ["a.txt", "file"]]);
		assert.equal(facts.entries[0].items, 1);
		assert.deepEqual(facts.entries[1], { name: "b.txt", path: join(root, "b.txt"), kind: "file", size: 5, modified: isoLocal(new Date(2026, 5, 1, 18, 5, 7)), newest: true });
		assert.match(facts.entries[1].modified, /^2026-06-01T18:05:07[+-]\d\d:\d\d$/);
		assert.equal(facts.newest_file, join(root, "b.txt"));
		assert.equal(facts.entries[2].newest, undefined);
		assert.equal(facts.left_out, undefined);
		await assert.rejects(listFolder(join(root, "missing")), /There is no folder/);
		await assert.rejects(listFolder(join(root, "a.txt")), /not a folder/);
	} finally { await rm(root, { recursive: true, force: true }); }
});

test("the ETF case: a dated file name is no date; front matter `updated` and the real time are given", async () => {
	const root = await mkdtemp(join(tmpdir(), "pippa-etf-"));
	try {
		await writeFile(join(root, "ETF-Portfolio.md"), "---\ntitle: ETF Portfolio\nupdated: 2026-10-01\n---\n# Portfolio\n");
		await writeFile(join(root, "20260820_ETF_PORTFOLIO_UPDATE.md"), "# Update\n");
		await utimes(join(root, "20260820_ETF_PORTFOLIO_UPDATE.md"), new Date(2026, 7, 20, 10, 0), new Date(2026, 7, 20, 10, 0));
		await utimes(join(root, "ETF-Portfolio.md"), new Date(2026, 9, 1, 8, 15), new Date(2026, 9, 1, 8, 15));
		const facts = JSON.parse((await listFolder(root)).content[0].text);
		assert.deepEqual(facts.entries.map((e) => [e.name, e.updated, e.newest]), [
			["ETF-Portfolio.md", "2026-10-01", true], ["20260820_ETF_PORTFOLIO_UPDATE.md", undefined, undefined]]);
		assert.equal(facts.newest_file, join(root, "ETF-Portfolio.md"));
	} finally { await rm(root, { recursive: true, force: true }); }
});

test("front matter: updated before date, quotes dropped, BOM stripped, only at the very top and within the first lines", () => {
	assert.equal(frontMatterDate("---\ndate: 2026-01-01\nupdated: '2026-10-01'\n---\n"), "2026-10-01");
	assert.equal(frontMatterDate("\uFEFF---\nupdated: 2026-10-01\n---\n"), "2026-10-01");
	assert.equal(frontMatterDate("---\nDate: \"2026-03-04 10:00\"\n---\nupdated: 2027-01-01"), "2026-03-04 10:00");
	assert.equal(frontMatterDate("# Title\n---\nupdated: 2026-10-01\n---"), undefined);
	assert.equal(frontMatterDate("---\n" + "x: 1\n".repeat(20) + "updated: 2026-10-01\n---"), undefined);
	assert.equal(frontMatterDate(""), undefined);
});

test("many entries with long paths: at most 20, the rest counted, JSON whole and under the smallest result cap", async () => {
	const root = await mkdtemp(join(tmpdir(), "pippa-many-"));
	try {
		const deep = join(root, "Library Mobile Documents com~apple~CloudDocs Steuern und Versicherungen 2026 Belege");
		await mkdir(deep);
		for (let i = 0; i < 45; i++) await writeFile(join(deep, `Rechnung Zahnarzt Praxis Dr. Mustermann Behandlung Nummer ${String(i).padStart(3, "0")}.pdf`), "x");
		const result = await listFolder(deep);
		const text = result.content[0].text;
		assert.ok(FACT_RESULT_CHARS < SMALLEST_RESULT_LIMIT);
		assert.ok(text.length <= FACT_RESULT_CHARS, `${text.length}`);
		const facts = JSON.parse(text);
		assert.ok(facts.entries.length <= 20 && facts.entries.length > 5, `${facts.entries.length}`);
		assert.equal(facts.total, 45);
		assert.equal(facts.left_out, 45 - facts.entries.length);
		const small = JSON.parse((await listFolder(deep, undefined, 1_500)).content[0].text);
		assert.equal(small.left_out, 45 - small.entries.length, "a smaller budget drops whole entries and counts them");
	} finally { await rm(root, { recursive: true, force: true }); }
});
