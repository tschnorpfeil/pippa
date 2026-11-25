// context-guard.mjs on its own, then inside a real Pi with a scripted fake oMLX. The real-Pi part is skipped unless a Pi
// CLI is named, as in real-pi.test.mjs:
//
//   node --experimental-strip-types --test runtime/pippa-local-server/test/context-guard.test.mjs
//   PIPPA_PI_CLI=<release>/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js \
//   PIPPA_PI_NODE=<node 22> node --experimental-strip-types --test runtime/pippa-local-server/test/context-guard.test.mjs
//
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { randomUUID } from "node:crypto";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import {
	buildLengthDeadlockRescue, capTerminalToolResult, registerLocalContextGuard, resultCharLimit, stubLargeToolCalls, writeArgLimit,
} from "../context-guard.mjs";

const here = fileURLToPath(new URL(".", import.meta.url));
const local = { provider: "pippa-local", id: "m", contextWindow: 32768 };

// ---------------------------------------------------------------------------------------------------------------------
// Unit tests

test("writeArgLimit: an eighth of the window", () => {
	assert.equal(writeArgLimit(32768), 4096);
	assert.equal(writeArgLimit(16384), 2048);
	assert.equal(writeArgLimit(undefined), 4096);
});

test("stubLargeToolCalls stubs successful big write/edit calls and leaves everything else as it was", () => {
	const big = "x".repeat(5000);
	const content = [
		{ type: "thinking", thinking: "plan" },
		{ type: "text", text: "Saving." },
		{ type: "toolCall", id: "w1", name: "write", arguments: { path: "page.html", content: big } },
		{ type: "toolCall", id: "w2", name: "write", arguments: { path: "small.txt", content: "tiny" } },
		{ type: "toolCall", id: "w3", name: "write", arguments: { path: "failed.html", content: big } },
		{ type: "toolCall", id: "e1", name: "edit", arguments: { path: "a.js", oldText: "a", newText: big } },
		{ type: "toolCall", id: "e2", name: "edit", arguments: { path: "b.js", edits: [{ oldText: big, newText: "y".repeat(300) }, { oldText: "k", newText: "l" }] } },
		{ type: "toolCall", id: "b1", name: "bash", arguments: { command: big } },
	];
	const results = ["w1", "w2", "e1", "e2", "b1"].map((id) => ({ toolCallId: id, isError: false })).concat({ toolCallId: "w3", isError: true });
	const out = stubLargeToolCalls(content, results, 4096);
	assert.ok(out);
	assert.equal(out.length, content.length);
	assert.deepEqual(out.map((b) => [b.type, b.id, b.name]), content.map((b) => [b.type, b.id, b.name]));
	assert.deepEqual(out[0], content[0]);
	assert.deepEqual(out[1], content[1]);
	assert.equal(out[2].arguments.path, "page.html");
	assert.match(out[2].arguments.content, /^\[Content of 5000 characters for page\.html omitted/);
	assert.deepEqual(out[3], content[3], "small write untouched");
	assert.deepEqual(out[4], content[4], "failed write untouched");
	assert.equal(out[5].arguments.oldText, "a");
	assert.match(out[5].arguments.newText, /^\[newText of 5000 characters for a\.js omitted/);
	assert.match(out[6].arguments.edits[0].oldText, /^\[oldText of 5000 characters/);
	assert.match(out[6].arguments.edits[0].newText, /^\[newText of 300 characters/);
	assert.deepEqual(out[6].arguments.edits[1], { oldText: "k", newText: "l" });
	assert.deepEqual(out[7], content[7], "bash untouched");
	assert.equal(content[2].arguments.content, big, "input not mutated");
	// Nothing big, a missing result, only failures, or many small edits (each <= 256 chars): nothing to change.
	assert.equal(stubLargeToolCalls(content.slice(0, 4), [{ toolCallId: "w2", isError: false }], 4096), undefined);
	assert.equal(stubLargeToolCalls([content[2]], [], 4096), undefined);
	assert.equal(stubLargeToolCalls([content[2]], [{ toolCallId: "w1", isError: true }], 4096), undefined);
	const manySmallEdits = {
		type: "toolCall", id: "e3", name: "edit",
		arguments: { path: "c.js", edits: Array.from({ length: 20 }, (_, i) => ({ oldText: `a${i}`.padEnd(150, "x"), newText: `b${i}`.padEnd(150, "y") })) },
	};
	assert.equal(stubLargeToolCalls([manySmallEdits], [{ toolCallId: "e3", isError: false }], 4096), undefined, "many tiny edits produce no no-op context_edit");
});

test("capTerminalToolResult: bash keeps the end, read whole lines with offset, others the start; mcp and short skipped", () => {
	const limit = resultCharLimit(32768);
	assert.equal(limit, 16000);
	assert.equal(resultCharLimit(16384), 8192);
	const long = "a".repeat(10) + "b".repeat(30000) + "END";
	const bash = capTerminalToolResult("bash", [{ type: "text", text: long }], 32768);
	assert.match(bash[0].text, /^\[Only the last 16000 of 30013 characters/);
	assert.ok(bash[0].text.endsWith("END"));
	const lines = Array.from({ length: 3000 }, (_, i) => `line ${i + 1} ${"z".repeat(10)}`).join("\n");
	const read = capTerminalToolResult("read", [{ type: "text", text: lines }], 32768, { path: "f", offset: 101 });
	const text = read[0].text;
	const body = text.slice(0, text.indexOf("\n[Only lines"));
	const shown = body.split("\n");
	assert.ok(body.length <= limit);
	assert.equal(shown[0], "line 1 zzzzzzzzzz");
	assert.match(shown.at(-1), /^line \d+ z{10}$/, "cut after a whole line");
	assert.match(text, new RegExp(`\\[Only lines 101-${100 + shown.length} are shown.*offset=${101 + shown.length} to read on\\.\\]$`));
	const other = capTerminalToolResult("grep", [{ type: "text", text: long }, { type: "image", data: "x", mimeType: "image/png" }], 32768);
	assert.ok(other[0].text.startsWith("aaaaaaaaaab"));
	assert.match(other[0].text, /\[Only the first 16000 of 30013 characters/);
	assert.equal(other[1].type, "image");
	assert.equal(capTerminalToolResult("mcp__pippa__search", [{ type: "text", text: long }], 32768), undefined);
	assert.equal(capTerminalToolResult("bash", [{ type: "text", text: "short" }], 32768), undefined);
});

// A branch as SessionManager.getBranch() returns it.
let clock = Date.parse("2026-11-25T10:00:00Z");
function entry(type, fields) {
	clock += 1000;
	return { type, id: randomUUID().slice(0, 8), parentId: null, timestamp: new Date(clock).toISOString(), ...fields };
}
const user = (text) => entry("message", { message: { role: "user", content: [{ type: "text", text }], timestamp: clock } });
const assistant = (content, stopReason, usage = { input: 100, output: 10, cacheRead: 0, cacheWrite: 0, totalTokens: 110 }) =>
	entry("message", { message: { role: "assistant", content, stopReason, usage, provider: "pippa-local", model: "m", api: "openai-completions", timestamp: clock } });
const toolResult = (toolCallId, toolName) =>
	entry("message", { message: { role: "toolResult", toolCallId, toolName, content: [{ type: "text", text: "ok" }], isError: false, timestamp: clock } });
const omit = (target) => entry("context_edit", { targetId: target.id, replacement: null });

function stuckBranch(tail) {
	const u1 = user("Build page.html");
	const a1 = assistant([{ type: "toolCall", id: "c1", name: "write", arguments: { path: "page.html", content: "x".repeat(22000) } }], "toolUse");
	const t1 = toolResult("c1", "write");
	const c1 = entry("compaction", { summary: "The user wants a web page.", firstKeptEntryId: a1.id, tokensBefore: 20000 });
	return [u1, a1, t1, c1, ...tail];
}

test("buildLengthDeadlockRescue: keeps a short trailing prompt, else restarts at the summary; ignores normal or compacted branches", () => {
	const u2 = user("Add a footer");
	const cut = assistant([{ type: "text", text: "<footer" }], "length");
	const branch = stuckBranch([u2, cut, omit(cut)]);
	const rescue = buildLengthDeadlockRescue(branch);
	assert.equal(rescue.type, "compaction");
	assert.equal(rescue.firstKeptEntryId, u2.id);
	assert.match(rescue.summary, /cut off/);
	assert.match(rescue.summary, /The user wants a web page\./);
	assert.match(rescue.summary, /- page\.html/);
	assert.doesNotMatch(rescue.summary, /Add a footer/, "the kept prompt is not repeated");

	// Ends on a tool result: keeping it would orphan it from its call, so nothing is kept, and the last tool result is noted.
	const a2 = assistant([{ type: "toolCall", id: "c2", name: "read", arguments: { path: "page.html" } }], "toolUse");
	const t2 = toolResult("c2", "read");
	const cut2 = assistant([{ type: "text", text: "<foo" }], "length");
	const afterTool = buildLengthDeadlockRescue(stuckBranch([u2, a2, t2, cut2, omit(cut2)]));
	assert.equal(afterTool.firstKeptEntryId, null);
	assert.match(afterTool.summary, /- Add a footer/);
	assert.match(afterTool.summary, /Last tool result \(read\):\nok/);

	// An oversized prompt is not kept either; it is summarized (clipped).
	const huge = user("y".repeat(9000));
	const cut3 = assistant([{ type: "text", text: "<" }], "length");
	const big = buildLengthDeadlockRescue(stuckBranch([huge, cut3, omit(cut3)]));
	assert.equal(big.firstKeptEntryId, null);
	assert.ok(big.summary.length < 6000);

	// Normal stop, a length stop Pi did not omit, or an omission already followed by a compaction: no rescue.
	assert.equal(buildLengthDeadlockRescue(stuckBranch([u2, assistant([{ type: "text", text: "done" }], "stop")])), undefined);
	const kept = assistant([{ type: "text", text: "<f" }], "length");
	assert.equal(buildLengthDeadlockRescue(stuckBranch([u2, kept])), undefined);
	const cut4 = assistant([{ type: "text", text: "<f" }], "length");
	assert.equal(buildLengthDeadlockRescue(stuckBranch([u2, cut4, omit(cut4), entry("compaction", { summary: "s", firstKeptEntryId: u2.id })])), undefined);
	assert.equal(buildLengthDeadlockRescue([]), undefined);
});

function loadGuard(options) {
	const handlers = {};
	registerLocalContextGuard({ on: (name, handler) => { handlers[name] = handler; } }, options);
	return handlers;
}

test("registerLocalContextGuard: hooks, at most one rescue per run, only pippa-local", () => {
	assert.deepEqual(Object.keys(loadGuard({ capToolResults: false })).sort(), ["agent_before_settle", "agent_settled", "turn_end"]);
	const handlers = loadGuard({ capToolResults: true });
	assert.deepEqual(Object.keys(handlers).sort(), ["agent_before_settle", "agent_settled", "tool_result", "turn_end"]);

	const u2 = user("Add a footer");
	const cut = assistant([{ type: "text", text: "<footer" }], "length");
	const branch = stuckBranch([u2, cut, omit(cut)]);
	const ctx = (model) => ({ model, sessionManager: { getBranch: () => branch } });
	const settle = (model, entries = [], extra = {}) =>
		handlers.agent_before_settle({ type: "agent_before_settle", entries, continue: false, outcome: "completed", context: { canContinue: true }, ...extra }, ctx(model));

	assert.equal(settle({ ...local, provider: "openai" }), undefined, "other providers untouched");
	assert.equal(settle(local, [], { outcome: "aborted" }), undefined, "aborted runs are never continued");
	assert.equal(settle(local, [], { context: { canContinue: false } }), undefined, "non-continuable context stays settled");
	const other = { type: "custom", customType: "x" };
	const first = settle(local, [other]);
	assert.equal(first.continue, true);
	assert.deepEqual(first.entries[0], other, "earlier drafts kept");
	assert.equal(first.entries[1].type, "compaction");
	assert.equal(settle(local), undefined, "only once per run");
	handlers.agent_settled({ type: "agent_settled", aborted: false }, ctx(local));
	assert.equal(settle(local).continue, true, "agent_settled allows the next run");
	handlers.agent_settled({ type: "agent_settled", aborted: false }, ctx(local));
	assert.equal(settle(local, [{ type: "compaction", summary: "s", firstKeptEntryId: null }]), undefined, "a second copy adds no second compaction");

	// turn_end: a stub for pippa-local, nothing for others or failed calls.
	const call = { type: "toolCall", id: "w1", name: "write", arguments: { path: "p.html", content: "h".repeat(20000) } };
	const turn = (model, isError = false, entries = []) => handlers.turn_end({
		type: "turn_end", turnIndex: 0, message: { role: "assistant", content: [call], stopReason: "toolUse" }, messageEntryId: "abc",
		toolResults: [{ role: "toolResult", toolCallId: "w1", toolName: "write", isError }], toolResultEntryIds: ["def"], entries, continue: false,
	}, { model });
	const edited = turn(local);
	assert.equal(edited.entries.length, 1);
	assert.equal(edited.entries[0].type, "context_edit");
	assert.equal(edited.entries[0].targetId, "abc");
	assert.match(edited.entries[0].replacement.content[0].arguments.content, /^\[Content of 20000 characters/);
	assert.equal(edited.continue, undefined, "turn_end never forces a continuation");
	assert.equal(turn({ ...local, provider: "anthropic" }), undefined);
	assert.equal(turn(local, true), undefined);
	assert.equal(turn(local, false, edited.entries), undefined, "a second copy does not edit twice");

	// tool_result: capped for pippa-local, never for a script's own calls or other providers.
	const result = (model, extra = {}) => handlers.tool_result({ type: "tool_result", toolName: "bash", toolCallId: "t", input: {}, content: [{ type: "text", text: "q".repeat(40000) }], isError: false, ...extra }, { model });
	assert.match(result(local).content[0].text, /^\[Only the last 16000/);
	assert.equal(result(local, { parentToolCallId: "p" }), undefined);
	assert.equal(result({ ...local, provider: "openai" }), undefined);
});

// ---------------------------------------------------------------------------------------------------------------------
// Real Pi with a scripted fake oMLX (in this process): requests are recorded, answers come from a queue.

const payload = process.env.PIPPA_PI_PAYLOAD;
const cli = process.env.PIPPA_PI_CLI
	|| (payload ? join(payload, "release/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js") : undefined);
const node = process.env.PIPPA_PI_NODE || (payload && existsSync(join(payload, "bin/node")) ? join(payload, "bin/node") : process.execPath);
const skip = !cli && "PIPPA_PI_CLI not set";
const modelID = "ornith-1.5-9b-mlx-4bit";

const chunk = (delta, finish = null, usage) => `data: ${JSON.stringify({ id: "x", object: "chat.completion.chunk", created: 0, model: modelID,
	choices: [{ index: 0, delta, finish_reason: finish }], ...(usage ? { usage } : {}) })}\n\n`;
const usageOf = (prompt, completion) => ({ prompt_tokens: prompt, completion_tokens: completion, total_tokens: prompt + completion });

async function fakeOMLX(key, answers) {
	const requests = [];
	const server = createServer((req, res) => {
		if (req.headers.authorization !== `Bearer ${key}`) return res.writeHead(401).end();
		if (req.url === "/health") return res.writeHead(200, { "Content-Type": "application/json" }).end('{"status":"healthy"}');
		if (req.method === "POST" && req.url === "/v1/chat/completions") {
			let raw = "";
			req.on("data", (d) => { raw += d; });
			req.on("end", () => {
				const body = JSON.parse(raw);
				requests.push({ body, size: raw.length });
				const answer = answers[requests.length - 1] ?? (chunk({ role: "assistant", content: "unexpected" }) + chunk({}, "stop", usageOf(100, 1)));
				res.writeHead(200, { "Content-Type": "text/event-stream" }).end(answer + "data: [DONE]\n\n");
			});
			return;
		}
		res.writeHead(404).end();
	});
	await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
	return { requests, port: server.address().port, close: () => new Promise((resolve) => server.close(resolve)) };
}

/** Fake HOME with Pippa's terminal extension (the shipped files), its config and a 32k pippa-local model. */
function setupHome(port, key) {
	mkdirSync(join(here, "../../../.build"), { recursive: true });
	const root = mkdtempSync(join(here, "../../../.build/pippa-context-guard-realpi-"));
	const home = join(root, "home");
	const support = join(home, "Library/Application Support/Pippa");
	const extensionDir = join(home, ".pi/agent/extensions/pippa-local-server");
	mkdirSync(support, { recursive: true });
	mkdirSync(extensionDir, { recursive: true });
	const shipped = JSON.parse(readFileSync(join(here, "../../../app/Packaging/runtime-files.json"), "utf8"))["pippa-local-server"];
	for (const f of shipped) copyFileSync(join(here, "..", f), join(extensionDir, f));
	const keyFile = join(support, "local-server-key");
	writeFileSync(keyFile, key + "\n", { mode: 0o600 });
	const base = join(support, "omlx");
	mkdirSync(base, { recursive: true });
	writeFileSync(join(support, "pippa-local-server.json"), JSON.stringify({
		schemaVersion: 2, provider: "pippa-local", port, binary: "/usr/bin/false", keyFile, modelID, logFile: join(support, "local-server.log"),
		arguments: ["-c", "from omlx.cli import main; main()", "serve", "--base-path", base, "--headless"], environment: { PATH: "/usr/bin:/bin" },
	}));
	writeFileSync(join(home, ".pi/agent/models.json"), JSON.stringify({ providers: { "pippa-local": {
		baseUrl: `http://127.0.0.1:${port}/v1`, api: "openai-completions", apiKey: `!/bin/cat '${keyFile}'`,
		models: [{ id: modelID, name: "Ornith 1.5 9B", contextWindow: 32768, maxTokens: 16384 }],
	} } }));
	const work = join(root, "work");
	mkdirSync(work);
	return { root, home, work };
}

function runPi({ home, work }, args) {
	const env = { HOME: home, PATH: "/usr/bin:/bin", PI_OFFLINE: "1", PI_SKIP_VERSION_CHECK: "1", PI_TELEMETRY: "0" };
	return new Promise((resolve) => {
		const child = execFile(node, [cli, "-p", "--provider", "pippa-local", "--model", modelID, "--no-context-files", "--no-skills", ...args],
			{ env, cwd: work, timeout: 60_000 }, (error, stdout, stderr) => resolve({ error, stdout, stderr }));
		child.stdin.end(); // `pi -p` reads piped stdin until EOF
	});
}

const maxTokens = (body) => body.max_completion_tokens ?? body.max_tokens;

test("real Pi: after a 20 KB write succeeds, the next request carries the stub, not the page", { skip }, async () => {
	const key = "k".repeat(64);
	const marker = "UNIQUE-HTML-MARKER";
	const html = `<!doctype html><html><body><!-- ${marker} -->${"<p>Lorem ipsum dolor sit amet.</p>\n".repeat(600)}</body></html>`;
	assert.ok(html.length >= 20_000);
	const answers = [
		chunk({ role: "assistant", tool_calls: [{ index: 0, id: "call_w1", type: "function", function: { name: "write", arguments: JSON.stringify({ path: "page.html", content: html }) } }] })
			+ chunk({}, "tool_calls", usageOf(3000, 6500)),
		chunk({ role: "assistant", content: "Saved page.html." }) + chunk({}, "stop", usageOf(3600, 8)),
	];
	const omlx = await fakeOMLX(key, answers);
	const setup = setupHome(omlx.port, key);
	try {
		const run = await runPi(setup, ["--no-session", "Build page.html"]);
		assert.equal(run.error, null, `stdout: ${run.stdout}\nstderr: ${run.stderr}`);
		assert.match(run.stdout, /Saved page\.html/);
		assert.equal(readFileSync(join(setup.work, "page.html"), "utf8"), html, "the file itself is whole");
		assert.equal(omlx.requests.length, 2);
		const [first, second] = omlx.requests;
		assert.ok(!JSON.stringify(first.body).includes(marker));
		const text = JSON.stringify(second.body);
		assert.ok(!text.includes(marker), "the page is not sent again");
		const call = second.body.messages.find((m) => m.role === "assistant" && m.tool_calls?.length)?.tool_calls[0];
		assert.equal(call.id, "call_w1");
		assert.equal(call.function.name, "write");
		const args = JSON.parse(call.function.arguments);
		assert.equal(args.path, "page.html");
		assert.match(args.content, /^\[Content of \d+ characters for page\.html omitted/);
		assert.ok(second.size < first.size + 3_000, `second request ${second.size} bytes vs first ${first.size}`);
		assert.ok(maxTokens(second.body) >= 8000, `max_tokens ${maxTokens(second.body)}`);
	} finally {
		await omlx.close();
		rmSync(setup.root, { recursive: true, force: true });
	}
});

test("real Pi: a stuck session (length stop, compaction finds nothing to cut) is rescued once and answers", { skip }, async () => {
	const key = "k".repeat(64);
	const answers = [
		chunk({ role: "assistant", content: "<footer class=" }) + chunk({}, "length", usageOf(27600, 1100)),
		chunk({ role: "assistant", content: "Footer added." }) + chunk({}, "stop", usageOf(1200, 5)),
	];
	const omlx = await fakeOMLX(key, answers);
	const setup = setupHome(omlx.port, key);
	try {
		// What a real stuck session looks like: an earlier compaction kept the whole tail, the 22 KB write included,
		// and the last answer's usage says the window is nearly full.
		const ms = Date.now() - 60_000;
		let t = 0;
		const at = () => ms + 1000 * ++t;
		const usage = (input, output) => ({ input, output, cacheRead: 0, cacheWrite: 0, totalTokens: input + output,
			cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } });
		const msg = (id, parentId, message) => ({ type: "message", id, parentId, timestamp: new Date(message.timestamp).toISOString(), message });
		const meta = { api: "openai-completions", provider: "pippa-local", model: modelID };
		const page = `<!doctype html><html><body>${"<div class=row>Isometric tile</div>\n".repeat(620)}</body></html>`;
		assert.ok(page.length >= 22_000);
		const entries = [
			{ type: "model_change", id: "e0000001", parentId: null, timestamp: new Date(at()).toISOString(), provider: "pippa-local", modelId: modelID },
			msg("e0000002", "e0000001", { role: "user", content: [{ type: "text", text: "Build page.html" }], timestamp: at() }),
			msg("e0000003", "e0000002", { role: "assistant", content: [{ type: "toolCall", id: "call_w1", name: "write", arguments: { path: "page.html", content: page } }],
				...meta, usage: usage(3000, 7000), stopReason: "toolUse", timestamp: at() }),
			msg("e0000004", "e0000003", { role: "toolResult", toolCallId: "call_w1", toolName: "write", content: [{ type: "text", text: `Successfully wrote ${page.length} bytes to page.html` }], isError: false, timestamp: at() }),
			{ type: "compaction", id: "e0000005", parentId: "e0000004", timestamp: new Date(at()).toISOString(), summary: "The user wants an isometric page.",
				firstKeptEntryId: "e0000003", tokensBefore: 20000, fromHook: false },
			msg("e0000006", "e0000005", { role: "assistant", content: [{ type: "text", text: "Saved page.html." }], ...meta, usage: usage(27400, 20), stopReason: "stop", timestamp: at() }),
		];
		const file = join(setup.root, "stuck.jsonl");
		const header = { type: "session", version: 3, id: randomUUID(), timestamp: new Date(ms).toISOString(), cwd: setup.work };
		writeFileSync(file, [header, ...entries].map((e) => JSON.stringify(e)).join("\n") + "\n");

		const run = await runPi(setup, ["--session", file, "Add a footer"]);
		assert.equal(run.error, null, `stdout: ${run.stdout}\nstderr: ${run.stderr}`);
		assert.match(run.stdout, /Footer added\./);
		assert.equal(omlx.requests.length, 2, `requests: ${omlx.requests.map((r) => maxTokens(r.body)).join(", ")}`);
		const [stuck, retry] = omlx.requests;
		assert.ok(maxTokens(stuck.body) < 1500, `first max_tokens ${maxTokens(stuck.body)}`);
		assert.ok(maxTokens(retry.body) >= 8000, `retry max_tokens ${maxTokens(retry.body)}`);
		assert.ok(!JSON.stringify(retry.body).includes("Isometric tile"), "the old page is gone");
		assert.ok(JSON.stringify(retry.body).includes("Add a footer"), "the prompt is kept");

		const saved = readFileSync(file, "utf8").trim().split("\n").map((l) => JSON.parse(l));
		const rescues = saved.filter((e) => e.type === "compaction" && e.fromHook === true);
		assert.equal(rescues.length, 1);
		const prompt = saved.find((e) => e.type === "message" && e.message.role === "user" && JSON.stringify(e.message.content).includes("Add a footer"));
		assert.equal(rescues[0].firstKeptEntryId, prompt.id);
		assert.match(rescues[0].summary, /cut off/);
	} finally {
		await omlx.close();
		rmSync(setup.root, { recursive: true, force: true });
	}
});

test("real Pi: after one rescue, a second uncompactable length stop in the same run does not rescue again", { skip }, async () => {
	const key = "k".repeat(64);
	// 1) Stuck session hits length -> rescued once (continue: true).
	// 2) Rescued continuation makes a tool call (resetting Pi's _overflowRecoveryAttempted) that returns a big uncompactable result.
	// 3) Next answer hits length again -> Pi omits it, prepareCompaction finds nothing to cut, and the guard must NOT rescue a second time in the same run.
	const answers = [
		chunk({ role: "assistant", content: "<footer" }) + chunk({}, "length", usageOf(27600, 1100)),
		chunk({ role: "assistant", tool_calls: [{ index: 0, id: "call_r1", type: "function", function: { name: "read", arguments: JSON.stringify({ path: "note.txt" }) } }] })
			+ chunk({}, "tool_calls", usageOf(1500, 30)),
		chunk({ role: "assistant", content: "Still cut" }) + chunk({}, "length", usageOf(27600, 1100)),
		chunk({ role: "assistant", content: "Must never be reached" }) + chunk({}, "stop", usageOf(1200, 5)),
	];
	const omlx = await fakeOMLX(key, answers);
	const setup = setupHome(omlx.port, key);
	try {
		writeFileSync(join(setup.work, "note.txt"), "small note\n");
		const ms = Date.now() - 60_000;
		let t = 0;
		const at = () => ms + 1000 * ++t;
		const usage = (input, output) => ({ input, output, cacheRead: 0, cacheWrite: 0, totalTokens: input + output,
			cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } });
		const msg = (id, parentId, message) => ({ type: "message", id, parentId, timestamp: new Date(message.timestamp).toISOString(), message });
		const meta = { api: "openai-completions", provider: "pippa-local", model: modelID };
		const page = `<!doctype html><html><body>${"<div class=row>Tile</div>\n".repeat(900)}</body></html>`;
		const entries = [
			{ type: "model_change", id: "e0000001", parentId: null, timestamp: new Date(at()).toISOString(), provider: "pippa-local", modelId: modelID },
			msg("e0000002", "e0000001", { role: "user", content: [{ type: "text", text: "Build page.html" }], timestamp: at() }),
			msg("e0000003", "e0000002", { role: "assistant", content: [{ type: "toolCall", id: "call_w1", name: "write", arguments: { path: "page.html", content: page } }],
				...meta, usage: usage(3000, 7000), stopReason: "toolUse", timestamp: at() }),
			msg("e0000004", "e0000003", { role: "toolResult", toolCallId: "call_w1", toolName: "write", content: [{ type: "text", text: "ok" }], isError: false, timestamp: at() }),
			{ type: "compaction", id: "e0000005", parentId: "e0000004", timestamp: new Date(at()).toISOString(), summary: "Prior.",
				firstKeptEntryId: "e0000003", tokensBefore: 20000, fromHook: false },
			msg("e0000006", "e0000005", { role: "assistant", content: [{ type: "text", text: "Saved." }], ...meta, usage: usage(27400, 20), stopReason: "stop", timestamp: at() }),
		];
		const file = join(setup.root, "double-stuck.jsonl");
		const header = { type: "session", version: 3, id: randomUUID(), timestamp: new Date(ms).toISOString(), cwd: setup.work };
		writeFileSync(file, [header, ...entries].map((e) => JSON.stringify(e)).join("\n") + "\n");

		const run = await runPi(setup, ["--session", file, "Add a footer"]);
		assert.equal(omlx.requests.length, 3, `expected 3 requests (stuck, rescued tool call, second length stop), got ${omlx.requests.length}`);
		assert.doesNotMatch(run.stdout, /Must never be reached/);
		const saved = readFileSync(file, "utf8").trim().split("\n").map((l) => JSON.parse(l));
		const rescues = saved.filter((e) => e.type === "compaction" && e.fromHook === true);
		assert.equal(rescues.length, 1, "at most one rescue compaction per run");
	} finally {
		await omlx.close();
		rmSync(setup.root, { recursive: true, force: true });
	}
});
