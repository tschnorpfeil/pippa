// Online lookup via Pippa's MCP server asks exactly once, through Pippa's own card (WebAccessGate), not additionally in
// the guard. Everything else stays as it was: same-named foreign tools ask, Pippa's `read_document` reads freely.
//
//   node --experimental-strip-types --test runtime/pippa-guard/self-asking.test.mjs
import assert from "node:assert/strict";
import { mkdir, mkdtemp } from "node:fs/promises";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const here = fileURLToPath(new URL(".", import.meta.url));
await mkdir(join(here, "../../.build"), { recursive: true });
const root = await mkdtemp(join(here, "../../.build/pippa-guard-self-asking-"));
process.env.PIPPA_UNDO_DIR = join(root, "undo");
const { default: guard, RECEIPT_TYPE, trustedSource } = await import("./pippa-guard.ts");
const { asksItself, SELF_ASKING } = await import("./self-asking.ts");

const online = { readOnlyHint: true, destructiveHint: false, idempotentHint: false, openWorldHint: true };
const reader = { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false };
const mcp = (server, name, annotations, source = "builtin") => ({ name: `mcp__${server}__${name}`, annotations, sourceInfo: { path: source === "builtin" ? "builtin:mcp" : "/person/extensions/x.ts", source } });
const pippa = new Set(["pippa"]);

test("only Pippa's server, only web_search/read_web_page, only without changes on the Mac", () => {
	assert.deepEqual([...SELF_ASKING], ["web_search", "read_web_page"]);
	assert.equal(asksItself("mcp__pippa__web_search", mcp("pippa", "web_search", online), pippa, trustedSource), true);
	assert.equal(asksItself("mcp__pippa__read_web_page", mcp("pippa", "read_web_page", online), pippa, trustedSource), true);
	assert.equal(asksItself("mcp__other__web_search", mcp("other", "web_search", online), pippa, trustedSource), false, "fremder Server");
	assert.equal(asksItself("mcp__pippa__web_search", mcp("pippa", "web_search", online, "auto"), pippa, trustedSource), false, "person's extension");
	assert.equal(asksItself("mcp__pippa__web_search", mcp("pippa", "web_search", { ...online, readOnlyHint: false }), pippa, trustedSource), false);
	assert.equal(asksItself("mcp__pippa__web_search", mcp("pippa", "web_search", { ...online, destructiveHint: true }), pippa, trustedSource), false);
	assert.equal(asksItself("mcp__pippa__mail_send", mcp("pippa", "mail_send", online), pippa, trustedSource), false, "only the two names");
	assert.equal(asksItself("web_search", { name: "web_search", annotations: online, sourceInfo: { source: "auto" } }, pippa, trustedSource), false);
	assert.equal(asksItself("mcp__pippa__web_search", undefined, pippa, trustedSource), false, "unbekannt: fragen");
});

function load(tools) {
	const handlers = {};
	const entries = [];
	const asked = [];
	process.env.PIPPA_GUARD_POLICY = "undo-first";
	guard({
		on: (name, handler) => { handlers[name] = handler; },
		appendEntry: (type, data) => { assert.equal(type, RECEIPT_TYPE); entries.push(data); },
		getAllTools: () => tools,
	});
	const ctx = { cwd: root, hasUI: true, ui: {
		confirm: async (_title, message) => { asked.push(message); return false; },
		select: async (title) => { asked.push(title); return "Nicht erlauben"; },
	} };
	return { entries, asked, call: (toolName, input) => handlers.tool_call({ toolName, input, toolCallId: "c1" }, ctx) };
}

test("in the guard: Pippa's web_search without a second question, read_document free, foreign web_search asks", async () => {
	const tools = [mcp("pippa", "web_search", online), mcp("pippa", "read_web_page", online), mcp("pippa", "read_document", reader),
		mcp("fremd", "web_search", online)];
	const g = load(tools);
	assert.equal(await g.call("mcp__pippa__web_search", { query: "Wetter morgen Köln" }), undefined);
	assert.equal(await g.call("mcp__pippa__read_web_page", { url: "https://example.org/a" }), undefined);
	assert.equal(await g.call("mcp__pippa__read_document", { path: "/tmp/x.pdf" }), undefined);
	assert.equal(g.asked.length, 0);
	assert.equal(g.entries.length, 0, "the receipt comes from WebAccessGate.records, not from the guard");
	const foreign = await g.call("mcp__fremd__web_search", { query: "x" });
	assert.equal(foreign.block, true);
	assert.equal(g.asked.length, 1);
	assert.equal(g.entries[0].outcome, "declined");
});
