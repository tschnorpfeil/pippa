// Real Pi and a real filesystem denial; scripted provider, not a model-quality or macOS TCC test.
import assert from "node:assert/strict";
import { spawn, execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { chmod, mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

const payload = process.env.PIPPA_PI_PAYLOAD;
const cli = process.env.PIPPA_PI_CLI || (payload && join(payload, "release/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js"));
const node = process.env.PIPPA_PI_NODE || (payload && existsSync(join(payload, "bin/node")) ? join(payload, "bin/node") : process.execPath);
const here = fileURLToPath(new URL(".", import.meta.url));

test("real Pi preserves folder permission evidence and stops without inventing an empty listing", {
	skip: !cli && "PIPPA_PI_CLI or PIPPA_PI_PAYLOAD not set", timeout: 30_000,
}, async () => {
	assert.match(execFileSync(node, [cli, "--version"], { encoding: "utf8" }).trim(), /^1\.4\./);
	const build = join(here, "../../.build"); await mkdir(build, { recursive: true });
	const root = await mkdtemp(join(build, "pippa-permission-realpi-"));
	const agent = join(root, "agent"), denied = join(root, "denied");
	await mkdir(agent); await mkdir(denied); await chmod(denied, 0);
	let requests = 0, child;
	const server = createServer((req, res) => {
		req.resume(); req.on("end", () => {
			const first = requests++ === 0;
			const delta = first ? { role: "assistant", tool_calls: [{ index: 0, id: "folder", type: "function",
				function: { name: "list_folder", arguments: JSON.stringify({ path: denied }) } }] }
				: { role: "assistant", content: "Folder access was denied. Repair access before trying again." };
			const chunk = (delta, finish_reason = null) => `data: ${JSON.stringify({ id: "fixture", object: "chat.completion.chunk", created: 0,
				model: "test", choices: [{ index: 0, delta, finish_reason }] })}\n\n`;
			res.writeHead(200, { "Content-Type": "text/event-stream" });
			res.end(chunk(delta) + chunk({}, first ? "tool_calls" : "stop") + "data: [DONE]\n\n");
		});
	});
	try {
		await new Promise((resolve, reject) => { server.once("error", reject); server.listen(0, "127.0.0.1", resolve); });
		await writeFile(join(agent, "models.json"), JSON.stringify({ providers: { "pippa-local": {
			baseUrl: `http://127.0.0.1:${server.address().port}/v1`, api: "openai-completions", apiKey: "fixture",
			models: [{ id: "test", name: "Test", contextWindow: 16384, maxTokens: 1024 }],
		} } }));
		child = spawn(node, [cli, "--mode", "rpc", "--no-session", "--no-context-files", "--no-approve", "--no-skills", "--no-extensions",
			"--extension", join(here, "pippa-tools.ts"), "--tools", "list_folder", "--system-prompt", "You are a scripted test.",
			"--provider", "pippa-local", "--model", "test"], { cwd: root, env: { HOME: root, PATH: process.env.PATH,
				PI_CODING_AGENT_DIR: agent, PI_OFFLINE: "1", PI_SKIP_VERSION_CHECK: "1", PI_TELEMETRY: "0" }, stdio: ["pipe", "pipe", "pipe"] });
		let buffer = "", stderr = "", timer; const events = [];
		child.stderr.on("data", (data) => { stderr += data; });
		const settled = await new Promise((resolve, reject) => {
			timer = setTimeout(() => reject(new Error(`Pi did not settle: ${stderr.slice(-1000)}`)), 20_000);
			child.once("error", reject); child.once("exit", (code) => reject(new Error(`Pi exited ${code}: ${stderr.slice(-1000)}`)));
			child.stdout.on("data", (data) => {
				buffer += data;
				for (let end; (end = buffer.indexOf("\n")) >= 0;) {
					const line = buffer.slice(0, end); buffer = buffer.slice(end + 1);
					let event; try { event = JSON.parse(line); } catch { continue; }
					events.push(event);
					if (event.type === "extension_error") reject(new Error(line));
					if (event.type === "agent_settled") resolve(event);
				}
			});
			child.stdin.write(JSON.stringify({ type: "prompt", message: "List the fixture folder once." }) + "\n");
		}).finally(() => clearTimeout(timer));
		assert.equal(settled.aborted, false); assert.equal(requests, 2);
		const ends = events.filter((event) => event.type === "tool_execution_end");
		assert.equal(ends.length, 1); assert.equal(ends[0].isError, true);
		assert.deepEqual(ends[0].result.details.pippaFileAccess, { schema: 1, code: "EACCES", path: denied });
		assert.match(ends[0].result.content[0].text, /Access to this folder was denied/);
	} finally {
		if (child && child.exitCode === null && child.signalCode === null) {
			child.kill("SIGKILL"); await new Promise((resolve) => child.once("exit", resolve));
		}
		server.closeAllConnections(); await new Promise((resolve) => server.close(resolve));
		await chmod(denied, 0o700); await rm(root, { recursive: true, force: true });
	}
});
