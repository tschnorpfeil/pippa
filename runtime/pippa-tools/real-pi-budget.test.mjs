// Budget of the first request: what a real Pi (`--mode rpc`) sends the local model before anything was said, with
// Pippa's launch arguments (prompt and tool list read from PippaPiLaunch.swift). Every token here is prefilled cold on
// a new conversation (~1.5 ms per token on a 16 GB Mac), so a new tool or a longer description has to fit or replace
// something. Skipped unless a Pi CLI is named (CI passes the pinned release):
//
//   PIPPA_PI_CLI=<release>/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js \
//   node --experimental-strip-types --test runtime/pippa-tools/real-pi-budget.test.mjs
//
// Budget: about 3,000 tokens for the whole first request (measured 2026-10-09: 9,086 characters = 2,860 tokens with
// Qwen3.5's chat template). Here the system text without the working folder plus Pi's, Pippa's and the web tools'
// declarations; Pippa's MCP declarations have their own share in PippaChecks (R2Checks, "First request budget").
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
const repo = join(here, "../..");
const web = join(repo, "runtime/pippa-web/index.ts");

/** Characters of system text (without `<cwd>`) and non-MCP tool declarations; MCP adds at most 3,100 (Swift). */
const BUDGET = 6_400;

test("real Pi: the first request stays within Pippa's budget, with no skills section", {
	skip: (!cli && "PIPPA_PI_CLI not set") || (!existsSync(join(repo, "runtime/pippa-web/node_modules")) && "npm ci in runtime/pippa-web first"),
	timeout: 60_000,
}, async () => {
	mkdirSync(join(repo, ".build"), { recursive: true });
	const root = mkdtempSync(join(repo, ".build/pippa-budget-realpi-"));
	const home = join(root, "home"), agent = join(home, ".pi/agent"), work = join(root, "work");
	for (const dir of [agent, work]) mkdirSync(dir, { recursive: true });
	let first;
	const server = createServer((req, res) => {
		let body = "";
		req.on("data", (chunk) => (body += chunk));
		req.on("end", () => {
			first ??= JSON.parse(body);
			res.writeHead(200, { "Content-Type": "text/event-stream" });
			res.end(`data: ${JSON.stringify({ id: "x", object: "chat.completion.chunk", created: 0, model: "m",
				choices: [{ index: 0, delta: { role: "assistant", content: "ok" }, finish_reason: "stop" }] })}\n\ndata: [DONE]\n\n`);
		});
	}).listen(0, "127.0.0.1");
	await new Promise((done) => server.once("listening", done));
	writeFileSync(join(agent, "models.json"), JSON.stringify({ providers: { "pippa-local": { baseUrl: `http://127.0.0.1:${server.address().port}/v1`,
		api: "openai-completions", apiKey: "x", models: [{ id: "m", name: "M", contextWindow: 16384, maxTokens: 4096 }] } } }));

	const launch = readFileSync(join(repo, "app/Sources/PiRPC/PippaPiLaunch.swift"), "utf8");
	const prompt = launch.match(/static let german = """\n([\s\S]*?)\n    """/)[1].replace(/^    /gm, "");
	const tools = launch.match(/public static let tools = \[([\s\S]*?)\]/)[1].match(/"[^"]+"/g).map((x) => JSON.parse(x)).join(",");
	const env = { HOME: home, PATH: process.env.PATH, PI_CODING_AGENT_DIR: agent, PI_OFFLINE: "1", PI_SKIP_VERSION_CHECK: "1", PI_TELEMETRY: "0",
		PIPPA_WEB_DIR: join(root, "web"), PIPPA_MEMORY_FILE: join(root, "memory.md") };
	const extensions = ["pippa-tools.ts", "pippa-assist.ts", "pippa-memory.ts", "pippa-context.ts"].map((f) => join(here, f)).concat(web);
	const child = spawn(node, [cli, "--mode", "rpc", "--no-session", "--no-context-files", "--no-approve",
		"--no-skills", "--skill", join(repo, "runtime/pippa-skills"), ...extensions.flatMap((e) => ["--extension", e]),
		"--tools", tools, "--system-prompt", prompt, "--provider", "pippa-local", "--model", "m"], { cwd: work, env, stdio: ["pipe", "pipe", "pipe"] });
	let err = "", buffer = "";
	child.stderr.on("data", (d) => (err += d));
	try {
		await new Promise((done, fail) => {
			const timer = setTimeout(() => fail(new Error(`no answer: ${err.slice(-500)}`)), 50_000);
			child.on("exit", (code) => { clearTimeout(timer); fail(new Error(`Pi exited ${code}: ${err.slice(-500)}`)); });
			child.stdout.on("data", (d) => {
				buffer += d;
				for (let i; (i = buffer.indexOf("\n")) >= 0;) {
					const line = buffer.slice(0, i);
					buffer = buffer.slice(i + 1);
					let event;
					try { event = JSON.parse(line); } catch { continue; }
					if (event.type === "extension_error") { clearTimeout(timer); fail(new Error(line)); }
					if (event.type === "agent_settled") { clearTimeout(timer); done(); }
				}
			});
			child.stdin.write(JSON.stringify({ type: "prompt", message: "Hallo" }) + "\n");
		});
	} finally {
		child.kill();
		server.closeAllConnections();
		server.close();
	}

	const system = first.messages.find((m) => m.role === "system" || m.role === "developer");
	const text = typeof system.content === "string" ? system.content : system.content.map((p) => p.text).join("");
	const declared = first.tools.filter((t) => !t.function.name.startsWith("mcp__"));
	const names = declared.map((t) => t.function.name).sort();
	const size = text.replace(/<cwd>[\s\S]*?<\/cwd>/, "").length + JSON.stringify(declared).length;
	assert.ok(text.startsWith("Du bist Pippa"), "Pippa's own prompt replaces Pi's");
	assert.ok(!text.includes("<skills>"), "every skill is button-only (disable-model-invocation), so no skills section");
	assert.deepEqual(names, ["bash", "edit", "fetch_content", "list_folder", "move_files", "move_to_trash", "read", "remember", "search_files", "web_search", "write"]);
	assert.ok(size <= BUDGET, `first request: ${size} characters of prompt and tool declarations, budget ${BUDGET}`);
	console.log(`first request: ${size} of ${BUDGET} characters (without MCP)`);
});
