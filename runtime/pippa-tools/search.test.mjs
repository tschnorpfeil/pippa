// File search (search.mjs) without Spotlight: a fake mdfind answers from a small invented home folder.
//
//   node --test runtime/pippa-tools/search.test.mjs
import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile, utimes } from "node:fs/promises";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { folderPredicate, parseQuery, personal, predicate, search, stem } from "./search.mjs";

const here = fileURLToPath(new URL(".", import.meta.url));
await mkdir(join(here, "../../.build"), { recursive: true });
const home = await mkdtemp(join(here, "../../.build/pippa-search-test-"));

// path → text content; folders come from the paths.
const corpus = {
	"projects/Kinderbuch/Kinderbuch_35cm_Gesamt.pdf": "Es war einmal ein kleiner Bär.",
	"projects/Kinderbuch/LayoutSketch.pdf": "",
	"Documents/Kinderbuch/Verläge.md": "Kinderbuch an Verlage schicken, PDF anhängen.",
	"Documents/a.pdf": "Zahnarzt Rechnung 2023",
	"Downloads/2023.pdf": "Urlaub 2026, kein Zahnarzt",
	"Library/Caches/Kinderbuch.pdf": "Kinderbuch",
	"Library/Mobile Documents/com~apple~CloudDocs/Kinderbuch Notizen.txt": "Ideen",
	".hidden/Kinderbuch.pdf": "Kinderbuch",
	"Developer/app/node_modules/kinderbuch/readme.md": "Kinderbuch",
};
for (const [path, text] of Object.entries(corpus)) {
	await mkdir(join(home, path, ".."), { recursive: true });
	await writeFile(join(home, path), text);
}
await utimes(join(home, "projects/Kinderbuch/LayoutSketch.pdf"), new Date(2020, 0, 1), new Date(2020, 0, 1));
const folders = [...new Set(Object.keys(corpus).flatMap((p) => p.split("/").slice(0, -1).map((_, i, parts) => parts.slice(0, i + 1).join("/"))))];

/** A tiny mdfind: understands the queries search.mjs builds (content prefix, name part, folder name, all). */
function fakeMdfind(args) {
	const where = args[args.indexOf("-onlyin") + 1];
	const query = args.at(-1);
	const items = [...Object.keys(corpus).map((p) => ({ path: join(home, p), text: corpus[p], folder: false })),
		...folders.map((p) => ({ path: join(home, p), text: "", folder: true }))].filter((i) => i.path.startsWith(where + "/"));
	const name = (i) => i.path.split("/").at(-1).toLowerCase();
	const hits = items.filter((item) => {
		if (query === 'kMDItemFSName == "*"') return true;
		if (query.startsWith('kMDItemContentType == "public.folder"')) return item.folder && [...query.matchAll(/FSName == "\*(.+?)\*"cd/g)].some((m) => name(item).includes(m[1]));
		return query.split(" && ").every((part) => {
			const [, word] = part.match(/TextContent == "([^"*]+)\*?"cd/) ?? [];
			const words = item.text.toLowerCase().match(/[\p{L}\p{N}]+/gu) ?? [];
			const content = words.some((w) => part.includes(`"${word}*"`) ? w.startsWith(word) : w === word);
			const inName = part.includes("FSName") && name(item).includes(word);
			return !item.folder && (content || inName);
		});
	});
	return Promise.resolve({ stdout: hits.map((h) => h.path).join("\0") });
}

test("query words: stems, file type words and generic words leave the topic", () => {
	assert.deepEqual([stem("Kinderbuchs"), stem("Rechnungen"), stem("Haus"), stem("2023")], ["kinderbuch", "rechnung", "haus", "2023"]);
	assert.deepEqual(parseQuery("PDF Kinderbuchs"), { words: ["kinderbuch"], kind: "pdf" });
	assert.deepEqual(parseQuery("Dokument Zahnarzt"), { words: ["zahnarzt"], kind: undefined });
	assert.deepEqual(parseQuery("PDF"), { words: ["pdf"], kind: "pdf" }, "a type alone stays the topic");
	assert.deepEqual(parseQuery("Urlaub", "Fotos"), { words: ["urlaub"], kind: "image" });
	assert.equal(predicate("Zahnarzt", "2023"), '(kMDItemTextContent == "zahnarzt*"cd || kMDItemFSName == "*zahnarzt*"cd) && kMDItemTextContent == "2023"cd');
	assert.equal(folderPredicate(["kinderbuch"]), 'kMDItemContentType == "public.folder" && (kMDItemFSName == "*kinderbuch*"cd)');
	assert.throws(() => predicate("Steuer", "2023; rm x"));
	assert.throws(() => predicate("", undefined));
});

test("personal places only: no hidden folders, no Library outside the cloud drives, no packages", () => {
	assert.ok(personal(`${home}/projects/a.pdf`, home));
	assert.ok(personal(`${home}/Library/Mobile Documents/com~apple~CloudDocs/a.pdf`, home));
	assert.ok(personal(`${home}/Library/CloudStorage/Drive/a.pdf`, home));
	for (const p of ["Library/Caches/a.pdf", ".config/a.pdf", "x/node_modules/a.md", "Pictures/Photos Library.photoslibrary/a.jpg", "Applications/X.app/Contents/a.pdf"])
		assert.ok(!personal(`${home}/${p}`, home), p);
	assert.ok(!personal("/elsewhere/a.pdf", home));
});

test("the children's book: PDFs in a folder named like the topic, the named type first", async () => {
	const result = await search("Kinderbuchs", undefined, home, { kind: "pdf", run: fakeMdfind });
	assert.equal(result.status, "ok");
	assert.deepEqual(result.files.map((f) => f.path.slice(home.length + 1)), [
		"projects/Kinderbuch/Kinderbuch_35cm_Gesamt.pdf",
		"projects/Kinderbuch/LayoutSketch.pdf",
		"Library/Mobile Documents/com~apple~CloudDocs/Kinderbuch Notizen.txt",
		"Documents/Kinderbuch/Verläge.md",
	]);
	assert.equal(result.kind, "pdf");
	// "PDF" in the query works like kind.
	assert.deepEqual((await search("PDF Kinderbuch", undefined, home, { run: fakeMdfind })).files.slice(0, 2).map((f) => f.name),
		["Kinderbuch_35cm_Gesamt.pdf", "LayoutSketch.pdf"]);
});

test("year stays a content condition; a file name with the year is no hit", async () => {
	const result = await search("Zahnarzt", "2023", home, { run: fakeMdfind });
	assert.deepEqual(result.files.map((f) => f.name), ["a.pdf"]);
});

test("no home folder: unavailable, nothing searched", async () => {
	const result = await search("Steuer", undefined, join(home, "missing"), { run: fakeMdfind });
	assert.equal(result.status, "unavailable");
	assert.deepEqual(result.files, []);
});
