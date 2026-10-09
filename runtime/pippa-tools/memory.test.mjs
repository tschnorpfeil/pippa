// Pippa's memory (pippa-memory.ts) and quiet context care (pippa-context.ts) without Pi and without a model: a stand-in
// `pi` takes the handlers and tools, the tests call them like Pi itself.
//
//   node --experimental-strip-types --test runtime/pippa-tools/memory.test.mjs
import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, utimes, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const here = fileURLToPath(new URL(".", import.meta.url));
await mkdir(join(here, "../../.build"), { recursive: true });
const root = await mkdtemp(join(here, "../../.build/pippa-memory-test-"));
const memory = await import("./pippa-memory.ts");
const context = await import("./pippa-context.ts");

function standIn() {
	const handlers = {}, tools = {};
	return {
		handlers, tools,
		on(name, handler) { (handlers[name] ??= []).push(handler); },
		registerTool(tool) { tools[tool.name] = tool; },
		async emit(name, event, ctx) { for (const handler of handlers[name] ?? []) await handler(event, ctx); },
	};
}

test("remember: add, change, forget, no duplicates, oldest go when full", () => {
	let change = memory.apply([], { add: "Landlord: Mr Berger" });
	assert.deepEqual(change.facts, ["Landlord: Mr Berger"]);
	change = memory.apply(change.facts, { add: "landlord: mr berger" });
	assert.deepEqual(change.facts, ["Landlord: Mr Berger"], "same fact twice stays once");
	change = memory.apply(change.facts, { forget: "Berger", add: "Landlord: Ms Kraus" });
	assert.deepEqual(change.facts, ["Landlord: Ms Kraus"]);
	assert.deepEqual(change.forgotten, ["Landlord: Mr Berger"]);
	change = memory.apply(["Lives in Köln", "Wants short answers"], { forget: "short answers please" });
	assert.deepEqual(change.facts, ["Lives in Köln", "Wants short answers"], "all words must match");
	change = memory.apply(["Lives in Köln", "Wants short answers"], { forget: "answers short" });
	assert.deepEqual(change.facts, ["Lives in Köln"]);
	assert.deepEqual(memory.apply(["a1", "b2"], { forget: "*" }).facts, []);
	const full = Array.from({ length: memory.MAX_LINES }, (_, i) => `Fact ${i}`);
	change = memory.apply(full, { add: "Newest" });
	assert.equal(change.facts.length, memory.MAX_LINES);
	assert.deepEqual(change.dropped, ["Fact 0"]);
	assert.equal(change.facts.at(-1), "Newest");
	assert.match(memory.apply([], {}).error, /Nothing to do/);
	assert.match(memory.apply([], { add: "x".repeat(memory.MAX_LINE + 1) }).error, /Too long/);
});

test("remember: never numbers like IBAN, account, card, tax or phone, never passwords; dates and amounts are fine", () => {
	for (const fact of ["IBAN DE89 3704 0044 0532 0130 00", "Konto 1234567890", "Steuer-ID 12 345 678 901", "Karte 4111-1111-1111-1111",
		"Telefon 0221 1234567", "Passwort für Mail ist sonne", "PIN 1234", "Die TAN kommt per SMS"]) {
		assert.ok(memory.refusal(fact), fact);
		assert.ok(memory.apply([], { add: fact }).error, fact);
	}
	for (const fact of ["Birthday 09.10.1971", "Rent is 840,50 € a month", "Lives at Hauptstraße 12, 50667 Köln", "Prefers 'du'"]) {
		assert.equal(memory.refusal(fact), undefined, fact);
	}
});

test("memory file: plain lines, foreign lines ignored, written whole and private", async () => {
	const file = join(root, "a", "memory.md");
	assert.deepEqual(await memory.readFacts(file), [], "missing file = knows nothing");
	await memory.writeFacts(file, ["Lives in Köln", "Landlord: Ms Kraus"]);
	assert.equal(await readFile(file, "utf8"), "- Lives in Köln\n- Landlord: Ms Kraus\n");
	await writeFile(file, "# Was Pippa über dich weiß\n\n- Lives in Köln\nnote without dash\n-   \n");
	assert.deepEqual(await memory.readFacts(file), ["Lives in Köln"]);
	assert.equal(memory.memorySection([]), undefined, "no section, no tokens when empty");
	assert.match(memory.memorySection(["Lives in Köln"]), /earlier conversations[\s\S]*\n- Lives in Köln$/);
});

test("extension: section read once per session and unchanged after remember; tool writes the file", async () => {
	const file = join(root, "ext", "memory.md");
	process.env.PIPPA_MEMORY_FILE = file;
	await memory.writeFacts(file, ["Lives in Köln"]);
	const pi = standIn();
	memory.default(pi);
	const turn = async () => { const event = { systemPromptOptions: { sections: {} } }; await pi.emit("before_agent_start", event, {}); return event.systemPromptOptions.sections; };
	await pi.emit("session_start", { reason: "startup" }, {});
	const first = await turn();
	assert.match(first.memory, /- Lives in Köln/);
	const result = await pi.tools.remember.execute("t1", { add: "Landlord: Ms Kraus" });
	assert.match(result.content[0].text, /Remembered: Landlord: Ms Kraus/);
	assert.deepEqual(await memory.readFacts(file), ["Lives in Köln", "Landlord: Ms Kraus"]);
	assert.equal((await turn()).memory, first.memory, "same section for the rest of the session (prompt cache)");
	await pi.emit("session_start", { reason: "startup" }, {});
	assert.match((await turn()).memory, /Landlord: Ms Kraus/, "next session sees the new fact");
	await assert.rejects(pi.tools.remember.execute("t2", { add: "IBAN DE89370400440532013000" }), /never keeps/);
	assert.deepEqual(await memory.readFacts(file), ["Lives in Köln", "Landlord: Ms Kraus"], "refused fact is not written");
	const forgot = await pi.tools.remember.execute("t3", { forget: "*" });
	assert.match(forgot.content[0].text, /Forgotten: Lives in Köln; Landlord: Ms Kraus/);
	assert.equal(await readFile(file, "utf8"), "");
	delete process.env.PIPPA_MEMORY_FILE;
});

test("context: handover from the last summary or the last question and answer, shortened", () => {
	const lines = (...entries) => entries.map((e) => JSON.stringify(e)).join("\n");
	const user = (text) => ({ type: "message", message: { role: "user", content: [{ type: "text", text }] } });
	const assistant = (text) => ({ type: "message", message: { role: "assistant", content: [{ type: "thinking", thinking: "hm" }, { type: "text", text }] } });
	assert.equal(context.handoverFrom(lines({ type: "session", id: "x" })), undefined);
	const plain = context.handoverFrom(lines({ type: "session" }, user("Was steht im Brief?"), assistant("Du musst 84,20 € bis 31.10. zahlen.")));
	assert.equal(plain, "Last question: Was steht im Brief?\nLast answer: Du musst 84,20 € bis 31.10. zahlen.");
	const summarized = context.handoverFrom(lines(user("alt"), { type: "compaction", summary: "Brief der Stadtwerke, 84,20 € bis 31.10." }, user("Und der Termin?"), assistant("Am Montag um 9.")));
	assert.match(summarized, /^Brief der Stadtwerke[\s\S]*Last question: Und der Termin\?\nLast answer: Am Montag um 9\.$/);
	const long = context.handoverFrom(lines(user("x".repeat(5000)), assistant("y".repeat(5000))));
	assert.ok(long.length <= context.HANDOVER_CHARS, `${long.length}`);
	assert.ok(context.handoverFrom("not json\n" + lines(user("ok"))), "broken lines are skipped");
});

test("context: previous session only if recent, never the current one", async () => {
	const dir = join(root, "sessions");
	await mkdir(dir, { recursive: true });
	const old = join(dir, "1_old.jsonl"), recent = join(dir, "2_recent.jsonl"), current = join(dir, "3_current.jsonl");
	for (const f of [old, recent, current]) await writeFile(f, "{}\n");
	const now = Date.now();
	await utimes(old, new Date(now - 13 * 3_600_000), new Date(now - 13 * 3_600_000));
	await utimes(recent, new Date(now - 3_600_000), new Date(now - 3_600_000));
	await utimes(current, new Date(now), new Date(now));
	assert.equal(await context.previousSession(dir, current, now), recent);
	await utimes(recent, new Date(now - 14 * 3_600_000), new Date(now - 14 * 3_600_000));
	assert.equal(await context.previousSession(dir, current, now), undefined, "older than 12 hours: no handover");
	assert.equal(await context.previousSession(join(root, "missing"), undefined, now), undefined);
});

test("context: handover only in a fresh session, fixed for the session", async () => {
	const dir = join(root, "handover");
	await mkdir(dir, { recursive: true });
	const before = join(dir, "1_before.jsonl"), now = join(dir, "2_now.jsonl");
	await writeFile(before, JSON.stringify({ type: "message", message: { role: "user", content: "Rechnung vom Klempner?" } }) + "\n");
	const pi = standIn();
	context.default(pi);
	let entries = [];
	const ctx = { sessionManager: { getSessionDir: () => dir, getSessionFile: () => now, getEntries: () => entries } };
	const turn = async () => { const event = { systemPromptOptions: { sections: {} } }; await pi.emit("before_agent_start", event, ctx); return event.systemPromptOptions.sections; };
	await pi.emit("session_start", { reason: "startup" }, ctx);
	const first = await turn();
	assert.match(first.earlier, /previous conversation[\s\S]*Last question: Rechnung vom Klempner\?/);
	await writeFile(before, JSON.stringify({ type: "message", message: { role: "user", content: "anders" } }) + "\n");
	assert.equal((await turn()).earlier, first.earlier, "fixed for the session");
	entries = [{ type: "message", message: { role: "user", content: "schon da" } }];
	await pi.emit("session_start", { reason: "startup" }, ctx);
	assert.equal((await turn()).earlier, undefined, "a resumed conversation needs no handover");
});

test("context: compacts after a quiet pause when at least 60 % full, not while busy, not when aborted", async () => {
	process.env.PIPPA_COMPACT_IDLE_MS = "10";
	const wait = () => new Promise((done) => setTimeout(done, 40));
	const run = async ({ tokens, idle = true, pending = false, aborted = false, interrupt = false }) => {
		const pi = standIn();
		context.default(pi);
		const calls = [];
		const ctx = { isIdle: () => idle, hasPendingMessages: () => pending, getContextUsage: () => ({ tokens, contextWindow: 16384, percent: null }),
			compact: (options) => calls.push(options) };
		await pi.emit("agent_settled", { aborted }, ctx);
		if (interrupt) await pi.emit("agent_start", {}, ctx);
		await wait();
		return calls;
	};
	const calls = await run({ tokens: 10_000 });
	assert.equal(calls.length, 1);
	assert.match(calls[0].customInstructions, /everyday helper conversation/);
	assert.equal((await run({ tokens: 9_000 })).length, 0, "below 60 %");
	assert.equal((await run({ tokens: null })).length, 0, "unknown size");
	assert.equal((await run({ tokens: 12_000, idle: false })).length, 0, "Pi still busy");
	assert.equal((await run({ tokens: 12_000, pending: true })).length, 0, "queued message");
	assert.equal((await run({ tokens: 12_000, aborted: true })).length, 0, "the person pressed Stop");
	assert.equal((await run({ tokens: 12_000, interrupt: true })).length, 0, "the person asked again meanwhile");
	delete process.env.PIPPA_COMPACT_IDLE_MS;
});

test("extension without PIPPA_MEMORY_FILE (trial runs): facts stay in the process, no file is touched", async () => {
	delete process.env.PIPPA_MEMORY_FILE;
	const pi = standIn();
	memory.default(pi);
	await pi.tools.remember.execute("t1", { add: "Lives in Köln" });
	const event = { systemPromptOptions: { sections: {} } };
	await pi.emit("session_start", {}, {});
	await pi.emit("before_agent_start", event, {});
	assert.match(event.systemPromptOptions.sections.memory, /Lives in Köln/);
});
