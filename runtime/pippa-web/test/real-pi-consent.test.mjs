// The web consent in real Pi across a restart: Pippa ends Pi when the person switches conversations and resumes the
// session later (`--session-id`). A yes in one conversation must hold when it is resumed, and not in another one.
// Scripted local model; the search goes to a closed local proxy port, so nothing leaves this Mac.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

const here = fileURLToPath(new URL(".", import.meta.url));
const extension = join(here, "..", "index.ts");
const cli = join(here, "..", "node_modules", "@earendil-works", "pi-coding-agent", "dist", "cli.js");

test("real Pi: a search yes holds when the conversation is resumed in a new Pi, not in another conversation", { timeout: 60_000 }, async () => {
	const home = mkdtempSync(join(tmpdir(), "pippa-web-consent-"));
	const agent = join(home, ".pi", "agent"), sessions = join(home, "sessions");
	mkdirSync(agent, { recursive: true }); mkdirSync(sessions, { recursive: true });
	const server = createServer((req, res) => {
		let body = "";
		req.on("data", (data) => { body += data; });
		req.on("end", () => {
			const messages = JSON.parse(body).messages;
			const answered = messages.at(-1)?.role === "tool";
			res.writeHead(200, { "Content-Type": "text/event-stream" });
			const chunk = (delta, finish_reason = null) => `data: ${JSON.stringify({ id: "t", object: "chat.completion.chunk", created: 0,
				model: "test", choices: [{ index: 0, delta, finish_reason }] })}\n\n`;
			if (answered) {
				res.write(chunk({ role: "assistant", content: "Done." }));
				res.write(chunk({}, "stop"));
			} else {
				res.write(chunk({ role: "assistant", tool_calls: [{ index: 0, id: `call_${messages.length}`, type: "function",
					function: { name: "web_search", arguments: JSON.stringify({ query: "DAX heute", proxy: "http://127.0.0.1:9" }) } }] }));
				res.write(chunk({}, "tool_calls"));
			}
			res.end("data: [DONE]\n\n");
		});
	});
	await new Promise((done) => server.listen(0, "127.0.0.1", done));
	writeFileSync(join(agent, "models.json"), JSON.stringify({ providers: { "pippa-local": {
		baseUrl: `http://127.0.0.1:${server.address().port}/v1`, api: "openai-completions", apiKey: "fixture",
		models: [{ id: "test", name: "Test", contextWindow: 16384, maxTokens: 1024 }],
	} } }));
	/** One Pi process, one prompt in session `id`; returns how often Pippa was asked. */
	const answer = async (id) => {
		const env = { ...process.env, HOME: home, PI_CODING_AGENT_DIR: agent, PIPPA_WEB_DIR: join(home, "pippa-web"),
			PI_OFFLINE: "1", PI_TELEMETRY: "0", PI_SKIP_VERSION_CHECK: "1", PIPPA_LANGUAGE: "de" };
		delete env.XDG_CONFIG_HOME;
		const child = spawn(process.execPath, [cli, "--mode", "rpc", "--session-dir", sessions, "--session-id", id, "--no-context-files",
			"--no-skills", "--no-extensions", "--extension", extension, "--tools", "web_search", "--system-prompt", "You are a test.",
			"--provider", "pippa-local", "--model", "test"], { env, cwd: home, stdio: ["pipe", "pipe", "pipe"] });
		let stderr = "", buffer = "", asked = 0;
		child.stderr.on("data", (data) => { stderr += data; });
		try {
			await new Promise((resolve, reject) => {
				const timer = setTimeout(() => reject(new Error(`Pi did not settle: ${stderr.slice(-1000)}`)), 20_000);
				child.stdout.on("data", (data) => {
					buffer += data;
					for (let end; (end = buffer.indexOf("\n")) >= 0;) {
						const line = buffer.slice(0, end); buffer = buffer.slice(end + 1);
						let event;
						try { event = JSON.parse(line); } catch { continue; }
						if (event.type === "extension_ui_request" && event.method === "confirm") {
							asked++;
							child.stdin.write(JSON.stringify({ type: "extension_ui_response", id: event.id, confirmed: true }) + "\n");
						}
						if (event.type === "extension_error") { clearTimeout(timer); reject(new Error(line)); }
						if (event.type === "agent_settled") { clearTimeout(timer); resolve(); }
					}
				});
				child.on("exit", (code) => { clearTimeout(timer); reject(new Error(`Pi exited ${code}: ${stderr.slice(-1000)}`)); });
				child.stdin.write(JSON.stringify({ type: "prompt", message: "Was ist heute an der Börse los?" }) + "\n");
			});
		} finally {
			child.kill("SIGKILL");
		}
		return asked;
	};
	try {
		assert.equal(await answer("conversation-a"), 1, "the first search of a conversation asks");
		assert.equal(await answer("conversation-a"), 0, "resumed in a new Pi, the conversation keeps the yes");
		assert.equal(await answer("conversation-b"), 1, "another conversation asks again");
	} finally {
		server.closeAllConnections();
		await new Promise((done) => server.close(done));
		rmSync(home, { recursive: true, force: true });
	}
});
