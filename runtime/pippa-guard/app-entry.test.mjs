// Pippa's calendar, reminder and mail-draft tools on her own MCP server. They change something on the Mac but do not
// leave it: `undo-first` does not ask, `ask-all` asks; the receipt (name, state, undo entry) comes from the server and
// the guard takes it over. Same-named foreign tools keep asking.
//
//   node --experimental-strip-types --test runtime/pippa-guard/app-entry.test.mjs
import assert from "node:assert/strict";
import { mkdir, mkdtemp } from "node:fs/promises";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const here = fileURLToPath(new URL(".", import.meta.url));
await mkdir(join(here, "../../.build"), { recursive: true });
const root = await mkdtemp(join(here, "../../.build/pippa-guard-app-entry-"));
const undoRoot = join(root, "undo");
process.env.PIPPA_UNDO_DIR = undoRoot;
const { default: guard, RECEIPT_TYPE, ALLOW, ALLOW_FOR_TASK, DENY, trustedSource, describeAppEntry } = await import("./pippa-guard.ts");
const { appEntry, serverReceipt, APP_ENTRIES } = await import("./self-asking.ts");
const { POLICIES } = await import("./policy.ts");

const writer = { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false };
const mcp = (server, name, annotations = writer, source = "builtin") => ({
	name: `mcp__${server}__${name}`, annotations,
	sourceInfo: { path: source === "builtin" ? "builtin:mcp" : "/person/extensions/x.ts", source },
});
const pippa = new Set(["pippa"]);
const tools = [mcp("pippa", "calendar_add"), mcp("pippa", "reminder_add"), mcp("pippa", "mail_draft"), mcp("fremd", "calendar_add")];

test("appEntry: only Pippa's server, only these three, only with the hints 'changes, reversible, stays on the Mac'", () => {
	assert.deepEqual(APP_ENTRIES, { calendar_add: "calendarAdd", reminder_add: "reminderAdd", mail_draft: "mailDraft" });
	assert.equal(appEntry("mcp__pippa__calendar_add", mcp("pippa", "calendar_add"), pippa, trustedSource), "calendarAdd");
	assert.equal(appEntry("mcp__pippa__mail_draft", mcp("pippa", "mail_draft"), pippa, trustedSource), "mailDraft");
	assert.equal(appEntry("mcp__fremd__calendar_add", mcp("fremd", "calendar_add"), pippa, trustedSource), undefined, "fremder Server");
	assert.equal(appEntry("mcp__pippa__calendar_add", mcp("pippa", "calendar_add", writer, "auto"), pippa, trustedSource), undefined, "person's extension");
	for (const hint of [{ readOnlyHint: true }, { destructiveHint: true }, { openWorldHint: true }, { openWorldHint: undefined }]) {
		assert.equal(appEntry("mcp__pippa__calendar_add", mcp("pippa", "calendar_add", { ...writer, ...hint }), pippa, trustedSource), undefined, JSON.stringify(hint));
	}
	assert.equal(appEntry("mcp__pippa__mail_send", mcp("pippa", "mail_send"), pippa, trustedSource), undefined, "there is no send tool");
	assert.equal(appEntry("mcp__pippa__calendar_add", undefined, pippa, trustedSource), undefined, "unbekannt: fragen");
});

test("presets: appEntry like file changes (undo-first free, ask-all asks)", () => {
	assert.equal(POLICIES["undo-first"].rules.appEntry, "allow");
	assert.equal(POLICIES["ask-all"].rules.appEntry, "ask");
});

function load(policy, answer = DENY) {
	const handlers = {};
	const entries = [];
	const asked = [];
	process.env.PIPPA_GUARD_POLICY = policy;
	guard({
		on: (name, handler) => { handlers[name] = handler; },
		appendEntry: (type, data) => { assert.equal(type, RECEIPT_TYPE); entries.push(data); },
		getAllTools: () => tools,
	});
	const ctx = { cwd: root, hasUI: true, ui: {
		confirm: async (_title, message) => { asked.push(message); return answer === ALLOW; },
		select: async (title, options) => { asked.push(title); assert.deepEqual(options, [ALLOW, ALLOW_FOR_TASK, DENY]); return answer; },
	} };
	let n = 0;
	return {
		entries, asked,
		call: async (toolName, input) => {
			const toolCallId = `c${++n}`;
			return { result: await handlers.tool_call({ toolName, input, toolCallId }, ctx), toolCallId };
		},
		/** Like Pi 1.0.4: the MCP result without `_meta` is under `structuredContent`, the server's own once more inside it. */
		result: (toolName, toolCallId, { isError = false, receipt, text = "{}" } = {}) =>
			handlers.tool_result({ toolName, toolCallId, isError, input: {}, content: [{ type: "text", text }],
				details: { server: "pippa", tool: toolName.split("__")[2] },
				structuredContent: { content: [{ type: "text", text }], ...(receipt ? { structuredContent: { pippaReceipt: receipt } } : {}), isError } }, ctx),
	};
}

test("undo-first: event without a question; receipt with name and undo entry from the server", async () => {
	const g = load("undo-first");
	const { result, toolCallId } = await g.call("mcp__pippa__calendar_add", { title: "Zahnarzt", date: "thursday", time: "09:00" });
	assert.equal(result, undefined);
	assert.equal(g.asked.length, 0);
	assert.equal(g.entries.length, 0, "no receipt before the result");
	const undo = join(undoRoot, "2026-10-07T19-00-00Z-calendar_add-abcd1234");
	await g.result("mcp__pippa__calendar_add", toolCallId, { receipt: { action: "calendarAdd", outcome: "done", name: "Do., 8. Okt., 09:00 – Zahnarzt", undo, restorable: true } });
	const [entry] = g.entries;
	assert.deepEqual([entry.outcome, entry.action, entry.name, entry.undo, entry.restorable, entry.category, entry.asked],
		["done", "calendarAdd", "Do., 8. Okt., 09:00 – Zahnarzt", undo, true, "appEntry", false]);
});

test("undo entry outside Pippa's folder is not taken over", async () => {
	const g = load("undo-first");
	const { toolCallId } = await g.call("mcp__pippa__reminder_add", { title: "Müll" });
	await g.result("mcp__pippa__reminder_add", toolCallId, { receipt: { action: "reminderAdd", outcome: "done", name: "Müll", undo: "/etc/x", restorable: true } });
	assert.equal(g.entries[0].undo, undefined);
	assert.equal(g.entries[0].restorable, false);
	assert.equal(serverReceipt({ structuredContent: { pippaReceipt: { outcome: "done", undo: `${undoRoot}/../x`, restorable: true } } }, undoRoot).restorable, false);
});

test("mail draft: state 'unclear' and reason from the server; never guess 'done'", async () => {
	const g = load("undo-first");
	const { toolCallId } = await g.call("mcp__pippa__mail_draft", { body: "Passt.", reply_to: "/tmp/x.eml" });
	await g.result("mcp__pippa__mail_draft", toolCallId, { receipt: { action: "mailDraft", outcome: "unclear", name: "„Re: Termin“", restorable: false, reason: "unconfirmed" } });
	assert.deepEqual([g.entries[0].outcome, g.entries[0].action, g.entries[0].reason, g.entries[0].restorable], ["unclear", "mailDraft", "unconfirmed", false]);
});

test("invalid arguments (error without server receipt): failed with text; slot taken: failed with reason", async () => {
	const g = load("undo-first");
	const first = await g.call("mcp__pippa__calendar_add", { title: "X", date: "gestern" });
	await g.result("mcp__pippa__calendar_add", first.toolCallId, { isError: true, text: "{\"status\":\"invalid_arguments\"}" });
	assert.deepEqual([g.entries[0].outcome, g.entries[0].name], ["failed", "X"]);
	assert.match(g.entries[0].error, /invalid_arguments/);
	const second = await g.call("mcp__pippa__calendar_add", { title: "Zahnarzt", date: "thursday", time: "09:00", if_free: true });
	await g.result("mcp__pippa__calendar_add", second.toolCallId, { receipt: { action: "calendarAdd", outcome: "failed", name: "Do., 8. Okt., 09:00 – Zahnarzt", restorable: false, reason: "busy" } });
	assert.deepEqual([g.entries[1].outcome, g.entries[1].reason], ["failed", "busy"]);
});

test("ask-all fragt in Worten; abgelehnt → nichts passiert, Quittung „declined“", async () => {
	const g = load("ask-all", false);
	const { result } = await g.call("mcp__pippa__calendar_add", { title: "Zahnarzt", date: "thursday", time: "09:00" });
	assert.equal(result.block, true);
	assert.match(g.asked[0], /Termin „Zahnarzt“ eintragen \(thursday, 09:00\)\. Das lässt sich rückgängig machen/);
	assert.deepEqual([g.entries[0].outcome, g.entries[0].action, g.entries[0].category, g.entries[0].asked], ["declined", "calendarAdd", "appEntry", true]);
	assert.match(describeAppEntry("mailDraft", { reply_to: "selected", body: "x" }).sentence, /Antwort als Entwurf anlegen\. Gesendet wird nichts/);
});

test("same-named foreign tool asks even in undo-first", async () => {
	const g = load("undo-first", DENY);
	const { result } = await g.call("mcp__fremd__calendar_add", { title: "x" });
	assert.equal(result.block, true);
	assert.equal(g.asked.length, 1);
	assert.deepEqual([g.entries[0].action, g.entries[0].category], ["tool", "tool"]);
});
