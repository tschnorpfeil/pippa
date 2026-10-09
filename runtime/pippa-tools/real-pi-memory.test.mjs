// pippa-memory.ts and pippa-context.ts inside a real Pi (`--mode rpc`) with a scripted stand-in model. Skipped unless a
// Pi CLI is named (scripts/bump-pi.sh passes the payload), so a Pi update that changes prompt sections, compaction or
// the prompt-during-compaction answer shows up here:
//
//   PIPPA_PI_CLI=<release>/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js \
//   node --experimental-strip-types --test runtime/pippa-tools/real-pi-memory.test.mjs
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const payload = process.env.PIPPA_PI_PAYLOAD;
const cli = process.env.PIPPA_PI_CLI
	|| (payload ? join(payload, "release/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js") : undefined);
const node = process.env.PIPPA_PI_NODE || (payload && existsSync(join(payload, "bin/node")) ? join(payload, "bin/node") : process.execPath);
const here = fileURLToPath(new URL(".", import.meta.url));

/** OpenAI-compatible stand-in: "merk dir" → a remember call, "lang" → a long answer, a summary request → a summary
 * (after `summaryDelay`), anything else → "ok". Every answer reports 11,000 prompt tokens of a 16k window. */
function model(requests, summaryDelay) {
	return createServer((req, res) => {
		let body = "";
		req.on("data", (chunk) => (body += chunk));
		req.on("end", () => {
			const json = JSON.parse(body || "{}");
			requests.push(json);
			const messages = json.messages ?? [];
			const last = messages.at(-1) ?? {};
			const text = typeof last.content === "string" ? last.content : JSON.stringify(last.content ?? "");
			const chunk = (delta, finish = null, usage) => `data: ${JSON.stringify({ id: "x", object: "chat.completion.chunk", created: 0, model: "m",
				choices: [{ index: 0, delta, finish_reason: finish }], ...(usage ? { usage } : {}) })}\n\n`;
			const usage = { prompt_tokens: 11000, completion_tokens: 20, total_tokens: 11020 };
			const send = (s) => res.end(s + "data: [DONE]\n\n");
			res.writeHead(200, { "Content-Type": "text/event-stream" });
			if (JSON.stringify(messages).includes("everyday helper conversation")) {
				setTimeout(() => send(chunk({ role: "assistant", content: "SUMMARY: letter, 84,20 €" }) + chunk({}, "stop", { prompt_tokens: 500, completion_tokens: 9, total_tokens: 509 })), summaryDelay());
			} else if (last.role === "user" && text.includes("merk dir")) {
				send(chunk({ role: "assistant", tool_calls: [{ index: 0, id: "c1", type: "function", function: { name: "remember", arguments: JSON.stringify({ add: "Lives in Köln" }) } }] }) + chunk({}, "tool_calls", usage));
			} else if (text.includes("lang")) {
				send(chunk({ role: "assistant", content: "Letter Stadtwerke 84,20 €. " + "word ".repeat(6000) }) + chunk({}, "stop", usage));
			} else {
				send(chunk({ role: "assistant", content: "ok" }) + chunk({}, "stop", usage));
			}
		});
	});
}

test("real Pi: memory section and remember, quiet summary, handover, prompt during a summary", { skip: !cli && "PIPPA_PI_CLI not set", timeout: 120_000 }, async () => {
	mkdirSync(join(here, "../../.build"), { recursive: true });
	const root = mkdtempSync(join(here, "../../.build/pippa-memory-realpi-"));
	const home = join(root, "home"), agent = join(home, ".pi/agent"), sessions = join(root, "sessions"), work = join(root, "work");
	for (const dir of [agent, sessions, work]) mkdirSync(dir, { recursive: true });
	const requests = [];
	let delay = 0;
	const server = model(requests, () => delay).listen(0, "127.0.0.1");
	await new Promise((done) => server.once("listening", done));
	const { port } = server.address();
	writeFileSync(join(agent, "models.json"), JSON.stringify({ providers: { "pippa-local": { baseUrl: `http://127.0.0.1:${port}/v1`, api: "openai-completions",
		apiKey: "x", models: [{ id: "m", name: "M", contextWindow: 16384, maxTokens: 4096 }] } } }));
	writeFileSync(join(agent, "settings.json"), JSON.stringify({ compaction: { modelOverrides: { "pippa-local/m": { reserveTokens: 4096, keepRecentTokens: 6144 } } } }));
	const memoryFile = join(root, "memory.md");
	writeFileSync(memoryFile, "- Prefers short answers\n");

	const start = (id) => {
		const env = { HOME: home, PATH: process.env.PATH, PI_OFFLINE: "1", PI_SKIP_VERSION_CHECK: "1", PI_TELEMETRY: "0",
			PIPPA_MEMORY_FILE: memoryFile, PIPPA_COMPACT_IDLE_MS: "300" };
		const child = spawn(node, [cli, "--mode", "rpc", "--extension", join(here, "pippa-memory.ts"), "--extension", join(here, "pippa-context.ts"),
			"--provider", "pippa-local", "--model", "m", "--no-context-files", "--no-approve", "--tools", "read,remember", "--system-prompt", "You are Pippa.",
			"--session-dir", sessions, "--session-id", id], { cwd: work, env, stdio: ["pipe", "pipe", "pipe"] });
		const events = [], waiters = [];
		let buffer = "", n = 0;
		child.stdout.on("data", (data) => {
			buffer += data;
			for (let i; (i = buffer.indexOf("\n")) >= 0;) {
				const line = buffer.slice(0, i); buffer = buffer.slice(i + 1);
				let event; try { event = JSON.parse(line); } catch { continue; }
				events.push(event);
				for (const w of [...waiters]) if (w.test(event)) { waiters.splice(waiters.indexOf(w), 1); w.done(event); }
			}
		});
		const until = (test, ms = 20_000) => events.find(test) ? Promise.resolve(events.find(test)) : new Promise((done, fail) => {
			waiters.push({ test, done }); setTimeout(() => fail(new Error(`timeout; events: ${events.map((e) => e.type).join(" ")}`)), ms);
		});
		const send = (command) => { const id = `r${++n}`; child.stdin.write(JSON.stringify({ ...command, id }) + "\n"); return until((e) => e.type === "response" && e.id === id); };
		const settled = (count) => until(() => events.filter((e) => e.type === "agent_settled").length >= count);
		const ask = async (message, count) => { assert.equal((await send({ type: "prompt", message })).success, true); await settled(count); };
		const stop = () => new Promise((done) => { child.once("exit", done); child.stdin.end(); });
		return { events, until, send, ask, stop };
	};

	try {
		// One topic: a remembered fact, two long answers, then the quiet summary with everyday instructions.
		const one = start("topic-one");
		await one.ask("merk dir: ich wohne in Köln", 1);
		assert.equal(readFileSync(memoryFile, "utf8"), "- Prefers short answers\n- Lives in Köln\n");
		await one.ask("erklär lang den Brief", 2);
		await one.ask("nochmal lang", 3);
		const end = await one.until((e) => e.type === "compaction_end");
		assert.equal(end.reason, "manual");
		assert.ok(end.result?.summary?.includes("SUMMARY"), JSON.stringify(end));
		await one.stop();
		const first = requests[0];
		assert.ok(JSON.stringify(first.messages[0]).includes("Prefers short answers"), "memory section in the system prompt");
		assert.ok((first.tools ?? []).some((t) => t.function?.name === "remember"));

		// A new topic: the new fact in the memory section, the handover from the previous session.
		const two = start("topic-two");
		await two.ask("hallo", 1);
		await two.stop();
		const system = JSON.stringify(requests.at(-1).messages[0]);
		assert.ok(system.includes("Lives in Köln"));
		assert.ok(system.includes("previous conversation") && system.includes("SUMMARY"), system);

		// A question during a slow summary: Pi refuses it; abort, then the question goes through (PiRPCClient.prompt).
		delay = 4000;
		const three = start("topic-one");
		await three.ask("nochmal lang", 1);
		await three.until((e) => e.type === "compaction_start");
		const refused = await three.send({ type: "prompt", message: "kurze Frage" });
		assert.equal(refused.success, false);
		assert.match(refused.error, /compaction is in progress/);
		assert.equal((await three.send({ type: "abort" })).success, true);
		assert.equal((await three.send({ type: "prompt", message: "kurze Frage" })).success, true);
		await three.until(() => three.events.filter((e) => e.type === "agent_settled").length >= 2);
		await three.stop();
	} finally {
		server.close();
	}
});
