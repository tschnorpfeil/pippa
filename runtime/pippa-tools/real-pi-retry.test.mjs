// An online AI that answers "429 Too Many Requests", with the real Pi over RPC and a scripted provider on 127.0.0.1.
// Pi runs with the online launch's flags and extensions (PIPPA_EGRESS=online, only `ask`) and an agent folder whose
// settings.json carries the `retry` block, as PiRecipientSnapshot writes it, with short delays so the test takes seconds.
//
//   PIPPA_PI_CLI=<pi>/dist/bundle/cli.js PIPPA_PI_NODE=<node> node --experimental-strip-types --test runtime/pippa-tools/real-pi-retry.test.mjs
//
// 1. 429 twice, then 200: two `auto_retry_start`, a successful `auto_retry_end`, and the 200 answer.
// 2. 429 every time: every try is used, `auto_retry_end` fails with the provider's words; a follow-up to the same Pi
//    session (what Continue sends) then answers, and its request still holds the first question.
// 3. Stop during the wait (`abort_retry`, then `abort`, in one write as PiRPCClient sends them): Pi settles at once as stopped and
//    sends nothing more to the provider.
import assert from "node:assert/strict";
import { spawn, execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

const payload = process.env.PIPPA_PI_PAYLOAD;
const cli = process.env.PIPPA_PI_CLI || (payload && join(payload, "release/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js"));
const node = process.env.PIPPA_PI_NODE || (payload && existsSync(join(payload, "bin/node")) ? join(payload, "bin/node") : process.execPath);
const here = fileURLToPath(new URL(".", import.meta.url));
const build = join(here, "../../.build");
const QUESTION = "QUESTION-RETRY-4b1d";
const LIMIT = { error: { message: "Rate limit reached for test on requests per min (RPM): Limit 3", type: "requests", code: "rate_limit_exceeded" } };

/** A scripted provider: `script()` decides per request, 429 or an answer. */
async function provider(script) {
	const bodies = [];
	const server = createServer((req, res) => {
		let text = "";
		req.on("data", (chunk) => { text += chunk; });
		req.on("end", () => {
			bodies.push(JSON.parse(text));
			if (script(bodies.length) === 429) {
				res.writeHead(429, { "Content-Type": "application/json" });
				res.end(JSON.stringify(LIMIT));
				return;
			}
			res.writeHead(200, { "Content-Type": "text/event-stream" });
			const chunk = (delta, finish_reason) => `data: ${JSON.stringify({ id: "fixture", object: "chat.completion.chunk", created: 0,
				model: "test", choices: [{ index: 0, delta, finish_reason }] })}\n\n`;
			res.write(chunk({ role: "assistant", content: "Fixture answer." }, "stop"));
			res.end("data: [DONE]\n\n");
		});
	});
	await new Promise((resolve, reject) => { server.once("error", reject); server.listen(0, "127.0.0.1", resolve); });
	return { bodies, server, base: `http://127.0.0.1:${server.address().port}` };
}

/** One online Pi process over RPC; `prompt` collects every event until Pi settles. */
async function onlinePi(retry, script) {
	await mkdir(build, { recursive: true });
	const root = await mkdtemp(join(build, "pippa-retry-realpi-"));
	const agent = join(root, "agent"), work = join(root, "work"), sessions = join(root, "sessions");
	await Promise.all([agent, work, sessions].map((path) => mkdir(path, { recursive: true })));
	const fixture = await provider(script);
	await writeFile(join(agent, "models.json"), JSON.stringify({ providers: { fixture: {
		baseUrl: `${fixture.base}/v1`, api: "openai-completions", apiKey: "fixture",
		models: [{ id: "test", name: "Test", contextWindow: 16384, maxTokens: 1024 }],
	} } }));
	await writeFile(join(agent, "settings.json"), JSON.stringify({ retry }));
	const child = spawn(node, [cli, "--mode", "rpc", "--no-context-files", "--no-approve", "--no-extensions", "--no-skills",
		"--extension", join(here, "pippa-tools.ts"), "--extension", join(here, "pippa-assist.ts"), "--tools", "ask",
		"--system-prompt", "You are a scripted test.", "--session-dir", sessions, "--session-id", "0f9e1c1a-2222-4222-8333-944455556666_online-abc123",
		"--provider", "fixture", "--model", "test"], {
		cwd: work, env: { HOME: root, PATH: process.env.PATH, PI_CODING_AGENT_DIR: agent, PI_OFFLINE: "1", PI_SKIP_VERSION_CHECK: "1",
			PI_TELEMETRY: "0", PIPPA_EGRESS: "online", PIPPA_EGRESS_TOOLS: "ask" },
		stdio: ["pipe", "pipe", "pipe"],
	});
	let stderr = "", buffer = "", serial = 0, listener;
	child.stderr.on("data", (data) => { stderr += data; });
	child.stdout.on("data", (data) => {
		buffer += data;
		for (let end; (end = buffer.indexOf("\n")) >= 0;) {
			const line = buffer.slice(0, end); buffer = buffer.slice(end + 1);
			let event; try { event = JSON.parse(line); } catch { continue; }
			listener?.(event);
		}
	});
	/** Commands in one write, as PiRPCClient sends Stop during a wait. */
	const write = (...types) => child.stdin.write(types.map((type) => JSON.stringify({ id: `retry-${++serial}`, type }) + "\n").join(""));
	/** Sends a prompt and returns every event until `agent_settled`; `onEvent` may act on the way (Stop). */
	const prompt = (message, onEvent = () => {}) => new Promise((resolve, reject) => {
		const events = [];
		const timer = setTimeout(() => reject(new Error(`No settle: ${JSON.stringify(events.map((e) => e.type))} ${stderr.slice(-1500)}`)), 30_000);
		listener = (event) => {
			events.push(event);
			if (event.type === "response" && event.success === false) { clearTimeout(timer); reject(new Error(JSON.stringify(event))); }
			onEvent(event);
			// Later lines of the same chunk (the response to `abort`) belong to no answer.
			if (event.type === "agent_settled") { clearTimeout(timer); listener = undefined; resolve(events); }
		};
		child.stdin.write(JSON.stringify({ id: `retry-${++serial}`, type: "prompt", message }) + "\n");
	});
	const close = async () => {
		if (child.exitCode === null && child.signalCode === null) { child.kill("SIGKILL"); await new Promise((resolve) => child.once("exit", resolve)); }
		fixture.server.close();
		await rm(root, { recursive: true, force: true });
	};
	return { prompt, write, close, bodies: fixture.bodies };
}

const skip = !cli && "PIPPA_PI_PAYLOAD or PIPPA_PI_CLI not set";
const short = { maxRetries: 4, baseDelayMs: 50, maxAgentDelayMs: 200 };
const of = (events, type) => events.filter((event) => event.type === type);

test("real Pi: 429 twice, then 200 — Pi waits twice and finishes with the answer", { skip, timeout: 60_000 }, async () => {
	assert.match(execFileSync(node, [cli, "--version"], { encoding: "utf8" }).trim(), /^1\.5\./);
	const pi = await onlinePi(short, (request) => request <= 2 ? 429 : 200);
	try {
		const events = await pi.prompt(QUESTION);
		const starts = of(events, "auto_retry_start");
		assert.deepEqual(starts.map((event) => [event.attempt, event.maxAttempts, event.delayMs]), [[1, 4, 50], [2, 4, 100]]);
		assert.match(starts[0].errorMessage, /429|rate limit/i);
		assert.deepEqual(of(events, "auto_retry_end").map((event) => [event.success, event.attempt]), [[true, 2]]);
		const answer = of(events, "message_end").map((event) => event.message).filter((message) => message.role === "assistant").at(-1);
		assert.equal(answer.stopReason, "stop");
		assert.equal(answer.content.map((part) => part.text ?? "").join(""), "Fixture answer.");
		assert.equal(events.at(-1).aborted, false);
		assert.equal(pi.bodies.length, 3);
	} finally { await pi.close(); }
});

test("real Pi: 429 every time — the tries run out, and a follow-up continues the same session", { skip, timeout: 60_000 }, async () => {
	let limited = true;
	const pi = await onlinePi(short, () => limited ? 429 : 200);
	try {
		const events = await pi.prompt(QUESTION);
		assert.deepEqual(of(events, "auto_retry_start").map((event) => event.attempt), [1, 2, 3, 4]);
		const end = of(events, "auto_retry_end");
		assert.equal(end.length, 1);
		assert.equal(end[0].success, false);
		assert.match(end[0].finalError, /rate limit/i);
		assert.equal(pi.bodies.length, 5, "the first request and four tries");
		limited = false;
		const resumed = await pi.prompt("Continue where you stopped.");
		const answer = of(resumed, "message_end").map((event) => event.message).filter((message) => message.role === "assistant").at(-1);
		assert.equal(answer.stopReason, "stop");
		assert.ok(JSON.stringify(pi.bodies.at(-1)).includes(QUESTION), "the follow-up's request still holds the first question");
	} finally { await pi.close(); }
});

test("real Pi: Stop during the wait settles at once and sends nothing more", { skip, timeout: 60_000 }, async () => {
	const pi = await onlinePi({ maxRetries: 4, baseDelayMs: 20_000, maxAgentDelayMs: 60_000 }, () => 429);
	try {
		const started = Date.now();
		const events = await pi.prompt(QUESTION, (event) => {
			if (event.type === "auto_retry_start") pi.write("abort_retry", "abort");
		});
		const seen = JSON.stringify(events.filter((event) => !["message_update"].includes(event.type)));
		assert.ok(Date.now() - started < 10_000, "no 20 s wait");
		assert.equal(of(events, "auto_retry_start").length, 1, seen);
		assert.deepEqual(of(events, "auto_retry_end").map((event) => event.success), [false], seen);
		assert.equal(events.at(-1).aborted, true, seen);
		assert.equal(pi.bodies.length, 1, seen);
	} finally { await pi.close(); }
});
