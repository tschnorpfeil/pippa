import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { listFolder } from "./list-folder.ts";

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

test("actual folder listing retains ordering, count and empty/missing distinction", async () => {
	const root = await mkdtemp(join(tmpdir(), "pippa-folder-access-"));
	try {
		assert.match((await listFolder(root)).content[0].text, /is empty/);
		await mkdir(join(root, "z-folder"));
		await writeFile(join(root, "a.txt"), "hello");
		await writeFile(join(root, ".hidden"), "hidden");
		const result = await listFolder(root);
		assert.equal(result.isError, undefined);
		assert.deepEqual(result.details, { folder: root, count: 2 });
		assert.match(result.content[0].text, /a\.txt \(5 B, .*\)\nz-folder\//);
		await assert.rejects(listFolder(join(root, "missing")), /There is no folder/);
		await assert.rejects(listFolder(join(root, "a.txt")), /not a folder/);
	} finally { await rm(root, { recursive: true, force: true }); }
});
