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
	"Documents/invoices/scan.txt": "Zahnarzt 2023",
	"Documents/Rechnungen/beleg.txt": "Zahnarzt 2023",
	"Documents/insurance/policy.txt": "2026",
	"Documents/Versicherungen/police.txt": "2026",
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
	const wheres = args.flatMap((a, i) => (a === "-onlyin" ? [args[i + 1]] : []));
	const query = args.at(-1);
	const items = [...Object.keys(corpus).map((p) => ({ path: join(home, p), text: corpus[p], folder: false })),
		...folders.map((p) => ({ path: join(home, p), text: "", folder: true }))].filter((i) => wheres.some((where) => i.path.startsWith(where + "/")));
	const name = (i) => i.path.split("/").at(-1).toLowerCase();
	const hits = items.filter((item) => {
		if (query === 'kMDItemFSName == "*"') return true;
		if (query.startsWith('kMDItemContentType == "public.folder"')) return item.folder && [...query.matchAll(/FSName == "\*(.+?)\*"cd/g)].some((m) => name(item).includes(m[1]));
		return query.split(" && ").every((part) => {
			const words = item.text.toLowerCase().match(/[\p{L}\p{N}]+/gu) ?? [];
			const content = [...part.matchAll(/TextContent == "([^"*]+)(\*?)"cd/g)].some(([, word, prefix]) => words.some(w => prefix ? w.startsWith(word) : w === word));
			const inName = [...part.matchAll(/FSName == "\*(.+?)\*"cd/g)].some(([, word]) => name(item).includes(word));
			return !item.folder && (content || inName);
		});
	});
	return Promise.resolve({ stdout: hits.map((h) => h.path).join("\0") });
}

test("query words: stems, file type words and generic words leave the topic", () => {
	assert.deepEqual([stem("Kinderbuchs"), stem("Rechnungen"), stem("Briefe"), stem("Handwerker"), stem("Haus"), stem("2023")], ["kinderbuch", "rechnung", "brief", "handwerk", "haus", "2023"]);
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

test("the children's book: PDFs in a folder named like the topic; a named type filters, newest first", async () => {
	const result = await search("Kinderbuchs", undefined, home, { kind: "pdf", run: fakeMdfind });
	assert.equal(result.status, "ok");
	assert.deepEqual(result.files.map((f) => f.path.slice(home.length + 1)), [
		"projects/Kinderbuch/Kinderbuch_35cm_Gesamt.pdf",
		"projects/Kinderbuch/LayoutSketch.pdf",
	]);
	assert.equal(result.kind, "pdf");
	assert.equal(result.total, 2);
	assert.equal(result.files[0].newest, true);
	assert.equal(result.newest_file, result.files[0].path);
	assert.deepEqual(Object.keys(result.files[1]), ["name", "path", "kind", "size", "modified"]);
	assert.match(result.files[1].modified, /^2020-01-01T00:00:00[+-]\d\d:\d\d$/);
	const all = await search("Kinderbuchs", undefined, home, { run: fakeMdfind });
	assert.equal(all.files.at(-1).name, "LayoutSketch.pdf", "without a type: every match, the oldest last");
	assert.equal(all.files.find((f) => f.name === "Verläge.md").kind, "file");
	const byName = await search("Kinderbuchs", undefined, home, { run: fakeMdfind, sort: "name" });
	assert.deepEqual(byName.files.map((f) => f.name), ["Kinderbuch Notizen.txt", "Kinderbuch_35cm_Gesamt.pdf", "LayoutSketch.pdf", "Verläge.md"]);
	assert.equal(byName.sorted, "by name");
	// "PDF" in the query works like kind.
	assert.deepEqual((await search("PDF Kinderbuch", undefined, home, { run: fakeMdfind })).files.slice(0, 2).map((f) => f.name),
		["Kinderbuch_35cm_Gesamt.pdf", "LayoutSketch.pdf"]);
});

test("year stays a content condition; a file name with the year is no hit", async () => {
	const result = await search("Zahnarzt", "2023", home, { run: fakeMdfind });
	assert.deepEqual(result.files.map((f) => f.name).sort(), ["a.pdf", "beleg.txt", "scan.txt"]);
});

test("invoice and insurance categories cross languages while the other words and year still constrain results", async () => {
	const paths = async (query, year) => (await search(query, year, home, { run: fakeMdfind })).files.map(f => f.path.slice(home.length + 1)).sort();
	const invoices = ["Documents/Rechnungen/beleg.txt", "Documents/a.pdf", "Documents/invoices/scan.txt"];
	for (const query of ["invoice Zahnarzt", "invoices Zahnarzt", "Rechnungen Zahnarzt"])
		assert.deepEqual(await paths(query, "2023"), invoices, query);
	assert.deepEqual(await paths("invoice Zahnarzt", "2024"), []);
	assert.deepEqual(await paths("invoice Kinderbuch", "2023"), []);
	assert.deepEqual(await paths("insurance"), await paths("Versicherung"));
	assert.equal((await paths("insurance")).length, 2);
	assert.ok(!predicate("Bill").includes("invoice"), "ambiguous words and names remain literal");
});

test("no home folder: unavailable, nothing searched", async () => {
	const result = await search("Steuer", undefined, join(home, "missing"), { run: fakeMdfind });
	assert.equal(result.status, "unavailable");
	assert.deepEqual(result.files, []);
});

test("many matches: at most 20, sorted newest first, the rest counted, JSON under the result cap", async () => {
	const many = join(home, "Documents/Steuer");
	await mkdir(many, { recursive: true });
	const names = Array.from({ length: 30 }, (_, i) => `Steuerbescheid Einkommensteuer Anlage Kapitalvermögen ${String(i).padStart(2, "0")}.md`);
	for (const [i, name] of names.entries()) {
		await writeFile(join(many, name), i === 3 ? "---\nupdated: 2026-10-01\n---\nSteuer" : "Steuer");
		await utimes(join(many, name), new Date(2026, 0, 1 + i), new Date(2026, 0, 1 + i));
	}
	const run = (args) => Promise.resolve({ stdout: args.at(-1).includes("public.folder") ? "" : names.map((n) => join(many, n)).join("\0") });
	const result = await search("Steuer", undefined, home, { run });
	const text = JSON.stringify(result);
	assert.ok(text.length <= 5_500, `${text.length}`);
	assert.equal(result.total, 30);
	assert.ok(result.files.length <= 20);
	assert.equal(result.left_out, 30 - result.files.length);
	assert.equal(result.files[0].name, names[29]);
	assert.equal(result.files[0].newest, true);
	const times = result.files.map((f) => f.modified);
	assert.deepEqual([...times].sort().reverse(), times);
	const byName = await search("Steuer", undefined, home, { run, sort: "name" });
	assert.equal(byName.files[3].updated, "2026-10-01", "front matter of Markdown files");
	assert.equal(byName.files[0].newest, undefined);
	assert.equal(byName.newest_file, join(many, names[29]), "the newest is named even when it is not shown");
});
