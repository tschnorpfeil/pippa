// Pi's `codemode` for an online AI with Mac access (docs/pippa-1.0.md "Codemode"), with the real Pi, a scripted provider
// on loopback and a stand-in for the app's MCP server. No model, no network beyond 127.0.0.1, synthetic markers only.
//
//   PIPPA_PI_CLI=<pi>/dist/bundle/cli.js node --experimental-strip-types --test runtime/pippa-tools/real-pi-codemode.test.mjs
//
// One Pi process with the Mac-access launch (the AI on this Mac's extensions and tools, PIPPA_MCP_EXPOSURE=direct+codemode
// and `codemode` at the end of `--tools`, as PippaPiLaunch.addMCP sets them)
// answers one scripted question per case; the scripted model calls `codemode` with a script that
//  a. pages through the app's mail reader three times and returns only a summary,
//  b. runs AppleScript in the shell (refused as app control),
//  c. runs curl twice, and the person says no twice (asked per command; nothing goes out),
//  d. asks to go online once more, and the person says yes only after a while (the script waits, then goes on),
//  e. writes into Pi's agent folder (refused by the protected-path hook),
//  f. adds a reminder and then throws (the reminder stays made; the answer goes on),
//  g. runs a long command and the person presses Stop (the script ends).
// A second process without the switch, the AI on this Mac as before, declares no codemode.
import assert from "node:assert/strict";
import { spawn, execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { CODEMODE_EXPOSURE, READINESS_COMMAND, REQUIRED_TOOLS } from "./pippa-mcp.ts";
import { APP_CONTROL_REASON, SHELL_DECLINED_REASON } from "./shell.ts";
import { PROTECTED_REASON } from "./protected.ts";

const payload = process.env.PIPPA_PI_PAYLOAD;
const cli = process.env.PIPPA_PI_CLI || (payload && join(payload, "release/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js"));
const node = process.env.PIPPA_PI_NODE || (payload && existsSync(join(payload, "bin/node")) ? join(payload, "bin/node") : process.execPath);
const here = fileURLToPath(new URL(".", import.meta.url));
const build = join(here, "../../.build");

const MAIL_MARKER = "MAIL-PAGE-BODY-71c3";
const NET_MARKER = "LOOPBACK-PAGE-5b9e";
// PippaPiLaunch.tools with web search off, as the app starts the AI on this Mac and an online AI with Mac access.
const LOCAL_TOOLS = ["read", "bash", "write", "search_files", "list_folder", "move_files", "remember", "ask", "mcp__pippa__*"];
const EXTENSIONS = ["pippa-tools.ts", "pippa-assist.ts", "pippa-memory.ts", "pippa-mcp.ts"];
const json = (value) => JSON.stringify(value).slice(1, -1);

/** One Pi process over RPC; `answer(request)` decides each question card. */
function startPi({ root, agent, work, sessions, base, token, memoryFile, env, answer, tools = LOCAL_TOOLS }) {
	const child = spawn(node, [cli, "--mode", "rpc", "--no-context-files", "--no-approve", "--no-extensions", "--no-skills",
		...EXTENSIONS.flatMap((name) => ["--extension", join(here, name)]), "--tools", tools.join(","),
		"--system-prompt", "You are a scripted test.", "--session-dir", sessions, "--session-id", `codemode-${randomUUID()}`,
		"--provider", "fixture", "--model", "test"], {
		cwd: work, env: { HOME: root, PATH: process.env.PATH, PI_CODING_AGENT_DIR: agent, PI_OFFLINE: "1", PI_SKIP_VERSION_CHECK: "1",
			PI_TELEMETRY: "0", PIPPA_MCP_URL: `${base}/mcp`, PIPPA_MCP_TOKEN: token, PIPPA_MEMORY_FILE: memoryFile, PIPPA_LANGUAGE: "en", ...env },
		stdio: ["pipe", "pipe", "pipe"],
	});
	let stderr = "", buffer = "", serial = 0, settled, events = [];
	const entries = [], pending = new Map();
	const listeners = new Set();
	child.stderr.on("data", (data) => { stderr += data; });
	child.stdout.on("data", (data) => {
		buffer += data;
		for (let end; (end = buffer.indexOf("\n")) >= 0;) {
			const line = buffer.slice(0, end); buffer = buffer.slice(end + 1);
			let event; try { event = JSON.parse(line); } catch { continue; }
			events.push(event);
			for (const listener of listeners) listener(event);
			if (event.type === "entry_appended") entries.push(event.entry);
			if (event.type === "response") pending.get(event.id)?.resolve(event);
			if (event.type === "agent_settled") settled?.resolve(event);
			if (event.type === "extension_ui_request" && event.method === "confirm") {
				void Promise.resolve(answer(event)).then((confirmed) =>
					child.stdin.write(JSON.stringify({ type: "extension_ui_response", id: event.id, confirmed }) + "\n"));
			}
		}
	});
	child.on("exit", (code) => { for (const waiter of pending.values()) waiter.reject(new Error(`Pi exited ${code}: ${stderr.slice(-1500)}`)); });
	const command = async (type, fields = {}) => {
		const id = `codemode-${++serial}`; let timer;
		try {
			return await new Promise((resolve, reject) => {
				pending.set(id, { resolve, reject });
				timer = setTimeout(() => reject(new Error(`No ${type} response: ${stderr.slice(-1500)}`)), 15_000);
				child.stdin.write(JSON.stringify({ id, type, ...fields }) + "\n");
			});
		} finally { clearTimeout(timer); pending.delete(id); }
	};
	return {
		get stderr() { return stderr; },
		listen(listener) { listeners.add(listener); return () => listeners.delete(listener); },
		command,
		async ready() {
			const nonce = randomUUID();
			await command("prompt", { message: `/${READINESS_COMMAND} ${nonce}` });
			return entries.find((entry) => entry.customType === READINESS_COMMAND && entry.data?.nonce === nonce)?.data;
		},
		/** One question until Pi settles; the events of exactly that answer. */
		async ask(message, seconds = 30) {
			events = [];
			let timer;
			const finished = new Promise((resolve, reject) => { settled = { resolve, reject };
				timer = setTimeout(() => reject(new Error(`No answer to ${message}: ${stderr.slice(-1500)}`)), seconds * 1000); });
			await command("prompt", { message });
			const end = await finished;
			clearTimeout(timer);
			return { events, settled: end };
		},
		async stop() {
			if (child.exitCode === null && child.signalCode === null) { child.kill("SIGKILL"); await new Promise((resolve) => child.once("exit", resolve)); }
		},
	};
}

test("real Pi with Mac access and codemode: scripts call Pippa's tools through every gate", {
	skip: !cli && "PIPPA_PI_PAYLOAD or PIPPA_PI_CLI not set", timeout: 180_000,
}, async () => {
	assert.match(execFileSync(node, [cli, "--version"], { encoding: "utf8" }).trim(), /^1\.6\./);
	await mkdir(build, { recursive: true });
	const root = await mkdtemp(join(build, "pippa-codemode-realpi-"));
	const agent = join(root, "agent"), work = join(root, "work"), sessions = join(root, "sessions");
	await Promise.all([agent, work, sessions].map((path) => mkdir(path, { recursive: true })));
	const memoryFile = join(root, "memory.md");
	await writeFile(memoryFile, "- fixture\n");
	const token = "9a".repeat(32);
	const mcpCalls = [], netHits = [], bodies = [];
	// The case is named in the question; the scripted model sends its script once, then answers.
	const scripts = {};
	const server = createServer((req, res) => {
		let text = "";
		req.on("data", (chunk) => { text += chunk; });
		req.on("end", () => {
			if (req.url.startsWith("/net-")) { netHits.push(req.url); res.writeHead(200); res.end(NET_MARKER); return; }
			if (req.url === "/mcp") {
				if (req.headers.authorization !== `Bearer ${token}`) { res.writeHead(403); res.end(); return; }
				if (req.method !== "POST") { res.writeHead(405); res.end(); return; }
				const request = JSON.parse(text);
				if (request.id === undefined) { res.writeHead(202); res.end(); return; }
				let result = {};
				if (request.method === "initialize") result = { protocolVersion: "2024-11-05", capabilities: { tools: {} }, serverInfo: { name: "pippa-fixture", version: "1" } };
				else if (request.method === "tools/list") result = { tools: REQUIRED_TOOLS.map((name) => name.split("__").pop()).map((name) => ({
					name, description: "Fixture", inputSchema: { type: "object", properties: { query: { type: "string" }, title: { type: "string" } } } })) };
				else if (request.method === "tools/call") {
					mcpCalls.push(request.params);
					const { name, arguments: args } = request.params;
					result = name === "mail_search"
						? { content: [{ type: "text", text: `${MAIL_MARKER} ${"x".repeat(4000)}` }], structuredContent: { page: args?.query, count: 20 }, isError: false }
						: { content: [{ type: "text", text: JSON.stringify({ done: true }) }], isError: false };
				}
				res.writeHead(200, { "Content-Type": "application/json" });
				res.end(JSON.stringify({ jsonrpc: "2.0", id: request.id, result }));
				return;
			}
			const body = JSON.parse(text);
			bodies.push(body);
			res.writeHead(200, { "Content-Type": "text/event-stream" });
			const chunk = (delta, finish_reason) => `data: ${JSON.stringify({ id: "fixture", object: "chat.completion.chunk", created: 0,
				model: "test", choices: [{ index: 0, delta, finish_reason }] })}\n\n`;
			const last = body.messages.at(-1);
			const user = [...body.messages].reverse().find((message) => message.role === "user");
			const asked = JSON.stringify(user?.content ?? "");
			const name = Object.keys(scripts).find((key) => asked.includes(`CASE-${key}`));
			if (name && last.role === "user") {
				res.write(chunk({ role: "assistant", tool_calls: [{ index: 0, id: `script_${name}`, type: "function",
					function: { name: "codemode", arguments: JSON.stringify({ code: scripts[name] }) } }] }, null));
				res.write(chunk({}, "tool_calls"));
			} else {
				res.write(chunk({ role: "assistant", content: "Fixture answer." }, "stop"));
			}
			res.end("data: [DONE]\n\n");
		});
	});
	let pi, plain;
	try {
		await new Promise((resolve, reject) => { server.once("error", reject); server.listen(0, "127.0.0.1", resolve); });
		const base = `http://127.0.0.1:${server.address().port}`;
		await writeFile(join(agent, "models.json"), JSON.stringify({ providers: { fixture: {
			baseUrl: `${base}/v1`, api: "openai-completions", apiKey: "fixture",
			models: [{ id: "test", name: "Test", contextWindow: 128000, maxTokens: 4096 }],
		} } }));
		// The person's shared settings ask for "only"; Pippa's Pi keeps "on" regardless.
		await writeFile(join(agent, "settings.json"), JSON.stringify({ codemode: { mode: "only" } }));
		const questions = [];
		let answer = () => false;
		pi = startPi({ root, agent, work, sessions, base, token, memoryFile, env: { PIPPA_MCP_EXPOSURE: CODEMODE_EXPOSURE, PIPPA_MAX_CALLS: "80" },
			tools: [...LOCAL_TOOLS, "codemode"],
			answer: (request) => { questions.push(request); return answer(request); } });
		const ready = await pi.ready();
		assert.equal(ready?.status, "ready", JSON.stringify(ready) + pi.stderr.slice(-800));
		assert.deepEqual([...ready.tools].sort(), [...REQUIRED_TOOLS].sort());

		const nested = (run) => run.events.filter((event) => event.type === "tool_execution_start" && event.parentToolCallId);
		const scriptEnd = (run, name) => run.events.find((event) => event.type === "tool_execution_end" && event.toolCallId === `script_${name}`);
		const resultOf = (event) => (event?.result?.content ?? []).map((part) => part.text ?? "").join("\n");

		// A1: codemode is declared next to the declared tools (mode "on" although the shared settings say "only").
		scripts.a = `const pages = [];
for (const query of ["p1", "p2", "p3"]) {
  const result = await tools.mcp__pippa__mail_search({ query });
  pages.push(result.structuredContent.page + ":" + result.structuredContent.count);
}
return "SUMMARY " + pages.join(",");`;
		bodies.length = 0;
		const a = await pi.ask("CASE-a Count my mail.");
		const declared = (bodies[0].tools ?? []).map((tool) => tool.function?.name ?? tool.name);
		assert.ok(declared.includes("codemode"), `codemode is declared: ${declared}`);
		for (const tool of ["read", "bash", "write", "mcp__pippa__mail_search", "mcp__pippa__calendar_add"]) assert.ok(declared.includes(tool), `${tool} stays declared`);
		// a. Three nested reader calls, reported with the script as parent; only the summary reaches the model.
		assert.deepEqual(mcpCalls.map((call) => [call.name, call.arguments?.query]), [["mail_search", "p1"], ["mail_search", "p2"], ["mail_search", "p3"]]);
		const pages = nested(a);
		assert.equal(pages.length, 3);
		assert.ok(pages.every((event) => event.parentToolCallId === "script_a" && event.toolCallId.startsWith("script_a/")), JSON.stringify(pages));
		const next = JSON.stringify(bodies.at(-1).messages);
		assert.ok(next.includes("SUMMARY p1:20,p2:20,p3:20"), "the script's summary goes to the model");
		assert.equal(next.includes(MAIL_MARKER), false, "the pages themselves stay in the script");
		assert.equal(a.settled.aborted, false);

		// b. AppleScript from a script: refused as app control, nothing ran.
		scripts.b = `try { await tools.bash({ command: "osascript -e 'return \\"APPLESCRIPT-RAN\\"'" }); return "RAN"; }
catch (error) { return "REFUSED " + error.message; }`;
		const b = await pi.ask("CASE-b Use AppleScript.");
		const refused = resultOf(scriptEnd(b, "b"));
		assert.ok(refused.includes("REFUSED") && refused.includes(APP_CONTROL_REASON), refused);
		assert.equal(refused.includes("APPLESCRIPT-RAN"), false);

		// c. Two commands that go online: asked per command; after two no's nothing went out.
		scripts.c = `const out = [];
for (const n of [1, 2]) {
  try { const r = await tools.bash({ command: "curl -s ${base}/net-" + n }); out.push("RAN " + r.output); }
  catch (error) { out.push("NO " + error.message); }
}
return out.join("\\n");`;
		questions.length = 0;
		answer = () => false;
		const c = await pi.ask("CASE-c Fetch two pages.");
		assert.equal(questions.length, 2, "asked once per command");
		assert.ok(questions.every((question) => /online/i.test(question.title + question.message)), JSON.stringify(questions));
		assert.ok(questions[0].message.includes("net-1") && questions[1].message.includes("net-2"), "each question names its own command");
		assert.deepEqual(netHits, [], "nothing went online");
		const declined = resultOf(scriptEnd(c, "c"));
		assert.equal(declined.split(SHELL_DECLINED_REASON).length - 1, 2, declined);

		// d. A question in the middle of a script: no deadline; after a late yes the script goes on.
		scripts.d = `const r = await tools.bash({ command: "curl -s ${base}/net-3" });
return "AFTER " + r.output;`;
		questions.length = 0;
		answer = () => new Promise((resolve) => setTimeout(() => resolve(true), 3_000));
		const d = await pi.ask("CASE-d Fetch one page.");
		assert.equal(questions.length, 1);
		assert.equal(questions[0].timeout, undefined, "the card has no timeout");
		assert.deepEqual(netHits, ["/net-3"]);
		assert.ok(resultOf(scriptEnd(d, "d")).includes(`AFTER ${NET_MARKER}`), resultOf(scriptEnd(d, "d")));

		// e. A write into Pi's agent folder: blocked by the protected-path hook.
		scripts.e = `try { await tools.write({ path: ${JSON.stringify(join(agent, "planted.json"))}, content: "{}" }); return "WROTE"; }
catch (error) { return "BLOCKED " + error.message; }`;
		const e = await pi.ask("CASE-e Save a file.");
		const blocked = resultOf(scriptEnd(e, "e"));
		assert.ok(blocked.includes("BLOCKED") && blocked.includes(PROTECTED_REASON), blocked);
		assert.equal(existsSync(join(agent, "planted.json")), false);

		// f. A script that throws after a change: the change stays made, the script failed, the answer goes on.
		scripts.f = `await tools.mcp__pippa__reminder_add({ title: "Fixture reminder" });
throw new Error("SCRIPT-BROKE");`;
		const before = mcpCalls.length;
		bodies.length = 0;
		const f = await pi.ask("CASE-f Add a reminder.");
		assert.deepEqual(mcpCalls.slice(before).map((call) => call.name), ["reminder_add"]);
		const broke = scriptEnd(f, "f");
		assert.equal(broke?.isError, true);
		assert.ok(resultOf(broke).includes("SCRIPT-BROKE"));
		const nestedEnd = f.events.find((event) => event.type === "tool_execution_end" && event.parentToolCallId === "script_f");
		assert.equal(nestedEnd?.isError, false, "the reminder call itself succeeded");
		assert.equal(bodies.length, 2, "the model got the failure and answered");
		assert.equal(f.settled.aborted, false);

		// g. Stop while a script runs a long command: the script ends promptly.
		scripts.g = `await tools.bash({ command: "sleep 30" });
return "NOT-STOPPED";`;
		const off = pi.listen((event) => {
			if (event.type === "tool_execution_start" && event.parentToolCallId === "script_g") setTimeout(() => void pi.command("abort"), 500);
		});
		const started = Date.now();
		const g = await pi.ask("CASE-g Wait.", 20);
		off();
		assert.equal(g.settled.aborted, true);
		assert.ok(Date.now() - started < 15_000, "Stop ends the script long before its command would");
		assert.equal(resultOf(scriptEnd(g, "g")).includes("NOT-STOPPED"), false);
		await pi.stop();

		// The AI on this Mac, as before: the same launch without the switch has no codemode.
		bodies.length = 0;
		plain = startPi({ root, agent, work, sessions, base, token, memoryFile, env: {}, answer: () => false });
		const plainReady = await plain.ready();
		assert.equal(plainReady?.status, "ready", JSON.stringify(plainReady) + plain.stderr.slice(-800));
		await plain.ask("Hello");
		const plainDeclared = (bodies[0].tools ?? []).map((tool) => tool.function?.name ?? tool.name);
		assert.equal(plainDeclared.includes("codemode"), false, `no codemode without Mac access: ${plainDeclared}`);
		assert.ok(plainDeclared.includes("mcp__pippa__mail_search"));
	} finally {
		await pi?.stop(); await plain?.stop();
		server.closeAllConnections(); await new Promise((resolve) => server.close(resolve));
		await rm(root, { recursive: true, force: true });
	}
});
