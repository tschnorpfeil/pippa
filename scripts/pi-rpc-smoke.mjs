#!/usr/bin/env node
// Headless RPC smoke for a Pi payload, used by scripts/bump-pi.sh. Starts the real Pi the way the app does
// (Pippa's Node + release cli.js, `--mode rpc`, guard and tool extensions, the app's flags and environment) against a
// FAKE HOME under .build/ and a scripted OpenAI-compatible stand-in on 127.0.0.1. No real model, no network, ~/.pi
// is never read or written.
//
//   node scripts/pi-rpc-smoke.mjs <payload dir from bundle-pi-payload.sh --with-node> [expected version]
//
// Checks: `--version`; models.json provider with a `!command` API key (as PiInstaller writes it); get_state;
// a guarded `write` that asks over extension_ui_request and is allowed; the guard's receipt via appendEntry
// (entry_appended); agent_settled; the session file under --session-dir with --session-id; an abort that still
// ends in agent_settled. Exit code 0 only if every check passed.
import { spawn, execFileSync } from "node:child_process";
import { createServer } from "node:http";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { mkdir, mkdtemp, rm, writeFile, chmod } from "node:fs/promises";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repo = resolve(fileURLToPath(new URL("..", import.meta.url)));
const payload = resolve(process.argv[2] ?? "");
const expected = process.argv[3];
const node = join(payload, "bin/node");
const cli = join(payload, "release/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js");
if (!existsSync(node) || !existsSync(cli)) {
	console.error("Usage: pi-rpc-smoke.mjs <payload dir with bin/node and release/> [version]");
	process.exit(2);
}

await mkdir(join(repo, ".build"), { recursive: true });
const home = await mkdtemp(join(repo, ".build/pi-smoke-home-"));
const agent = join(home, ".pi/agent");
const work = join(home, "work");
const sessions = join(home, "Library/Application Support/Pippa/pi-sessions");
const keyFile = join(home, "Library/Application Support/Pippa/llama-key");
await Promise.all([agent, work, sessions].map((d) => mkdir(d, { recursive: true })));
await writeFile(keyFile, "smoke-key\n");
await chmod(keyFile, 0o600);

let failed = 0;
const check = (name, ok, detail = "") => {
	console.log(`${ok ? "ok  " : "FAIL"} ${name}${detail ? ` (${detail})` : ""}`);
	if (!ok) failed++;
};
const env = {
	HOME: home, PATH: `${join(payload, "bin")}:/usr/bin:/bin:/usr/sbin:/sbin`,
	PI_TELEMETRY: "0", PI_OFFLINE: "1", PI_SKIP_VERSION_CHECK: "1",
	PIPPA_UNDO_DIR: join(home, "undo"), PIPPA_TRASH_DIR: join(home, "trash"), PIPPA_GUARD_POLICY: "ask-all",
};

// 1. --version
const version = execFileSync(node, [cli, "--version"], { env, encoding: "utf8" }).trim();
check("pi --version", !expected || version === expected, version);

// 2. Scripted model: first a write tool call, then text; a slow turn for the abort check.
const auth = [];
let step = 0;
const model = createServer((req, res) => {
	let body = "";
	req.on("data", (c) => { body += c; });
	req.on("end", () => {
		if (!req.url.endsWith("/chat/completions")) { res.writeHead(404).end(); return; }
		auth.push(req.headers.authorization ?? "");
		const prompt = JSON.stringify(JSON.parse(body).messages ?? []);
		res.writeHead(200, { "content-type": "text/event-stream" });
		const chunk = (delta, finish = null) => `data: ${JSON.stringify({ id: "c", object: "chat.completion.chunk", created: 0, model: "smoke",
			choices: [{ index: 0, delta, finish_reason: finish }] })}\n\n`;
		if (prompt.includes("SLOW")) {
			res.write(chunk({ role: "assistant", content: "Moment" }));
			setTimeout(() => { if (!res.writableEnded) res.end("data: [DONE]\n\n"); }, 20_000);
			return;
		}
		if (step++ === 0) {
			res.write(chunk({ role: "assistant", tool_calls: [{ index: 0, id: "call_1", type: "function",
				function: { name: "write", arguments: JSON.stringify({ path: "hello.txt", content: "Hallo\n" }) } }] }));
			res.write(chunk({}, "tool_calls"));
		} else {
			res.write(chunk({ role: "assistant", content: "Fertig." }));
			res.write(chunk({}, "stop"));
		}
		res.end("data: [DONE]\n\n");
	});
});
await new Promise((ok) => model.listen(0, "127.0.0.1", ok));
const port = model.address().port;
// Same shape as PiInstaller.providerEntry: fixed port, key read by Pi through `!/bin/cat '<file>'`.
await writeFile(join(agent, "models.json"), JSON.stringify({ providers: { "pippa-local": {
	baseUrl: `http://127.0.0.1:${port}/v1`, api: "openai-completions", apiKey: `!/bin/cat '${keyFile}'`,
	models: [{ id: "smoke", name: "Smoke", contextWindow: 16384, maxTokens: 1024 }] } } }, null, 2));

// 3. Pi in RPC mode with the app's arguments (PippaPiLaunch.configuration + PiInstaller.launchSpec).
const guard = join(repo, "runtime/pippa-guard");
const child = spawn(node, [cli, "--mode", "rpc", "--extension", join(guard, "pippa-guard.ts"), "--extension", join(guard, "pippa-tools.ts"),
	"--provider", "pippa-local", "--model", "smoke", "--no-context-files", "--no-approve", "--system-prompt", "You are a smoke test.",
	"--session-dir", sessions, "--session-id", "smoke-1"], { cwd: work, env, stdio: ["pipe", "pipe", "pipe"] });
let stderr = "";
child.stderr.on("data", (d) => { stderr += d; });
const events = [];
const waiters = [];
let buffer = "";
child.stdout.on("data", (data) => {
	buffer += data;
	let n;
	while ((n = buffer.indexOf("\n")) >= 0) {
		const line = buffer.slice(0, n); buffer = buffer.slice(n + 1);
		let event; try { event = JSON.parse(line); } catch { check("stdout is JSONL only", false, line.slice(0, 80)); continue; }
		events.push(event);
		if (event.type === "extension_ui_request" && event.method === "confirm") {
			child.stdin.write(`${JSON.stringify({ type: "extension_ui_response", id: event.id, confirmed: true })}\n`);
		} else if (event.type === "extension_ui_request" && event.method === "select") {
			child.stdin.write(`${JSON.stringify({ type: "extension_ui_response", id: event.id, value: event.options[0] })}\n`);
		}
		for (const w of [...waiters]) if (w.match(event)) { waiters.splice(waiters.indexOf(w), 1); w.resolve(event); }
	}
});
const send = (command) => child.stdin.write(`${JSON.stringify(command)}\n`);
const waitFor = (match, ms = 60_000) => new Promise((resolve, reject) => {
	const timer = setTimeout(() => reject(new Error(`timeout; stderr: ${stderr.slice(-600)}`)), ms);
	waiters.push({ match, resolve: (e) => { clearTimeout(timer); resolve(e); } });
});

try {
	send({ id: "s1", type: "get_state" });
	const state = await waitFor((e) => e.type === "response" && e.id === "s1");
	check("get_state", state.success === true && state.data?.model?.id === "smoke", `model ${state.data?.model?.provider}/${state.data?.model?.id}`);

	send({ id: "p1", type: "prompt", message: "Schreib hello.txt" });
	const accepted = await waitFor((e) => e.type === "response" && e.id === "p1");
	check("prompt accepted", accepted.success === true);
	const settled = await waitFor((e) => e.type === "agent_settled");
	check("agent_settled", true, `aborted=${JSON.stringify(settled.aborted)}`);
	const asked = events.some((e) => e.type === "extension_ui_request" && (e.method === "confirm" || e.method === "select"));
	check("guard asked over extension_ui_request (tool_call)", asked);
	const end = events.find((e) => e.type === "tool_execution_end" && e.toolName === "write");
	check("write ran", Boolean(end && !end.isError && existsSync(join(work, "hello.txt")) && readFileSync(join(work, "hello.txt"), "utf8") === "Hallo\n"));
	check("guard receipt via appendEntry", events.some((e) => e.type === "entry_appended" && e.entry?.customType === "pippa-receipt"));
	check("API key from !command", auth.length > 0 && auth.every((a) => a === "Bearer smoke-key"), auth[0]);
	const files = readdirSync(sessions, { recursive: true }).map(String).filter((f) => f.endsWith(".jsonl"));
	check("session file in --session-dir with --session-id", files.some((f) => f.includes("smoke-1")), files.join(", "));

	send({ id: "p2", type: "prompt", message: "SLOW" });
	await waitFor((e) => e.type === "message_update", 30_000);
	send({ id: "a1", type: "abort" });
	const abortSettled = await waitFor((e) => e.type === "agent_settled", 30_000);
	check("abort ends in agent_settled", true, `aborted=${JSON.stringify(abortSettled.aborted)}`);
} catch (error) {
	check("run", false, error.message);
} finally {
	child.kill("SIGTERM");
	model.closeAllConnections?.();
	model.close();
	if (!failed) await rm(home, { recursive: true, force: true });
	else console.log(`fake HOME kept for inspection: ${home}`);
}
console.log(failed ? `RPC smoke: ${failed} check(s) failed` : `RPC smoke passed (Pi ${version})`);
process.exit(failed ? 1 : 0);
