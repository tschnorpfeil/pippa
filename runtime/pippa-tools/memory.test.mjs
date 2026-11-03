// Pippa's memory (pippa-memory.ts) without Pi and without a model: a stand-in
// `pi` takes the handlers and tools, the tests call them like Pi itself.
//
//   node --experimental-strip-types --test runtime/pippa-tools/memory.test.mjs
import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const here = fileURLToPath(new URL(".", import.meta.url));
await mkdir(join(here, "../../.build"), { recursive: true });
const root = await mkdtemp(join(here, "../../.build/pippa-memory-test-"));
const memory = await import("./pippa-memory.ts");

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
	for (const fact of ["IBAN DE89 3704 0044 0532 0130 00", "iban nl91 abna 0417 1643 00", "Konto 1234567890", "Steuer-ID 12 345 678 901",
		"Steuer ID ABC", "Ausweisnummer T22000129", "Karte 4111-1111-1111-1111", "Telefon 0221 1234567", "Passwort für Mail ist sonne",
		"PIN 1234", "Die TAN kommt per SMS", "API key sk-abc", "secret_key=xyz", "Bearer token abc", "seed phrase witch collapse", "recovery code 99"]) {
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
	const { stat } = await import("node:fs/promises");
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
	const inoBefore = (await stat(file)).ino;
	await pi.tools.remember.execute("t1-dup", { add: "landlord: ms kraus" });
	assert.equal((await stat(file)).ino, inoBefore, "duplicate fact does not rewrite the file");
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

