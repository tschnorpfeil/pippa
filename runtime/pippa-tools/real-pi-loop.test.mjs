// Real Pi's validation and blocking paths skip extension hooks. Exercise the actual RPC lifecycle with a scripted
// local model, no model download or personal data. CI can pass the same payload used for the other real-Pi tests:
//
//   PIPPA_PI_PAYLOAD=<payload> node --experimental-strip-types --test runtime/pippa-tools/real-pi-loop.test.mjs
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

const payload = process.env.PIPPA_PI_PAYLOAD;
const cli = process.env.PIPPA_PI_CLI
	|| (payload ? join(payload, "release/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js") : undefined);
const node = process.env.PIPPA_PI_NODE || (payload && existsSync(join(payload, "bin/node")) ? join(payload, "bin/node") : process.execPath);
const here = fileURLToPath(new URL(".", import.meta.url));
const build = join(here, "../../.build");

for (const scenario of [
	{ name: "rejected document reads", tool: "read", args: () => ({ path: "/fake/invoice.pdf" }), attempts: 5 },
	{ name: "unknown tools", tool: "invented_tool", args: () => ({ query: "invoice" }), attempts: 5 },
	{ name: "invalid arguments", tool: "read", args: () => ({ wrong_path: "/fake/invoice.txt" }), attempts: 5 },
	{ name: "reordered duplicate writes", tool: "write", args: (n) => n % 2
		? { path: "note.txt", content: "Fixture only" } : { content: "Fixture only", path: "note.txt" }, attempts: 4 },
]) {
	test(`real Pi: ${scenario.name} settle with a loop receipt, and the next prompt works`, {
		skip: !cli && "PIPPA_PI_CLI or PIPPA_PI_PAYLOAD not set", timeout: 30_000,
	}, async () => {
		await mkdir(build, { recursive: true });
		const root = await mkdtemp(join(build, "pippa-loop-realpi-"));
		const agent = join(root, ".pi/agent"), work = join(root, "work");
		await Promise.all([agent, work].map((path) => mkdir(path, { recursive: true })));
		let requests = 0;
		const server = createServer((req, res) => {
			let body = "";
			req.on("data", (data) => { body += data; });
			req.on("end", () => {
				const recovering = JSON.stringify(JSON.parse(body).messages).includes("RECOVER");
				if (!recovering) requests++;
				res.writeHead(200, { "Content-Type": "text/event-stream" });
				const chunk = (delta, finish_reason = null) => `data: ${JSON.stringify({ id: "test", object: "chat.completion.chunk", created: 0,
					model: "test", choices: [{ index: 0, delta, finish_reason }] })}\n\n`;
				// A broken brake finishes after eight attempts so the regression fails promptly instead of hanging.
				if (recovering || requests > 8) {
					res.write(chunk({ role: "assistant", content: recovering ? "Recovered." : "Unbounded loop." }));
					res.write(chunk({}, "stop"));
				} else {
					res.write(chunk({ role: "assistant", tool_calls: [{ index: 0, id: `call_${requests}`, type: "function",
						function: { name: scenario.tool, arguments: JSON.stringify(scenario.args(requests)) } }] }));
					res.write(chunk({}, "tool_calls"));
				}
				res.end("data: [DONE]\n\n");
			});
		});
		let child;
		try {
			await new Promise((done, fail) => { server.once("error", fail); server.listen(0, "127.0.0.1", done); });
			await writeFile(join(agent, "models.json"), JSON.stringify({ providers: { "pippa-local": {
				baseUrl: `http://127.0.0.1:${server.address().port}/v1`, api: "openai-completions", apiKey: "fixture",
				models: [{ id: "test", name: "Test", contextWindow: 16384, maxTokens: 1024 }],
			} } }));
			child = spawn(node, [cli, "--mode", "rpc", "--no-session", "--no-context-files", "--no-approve", "--no-skills",
				"--extension", join(here, "pippa-assist.ts"), "--tools", "read,write", "--system-prompt", "You are a test.",
				"--provider", "pippa-local", "--model", "test"], {
				cwd: work, env: { HOME: root, PATH: process.env.PATH, PI_CODING_AGENT_DIR: agent,
					PI_OFFLINE: "1", PI_SKIP_VERSION_CHECK: "1", PI_TELEMETRY: "0" }, stdio: ["pipe", "pipe", "pipe"],
			});
			let stderr = "", buffer = "";
			child.stderr.on("data", (data) => { stderr += data; });
			const events = [];
			let waiting;
			child.stdout.on("data", (data) => {
				buffer += data;
				for (let end; (end = buffer.indexOf("\n")) >= 0;) {
					const line = buffer.slice(0, end); buffer = buffer.slice(end + 1);
					let event;
					try { event = JSON.parse(line); } catch { continue; }
					events.push(event);
					if (event.type === "extension_error") waiting?.reject(new Error(line));
					if (event.type === "agent_settled") waiting?.resolve(event);
				}
			});
			child.on("error", (error) => waiting?.reject(error));
			child.on("exit", (code) => waiting?.reject(new Error(`Pi exited ${code}: ${stderr.slice(-1000)}`)));
			const prompt = async (message) => {
				let timer;
				try {
					return await new Promise((resolve, reject) => {
						waiting = { resolve, reject };
						timer = setTimeout(() => reject(new Error(`Pi did not settle: ${stderr.slice(-1000)}`)), 12_000);
						child.stdin.write(JSON.stringify({ type: "prompt", message }) + "\n");
					});
				} finally { clearTimeout(timer); waiting = undefined; }
			};
			const stopped = await prompt("Run the scripted loop.");
			assert.equal(stopped.aborted, true);
			assert.equal(requests, scenario.attempts);
			const receipts = events.filter((event) => event.type === "entry_appended" && event.entry?.customType === "pippa-loop-stop");
			assert.equal(receipts.length, 1, "the app receives one explicit incomplete-task receipt");
			assert.equal(receipts[0].entry.data.tool, scenario.tool);
			if (scenario.tool === "write") {
				assert.equal(events.filter((event) => event.type === "tool_execution_end" && !event.isError).length, 1);
			}
			const recovered = await prompt("RECOVER");
			assert.equal(recovered.aborted, false);
			assert.ok(events.some((event) => event.type === "message_end" && event.message?.role === "assistant"
				&& Array.isArray(event.message.content) && event.message.content.some((part) => part.type === "text" && part.text === "Recovered.")));
		} finally {
			if (child && child.exitCode === null && child.signalCode === null) {
				child.kill("SIGKILL");
				await new Promise((done) => child.once("exit", done));
			}
			server.closeAllConnections();
			await new Promise((done) => server.close(done));
			await rm(root, { recursive: true, force: true });
		}
	});
}
