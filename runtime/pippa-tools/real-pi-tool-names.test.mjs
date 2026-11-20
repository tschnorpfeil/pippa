// A mistyped tool name in real Pi: pippa-assist.ts renames it at `message_end`, before Pi looks the tool up, so the call
// runs instead of failing with "Tool … not found". Scripted local model, no download or personal data:
//
//   PIPPA_PI_PAYLOAD=<payload> node --experimental-strip-types --test runtime/pippa-tools/real-pi-tool-names.test.mjs
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
	{ name: "a prefixed real name runs as that tool", called: "web_read", ran: "read", ok: true },
	{ name: "an invented name still fails as unknown", called: "invented_read", ran: "invented_read", ok: false },
]) {
	test(`real Pi: ${scenario.name}`, { skip: !cli && "PIPPA_PI_CLI or PIPPA_PI_PAYLOAD not set", timeout: 30_000 }, async () => {
		await mkdir(build, { recursive: true });
		const root = await mkdtemp(join(build, "pippa-names-realpi-"));
		const agent = join(root, ".pi/agent"), work = join(root, "work");
		await Promise.all([agent, work].map((path) => mkdir(path, { recursive: true })));
		await writeFile(join(work, "note.txt"), "Fixture note: 42\n");
		const bodies = [];
		const server = createServer((req, res) => {
			let body = "";
			req.on("data", (data) => { body += data; });
			req.on("end", () => {
				bodies.push(body);
				res.writeHead(200, { "Content-Type": "text/event-stream" });
				const chunk = (delta, finish_reason = null) => `data: ${JSON.stringify({ id: "test", object: "chat.completion.chunk", created: 0,
					model: "test", choices: [{ index: 0, delta, finish_reason }] })}\n\n`;
				if (bodies.length === 1) {
					res.write(chunk({ role: "assistant", tool_calls: [{ index: 0, id: "call_1", type: "function",
						function: { name: scenario.called, arguments: JSON.stringify({ path: "note.txt" }) } }] }));
					res.write(chunk({}, "tool_calls"));
				} else {
					res.write(chunk({ role: "assistant", content: "Done." }));
					res.write(chunk({}, "stop"));
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
			const settled = new Promise((resolve, reject) => {
				const timer = setTimeout(() => reject(new Error(`Pi did not settle: ${stderr.slice(-1000)}`)), 12_000);
				child.stdout.on("data", (data) => {
					buffer += data;
					for (let end; (end = buffer.indexOf("\n")) >= 0;) {
						const line = buffer.slice(0, end); buffer = buffer.slice(end + 1);
						let event;
						try { event = JSON.parse(line); } catch { continue; }
						events.push(event);
						if (event.type === "extension_error") { clearTimeout(timer); reject(new Error(line)); }
						if (event.type === "agent_settled") { clearTimeout(timer); resolve(event); }
					}
				});
				child.on("exit", (code) => { clearTimeout(timer); reject(new Error(`Pi exited ${code}: ${stderr.slice(-1000)}`)); });
			});
			child.stdin.write(JSON.stringify({ type: "prompt", message: "Read the note." }) + "\n");
			await settled;
			const ends = events.filter((event) => event.type === "tool_execution_end");
			assert.equal(ends.length, 1, JSON.stringify(ends));
			assert.equal(ends[0].toolName, scenario.ran);
			assert.equal(ends[0].isError, !scenario.ok, JSON.stringify(ends[0].result));
			const result = ends[0].result.content.map((part) => part.text).join("\n");
			if (scenario.ok) assert.match(result, /Fixture note: 42/);
			else assert.match(result, /Tool invented_read not found/);
			// The model sees its own call under the name that ran, so the next turn uses the right name.
			const history = JSON.parse(bodies[1]).messages.find((message) => message.role === "assistant");
			assert.equal(history.tool_calls[0].function.name, scenario.ran);
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
