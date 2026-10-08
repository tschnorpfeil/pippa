// Tests the receipt entries of the Pippa guard without a model and without Pi: a stand-in `pi` accepts the handlers,
// the tests call `tool_call` and `tool_result` like Pi itself. Everything in a fresh folder under .build/ in the repo.
//
//   node --experimental-strip-types --test runtime/pippa-guard/guard.test.mjs
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { constants } from "node:fs";
import { copyFile, mkdtemp, readdir, readFile, rename, stat, writeFile, mkdir } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const here = fileURLToPath(new URL(".", import.meta.url));
await mkdir(join(here, "../../.build"), { recursive: true });
const root = await mkdtemp(join(here, "../../.build/pippa-guard-test-"));
process.env.PIPPA_UNDO_DIR = join(root, "undo");
process.env.PIPPA_TRASH_DIR = join(root, "trash");   // restore.mjs legt dorthin statt in den echten Papierkorb
delete process.env.PIPPA_GUARD_DECLINE;
const { default: guard, RECEIPT_TYPE, ALLOW, ALLOW_FOR_TASK, DENY } = await import("./pippa-guard.ts");
const { classify, classifyCommand, mkdirTargets, POLICIES, pruneUndo } = await import("./policy.ts");
const { planMoves, folderLabel } = await import("./files.ts");
const { capResult, resultLimit, shortenParameters } = await import("./budget.ts");

/** Was `pi.getAllTools()` liefert: Pis eingebaute Werkzeuge (`builtin`), Pippas Werkzeuge (`--extension` → `cli`). */
const builtin = (name) => ({ name, sourceInfo: { path: `builtin:${name}`, source: "builtin" } });
const pippa = (name, annotations) => ({ name, annotations, sourceInfo: { path: "/x/pippa-tools.ts", source: "cli" } });
const tools = [...["read", "write", "edit", "bash", "grep", "find", "ls"].map(builtin),
	pippa("list_folder", { readOnlyHint: true, openWorldHint: false }), pippa("rename_or_move"), pippa("move_files"), pippa("move_to_trash")];

/**
 * A guard with its own entry list; `answer` answers the question (confirm: true/false, select: the answer, or
 * true for "Erlauben", false for "Nicht erlauben"). The older cases test `ask-all`.
 */
function load({ answer = true, hasUI = true, policy = "ask-all" } = {}) {
	const handlers = {};
	const entries = [];
	const asked = [];
	process.env.PIPPA_GUARD_POLICY = policy;
	guard({
		on: (name, handler) => { handlers[name] = handler; },
		appendEntry: (type, data) => { assert.equal(type, RECEIPT_TYPE); entries.push(data); },
		getAllTools: () => tools,
	});
	const ctx = { cwd: root, hasUI, ui: {
		confirm: async (title, message) => { asked.push(message); return answer; },
		select: async (title, options) => {
			asked.push(title);
			assert.deepEqual(options, [ALLOW, ALLOW_FOR_TASK, DENY]);
			return answer === true ? ALLOW : answer === false ? DENY : answer;
		},
	} };
	return {
		entries, asked, handlers,
		call: (toolName, input, toolCallId = `call-${Math.random().toString(36).slice(2)}`) =>
			handlers.tool_call({ toolName, input, toolCallId }, ctx).then((result) => ({ result, toolCallId })),
		result: (toolName, toolCallId, isError, details, text = "") =>
			handlers.tool_result({ toolName, toolCallId, isError, details, content: [{ type: "text", text }], input: {} }, ctx),
	};
}

const present = (path) => stat(path).then(() => true, () => false);

test("abgelehnt: blockiert, Eintrag „declined“, nichts geschrieben", async () => {
	const g = load({ answer: false });
	const { result, toolCallId } = await g.call("write", { path: "Einkauf.txt", content: "Milch" });
	assert.equal(result.block, true);
	assert.match(g.asked[0], /Einkauf\.txt.*anlegen/);
	assert.deepEqual(g.entries.map((e) => [e.toolCallId, e.outcome, e.action, e.name]), [[toolCallId, "declined", "create", "Einkauf.txt"]]);
	assert.equal(await present(join(root, "Einkauf.txt")), false);
});

test("allowed + done: entry 'done' with undo folder", async () => {
	const g = load();
	const { result, toolCallId } = await g.call("write", { path: "Neu.txt", content: "x" });
	assert.equal(result, undefined);
	assert.equal(g.entries.length, 0, "no receipt before the result");
	await g.result("write", toolCallId, false, undefined);
	const [entry] = g.entries;
	assert.equal(entry.outcome, "done");
	assert.equal(entry.restorable, true);
	const manifest = JSON.parse(await readFile(join(entry.undo, "manifest.json"), "utf8"));
	assert.equal(manifest.entries[0].existed, false);
});

test("allowed + tool error: entry 'failed' with error text", async () => {
	const g = load();
	await writeFile(join(root, "Liste.txt"), "Milch\n");
	const { toolCallId } = await g.call("edit", { path: "Liste.txt", edits: [{ oldText: "Käse", newText: "Brot" }] });
	await g.result("edit", toolCallId, true, undefined, "Could not find the exact text");
	assert.deepEqual(g.entries.map((e) => [e.outcome, e.action, e.name, e.error]), [["failed", "change", "Liste.txt", "Could not find the exact text"]]);
});

test("without UI: blocked, entry 'blocked'/noUI", async () => {
	const g = load({ hasUI: false });
	const { result } = await g.call("bash", { command: "rm Liste.txt" });
	assert.equal(result.block, true);
	assert.deepEqual(g.entries.map((e) => [e.outcome, e.reason, e.action, e.name]), [["blocked", "noUI", "delete", "Liste.txt"]]);
});

test("read-only: list_folder and read without a question and without an entry", async () => {
	const g = load({ answer: false });
	assert.equal((await g.call("list_folder", { path: "." })).result, undefined);
	assert.equal((await g.call("read", { path: "Liste.txt" })).result, undefined);
	assert.equal(g.asked.length, 0);
	assert.equal(g.entries.length, 0);
});

test("rename: plain-language question, manifest with moves, restore.mjs brings the old name back", async () => {
	const g = load();
	await writeFile(join(root, "Alt.txt"), "a");
	const { toolCallId } = await g.call("rename_or_move", { from: "Alt.txt", to: "Neu-Name.txt" });
	assert.match(g.asked[0], /‚Alt\.txt‘ im Ordner .* in ‚Neu-Name\.txt‘ umbenennen/);
	await rename(join(root, "Alt.txt"), join(root, "Neu-Name.txt"));   // the tool itself
	await g.result("rename_or_move", toolCallId, false, { from: join(root, "Alt.txt"), to: join(root, "Neu-Name.txt") });
	const [entry] = g.entries;
	assert.deepEqual([entry.outcome, entry.action, entry.name, entry.toName, entry.restorable], ["done", "rename", "Alt.txt", "Neu-Name.txt", true]);
	execFileSync(process.execPath, [join(here, "restore.mjs"), entry.undo]);
	assert.equal(await present(join(root, "Alt.txt")), true);
	assert.equal(await present(join(root, "Neu-Name.txt")), false);
});

test("verschieben in einen Ordner: Frage nennt den Zielordner", async () => {
	const g = load({ answer: false });
	await mkdir(join(root, "Archiv"), { recursive: true });
	await writeFile(join(root, "Brief.txt"), "b");
	await g.call("rename_or_move", { from: "Brief.txt", to: "Archiv" });
	assert.match(g.asked[0], /in den Ordner ‚Archiv‘ verschieben/);
	assert.deepEqual(g.entries.map((e) => [e.outcome, e.action, e.toName]), [["declined", "move", "Archiv"]]);
});

test("trash: target from the result into the manifest, restorable", async () => {
	const g = load();
	await writeFile(join(root, "Weg.txt"), "w");
	const { toolCallId } = await g.call("move_to_trash", { path: "Weg.txt" });
	assert.match(g.asked[0], /‚Weg\.txt‘ .* in den Papierkorb legen/);
	const trashed = join(root, "fake-trash", "Weg.txt");
	await mkdir(join(root, "fake-trash"), { recursive: true });
	await rename(join(root, "Weg.txt"), trashed);
	await g.result("move_to_trash", toolCallId, false, { path: join(root, "Weg.txt"), trashedTo: trashed });
	const [entry] = g.entries;
	assert.deepEqual([entry.outcome, entry.action, entry.restorable], ["done", "trash", true]);
	execFileSync(process.execPath, [join(here, "restore.mjs"), entry.undo]);
	assert.equal(await present(join(root, "Weg.txt")), true);
});

test("bash look-only: receipt 'look', no undo", async () => {
	const g = load();
	const { toolCallId } = await g.call("bash", { command: "ls -1 | wc -l" });
	await g.result("bash", toolCallId, false, undefined);
	assert.deepEqual(g.entries.map((e) => [e.outcome, e.action, e.restorable]), [["done", "look", false]]);
});

test("read-only applies only to Pi and Pippa: foreign 'read', hints of foreign tools and foreign MCP servers ask", async () => {
	const { readsOnly } = await import("./pippa-guard.ts");
	const user = { path: "/Users/x/.pi/agent/extensions/a.ts", source: "auto", scope: "user" };
	const ro = { readOnlyHint: true, openWorldHint: false };
	assert.equal(readsOnly("read", builtin("read")), true);
	assert.equal(readsOnly("list_folder", tools.find((t) => t.name === "list_folder")), true);
	assert.equal(readsOnly("read", { name: "read", sourceInfo: user }), false, "eingebautes read durch Extension ersetzt");
	assert.equal(readsOnly("peek", { name: "peek", annotations: ro, sourceInfo: user }), false, "readOnlyHint einer fremden Extension");
	assert.equal(readsOnly("mcp__pippa__mail_read", { annotations: ro, sourceInfo: { path: "builtin:mcp", source: "builtin" } }), true);
	assert.equal(readsOnly("mcp__notes__read", { annotations: ro, sourceInfo: { path: "builtin:mcp", source: "builtin" } }), false, "fremder MCP-Server");
	assert.equal(readsOnly("mcp__pippa__x", { annotations: ro, sourceInfo: user }), false, "Name nachgemacht, Quelle fremd");
	assert.equal(readsOnly("write", undefined), false);
});

test("arguments are frozen after the question", async () => {
	const g = load({ answer: false });
	const input = { path: "Frost.txt", content: "x" };
	await g.call("write", input);
	assert.throws(() => { input.path = "Anders.txt"; }, TypeError);
	assert.equal(input.path, "Frost.txt");
});

test("restore.mjs: change reverted, current state and newly created files go to the trash, restored.json", async () => {
	const g = load();
	await writeFile(join(root, "Brief.md"), "alt\n");
	const edited = await g.call("edit", { path: "Brief.md", edits: [{ oldText: "alt", newText: "neu" }] });
	await writeFile(join(root, "Brief.md"), "neu\n");
	await g.result("edit", edited.toolCallId, false, undefined);
	const created = await g.call("write", { path: "Frisch.md", content: "f" });
	await writeFile(join(root, "Frisch.md"), "f");
	await g.result("write", created.toolCallId, false, undefined);
	const [edit, write] = g.entries;
	execFileSync(process.execPath, [join(here, "restore.mjs"), edit.undo]);
	execFileSync(process.execPath, [join(here, "restore.mjs"), write.undo]);
	assert.equal(await readFile(join(root, "Brief.md"), "utf8"), "alt\n");
	assert.equal(await readFile(join(root, "trash", "Brief.md"), "utf8"), "neu\n");
	assert.equal(await present(join(root, "Frisch.md")), false);
	assert.equal(await readFile(join(root, "trash", "Frisch.md"), "utf8"), "f");
	assert.equal(await present(join(edit.undo, "restored.json")), true);
	assert.deepEqual(await readdir(write.undo), ["manifest.json", "restored.json"], "no copy for newly created files");
});

test("classification: file tools, look, delete, network, send, other commands, foreign tools", () => {
	const cases = {
		fileChange: [["write", {}], ["edit", {}], ["rename_or_move", {}], ["move_files", {}], ["move_to_trash", {}], ["bash", { command: "mkdir Neu" }],
			["bash", { command: "mkdir -p Belege/2026 Archiv" }], ["bash", { command: "mkdir -pv ~/Desktop/Ablage" }], ["bash", { command: "mkdir Mail" }]],
		look: [["bash", { command: "ls -la | wc -l" }], ["bash", { command: "cat Brief.md" }], ["bash", { command: "grep -r Miete ." }],
			["bash", { command: "mdfind -onlyin ~/Documents 'Mietvertrag'" }], ["bash", { command: "mdfind -name Rechnung | head -20" }],
			["bash", { command: "fd -e pdf . ~/Documents" }], ["bash", { command: "rg -il nebenkosten ~/Documents" }], ["bash", { command: "mdls -name kMDItemContentCreationDate a.pdf" }],
			["bash", { command: "ls -lax" }], ["bash", { command: "find /Users/remi -type f -name \"*.md\" 2>/dev/null | head -50" }],
			["bash", { command: "grep -ril nullkalkulation ~/Documents 2>&1 | head" }], ["bash", { command: "ls x >/dev/null && echo ja" }]],
		delete: [["bash", { command: "rm Brief.md" }], ["bash", { command: "rm -rf Archiv" }], ["bash", { command: "find . -name '*.tmp' -delete" }],
			["bash", { command: "cd x && unlink a" }], ["bash", { command: "find . -exec rm {} \\;" }]],
		network: [["bash", { command: "curl https://example.com" }], ["bash", { command: "wget x" }], ["bash", { command: "python3 skript.py" }],
			["bash", { command: "node a.js" }], ["bash", { command: "ssh host ls" }], ["bash", { command: "git push" }], ["bash", { command: "osascript -e 'tell application \"Finder\" to get name'" }]],
		send: [["bash", { command: "echo hi | mail -s x a@b.c" }], ["bash", { command: "osascript -e 'tell application \"Mail\" to send newMessage'" }]],
		command: [["bash", { command: "echo b > Bash.txt" }], ["bash", { command: "mv a b" }], ["bash", { command: "sed -i '' s/a/b/ x" }],
			["bash", { command: "mkdir \"Neuer Ordner\"" }], ["bash", { command: "mkdir -m 700 Geheim" }], ["bash", { command: "mkdir $HOME/x" }],
			["bash", { command: "mkdir a && touch a/b" }], ["bash", { command: "mkdir *.x" }], ["bash", { command: "mkdir" }], ["bash", { command: "mkdir -- -p" }],
			["bash", { command: "fd -e tmp -x gzip" }], ["bash", { command: "fd . -X trash" }], ["bash", { command: "fd -HX ls" }], ["bash", { command: "fd --exec-batch zip a.zip" }],
			["bash", { command: "rg --pre ./skript x" }], ["bash", { command: "mdfind -live Rechnung" }],
			["bash", { command: "find . 2>/dev/null > liste.txt" }], ["bash", { command: "ls > /dev/null.txt" }], ["bash", { command: "ls 2>fehler.log" }]],
		tool: [["save_note", {}], ["mcp__notes__create", {}]],
	};
	for (const [category, calls] of Object.entries(cases)) {
		for (const [tool, input] of calls) assert.equal(classify(tool, input), category, `${tool} ${input.command ?? ""}`);
	}
	assert.equal(classifyCommand("node_modules/.bin/x"), "command", "\"node\" only as a word of its own");
	assert.equal(classifyCommand("mkdir a; rm -rf b"), "delete", "second command: not a plain mkdir");
	assert.deepEqual(mkdirTargets("mkdir -p Belege/2026 Archiv"), { parents: true, paths: ["Belege/2026", "Archiv"] });
	assert.deepEqual(mkdirTargets("mkdir Äpfel"), { parents: false, paths: ["Äpfel"] });
	assert.equal(mkdirTargets("mkdir a\nrm b"), undefined);
});

test("mkdir under undo-first: no question, receipt 'createFolder', undo moves the new folders to the trash", async () => {
	const g = load({ policy: "undo-first", answer: false });
	await mkdir(join(root, "mk"), { recursive: true });
	const { result, toolCallId } = await g.call("bash", { command: "mkdir -p mk/Belege/2026 mk/Archiv" });
	assert.equal(result, undefined);
	assert.equal(g.asked.length, 0);
	await mkdir(join(root, "mk/Belege/2026"), { recursive: true });   // the command itself
	await mkdir(join(root, "mk/Archiv"));
	await writeFile(join(root, "mk/Belege/.DS_Store"), "");              // created by Finder, does not count
	await g.result("bash", toolCallId, false, undefined);
	const [entry] = g.entries;
	assert.deepEqual([entry.outcome, entry.action, entry.name, entry.restorable, entry.category, entry.asked],
		["done", "createFolder", "2026", true, "fileChange", false]);
	const manifest = JSON.parse(await readFile(join(entry.undo, "manifest.json"), "utf8"));
	assert.deepEqual(manifest.folders, [join(root, "mk/Belege"), join(root, "mk/Archiv")]);
	assert.deepEqual(manifest.created, [join(root, "mk/Belege"), join(root, "mk/Belege/2026"), join(root, "mk/Archiv")]);
	execFileSync(process.execPath, [join(here, "restore.mjs"), entry.undo]);
	assert.deepEqual(await readdir(join(root, "mk")), []);
	assert.equal(await present(join(entry.undo, "restored.json")), true);
});

test("mkdir: no longer empty stays, restore.mjs reports it; already existing means nothing to restore; ask-all asks in words", async () => {
	const g = load({ policy: "undo-first" });
	const { toolCallId } = await g.call("bash", { command: "mkdir Volle" });
	await mkdir(join(root, "Volle"));
	await g.result("bash", toolCallId, false, undefined);
	await writeFile(join(root, "Volle/Brief.txt"), "x");
	let failed = false;
	try { execFileSync(process.execPath, [join(here, "restore.mjs"), g.entries[0].undo], { stdio: "pipe" }); }
	catch (error) { failed = true; assert.match(String(error.stdout), /nicht leer, bleibt/); }
	assert.equal(failed, true);
	assert.equal(await present(join(root, "Volle/Brief.txt")), true);
	assert.equal(await present(join(g.entries[0].undo, "restored.json")), false);

	const again = await g.call("bash", { command: "mkdir -p Volle" });
	await g.result("bash", again.toolCallId, false, undefined);
	assert.deepEqual([g.entries[1].action, g.entries[1].restorable], ["createFolder", false]);

	const asking = load({ policy: "ask-all", answer: false });
	await asking.call("bash", { command: "mkdir Neu" });
	assert.match(asking.asked[0], /den Ordner ‚Neu‘ im Ordner .* anlegen/);
	assert.deepEqual(asking.entries.map((e) => [e.outcome, e.action]), [["declined", "createFolder"]]);
	assert.equal(await present(join(root, "Neu")), false);
});

test("presets: one table, limits for backups", () => {
	assert.deepEqual(Object.keys(POLICIES).sort(), ["ask-all", "undo-first"]);
	assert.equal(POLICIES["undo-first"].rules.fileChange, "allow");
	assert.equal(POLICIES["undo-first"].rules.look, "allow");
	for (const c of ["command", "delete", "network", "send", "tool"]) assert.equal(POLICIES["undo-first"].rules[c], "ask", c);
	for (const c of Object.keys(POLICIES["ask-all"].rules)) assert.equal(POLICIES["ask-all"].rules[c], "ask", c);
	assert.equal(POLICIES["undo-first"].keepDays, 7);
	assert.equal(POLICIES["undo-first"].keepBytes, 500 * 1024 * 1024);
});

test("undo-first: file tools without a question but with backup and receipt like ask-all", async () => {
	for (const policy of ["undo-first", "ask-all"]) {
		const g = load({ policy });
		await writeFile(join(root, `Vorher-${policy}.txt`), "alt\n");
		const { result, toolCallId } = await g.call("write", { path: `Vorher-${policy}.txt`, content: "neu" });
		assert.equal(result, undefined);
		await g.result("write", toolCallId, false, undefined);
		const [entry] = g.entries;
		assert.equal(g.asked.length, policy === "ask-all" ? 1 : 0, policy);
		assert.deepEqual([entry.outcome, entry.action, entry.restorable, entry.category, entry.asked], ["done", "overwrite", true, "fileChange", policy === "ask-all"]);
		const manifest = JSON.parse(await readFile(join(entry.undo, "manifest.json"), "utf8"));
		assert.equal(await readFile(manifest.entries[0].snapshot, "utf8"), "alt\n");
	}
});

test("undo-first: deleting asks with three answers; 'allow for this task' lasts until the end of the answer", async () => {
	const g = load({ policy: "undo-first", answer: ALLOW_FOR_TASK });
	await g.handlers.agent_start?.({});
	await g.call("bash", { command: "rm a.txt" });
	await g.call("bash", { command: "rm b.txt" });          // same category: no second question
	await g.call("bash", { command: "curl https://x.y" });  // andere Art: fragt
	assert.equal(g.asked.length, 2);
	assert.match(g.asked[0], /^Darf Pippa das\?\n\nPippa möchte die Datei ‚a\.txt‘/);
	await g.handlers.agent_end?.({});
	await g.call("bash", { command: "rm c.txt" });          // neue Antwort: fragt wieder
	assert.equal(g.asked.length, 3);
	const no = load({ policy: "undo-first", answer: DENY });
	const { result } = await no.call("bash", { command: "rm d.txt" });
	assert.equal(result.block, true);
	assert.deepEqual(no.entries.map((e) => [e.outcome, e.category, e.asked]), [["declined", "delete", true]]);
	const quiet = load({ policy: "undo-first", answer: false, hasUI: false });
	assert.equal((await quiet.call("write", { path: "OhneUI.txt", content: "x" })).result, undefined, "without UI: file tool runs (undoable)");
	assert.equal((await quiet.call("bash", { command: "rm OhneUI.txt" })).result.block, true, "without UI: deleting is blocked");
});

test("backup is an APFS clone (if the volume can clone), pruning by age and size", async () => {
	const g = load({ policy: "undo-first" });
	await writeFile(join(root, "Gross.bin"), Buffer.alloc(1024 * 1024, 7));
	const { toolCallId } = await g.call("edit", { path: "Gross.bin", edits: [] });
	await g.result("edit", toolCallId, false, undefined);
	const snapshot = JSON.parse(await readFile(join(g.entries[0].undo, "manifest.json"), "utf8")).entries[0].snapshot;
	// Same first block on disk means clone (F_LOG2PHYS, scripts/tests/same-blocks.py).
	const same = execFileSync("python3", [join(here, "../../scripts/tests/same-blocks.py"), join(root, "Gross.bin"), snapshot], { encoding: "utf8" }).trim();
	assert.equal(same, "clone");

	const pruneRoot = join(root, "prune");
	const day = 86_400_000, now = Date.now();
	async function entry(name, ageDays, bytes) {
		await mkdir(join(pruneRoot, name, "files"), { recursive: true });
		await writeFile(join(pruneRoot, name, "manifest.json"), JSON.stringify({ createdAt: new Date(now - ageDays * day).toISOString() }));
		await writeFile(join(pruneRoot, name, "files", "x"), Buffer.alloc(bytes));
	}
	await entry("a-alt", 8, 10); await entry("b", 3, 400); await entry("c", 2, 400); await entry("d", 1, 400);
	await mkdir(join(pruneRoot, "kein-eintrag"), { recursive: true });
	const removed = await pruneUndo(pruneRoot, { ...POLICIES["undo-first"], keepBytes: 1000 }, now);
	assert.deepEqual(removed, ["a-alt", "b"]);
	assert.deepEqual((await readdir(pruneRoot)).sort(), ["c", "d", "kein-eintrag"]);
});

/** What `move_files` itself does (pippa-tools.ts), here without Pi: same plan, mkdir, rename; never overwrites. */
async function runMoveFiles(input) {
	const plan = await planMoves(input.folder, input.groups, root);
	const moved = [];
	for (const item of plan.items) {
		if (item.error) continue;
		await mkdir(item.into, { recursive: true });
		await rename(item.from, item.to);
		moved.push({ from: item.from, to: item.to });
	}
	return moved;
}

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

test("move_files: no question under undo-first, ONE manifest for the batch, one restore brings everything back", async () => {
	const g = load({ policy: "undo-first", answer: false });
	const dir = join(root, "tidy");
	await mkdir(join(dir, "PDFs"), { recursive: true });
	const names = ["Rechnung.pdf", "Vertrag.pdf", "Foto1.jpg", "Foto2.png", "Notiz.txt", "Doppelt.pdf"];
	for (const f of names) await writeFile(join(dir, f), f);
	await writeFile(join(dir, "PDFs", "Doppelt.pdf"), "alt");
	const input = { folder: dir, groups: [{ into: "PDFs", files: ["Rechnung.pdf", "Vertrag.pdf", "Doppelt.pdf"] }, { into: "Bilder", files: ["Foto1.jpg", "Foto2.png"] },
		{ into: "Texte/2026", files: ["Notiz.txt"] }] };
	const { result, toolCallId } = await g.call("move_files", input);
	assert.equal(result, undefined);
	assert.equal(g.asked.length, 0, "moves inside user folders are undoable: no question");
	const moved = await runMoveFiles(input);
	assert.equal(moved.length, 5);
	await g.result("move_files", toolCallId, false, { folder: dir, moved, failed: [{ name: "Doppelt.pdf", error: "exists" }] });
	assert.equal(g.entries.length, 1, "one receipt for the whole batch");
	const [entry] = g.entries;
	assert.deepEqual([entry.outcome, entry.action, entry.name, entry.toName, entry.restorable, entry.category, entry.asked],
		["done", "move", "5 Dateien", "PDFs, Bilder, Texte/2026", true, "fileChange", false]);
	const manifest = JSON.parse(await readFile(join(entry.undo, "manifest.json"), "utf8"));
	assert.equal(manifest.moves.length, 5);
	assert.deepEqual(manifest.folders, [join(dir, "Bilder"), join(dir, "Texte")]);
	execFileSync(process.execPath, [join(here, "restore.mjs"), entry.undo]);
	for (const f of names) assert.equal(await present(join(dir, f)), true, f);
	assert.deepEqual((await readdir(dir)).sort(), [...names, "PDFs"].sort(), "new folders gone");
	assert.deepEqual(await readdir(join(dir, "PDFs")), ["Doppelt.pdf"], "the existing file was never touched");
	assert.equal(await present(join(entry.undo, "restored.json")), true);
});

test("move_files partial success: manifest rewritten to what really moved; ask-all asks one question in words", async () => {
	const g = load({ policy: "undo-first" });
	const dir = join(root, "partial");
	await mkdir(dir, { recursive: true });
	for (const f of ["a.pdf", "b.pdf"]) await writeFile(join(dir, f), f);
	const { toolCallId } = await g.call("move_files", { folder: dir, groups: [{ into: "PDFs", files: ["a.pdf", "b.pdf"] }] });
	const before = JSON.parse(await readFile(join(root, "undo", (await readdir(join(root, "undo"))).sort().pop(), "manifest.json"), "utf8"));
	assert.equal(before.moves.length, 2, "manifest written before the change");
	await mkdir(join(dir, "PDFs"));
	await rename(join(dir, "a.pdf"), join(dir, "PDFs/a.pdf"));   // b.pdf failed in the tool
	await g.result("move_files", toolCallId, false, { folder: dir, moved: [{ from: join(dir, "a.pdf"), to: join(dir, "PDFs/a.pdf") },
		{ from: "/etc/hosts", to: join(dir, "hosts") }] });
	const manifest = JSON.parse(await readFile(join(g.entries[0].undo, "manifest.json"), "utf8"));
	assert.deepEqual(manifest.moves, [{ from: join(dir, "a.pdf"), to: join(dir, "PDFs/a.pdf") }], "only planned moves that happened");
	execFileSync(process.execPath, [join(here, "restore.mjs"), g.entries[0].undo]);
	assert.deepEqual((await readdir(dir)).sort(), ["a.pdf", "b.pdf"]);

	const asking = load({ policy: "ask-all", answer: false });
	await asking.call("move_files", { folder: dir, groups: [{ into: "PDFs", files: ["a.pdf"] }, { into: "Alt", files: ["b.pdf"] }] });
	assert.equal(asking.asked.length, 1);
	assert.match(asking.asked[0], /im Ordner ‚partial‘ 2 Dateien in 2 Ordner \(PDFs, Alt\) einsortieren/);
	assert.deepEqual(asking.entries.map((e) => [e.outcome, e.action, e.name]), [["declined", "move", "2 Dateien"]]);
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
