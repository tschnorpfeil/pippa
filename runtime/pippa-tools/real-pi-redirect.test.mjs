// A provider request never goes on to another address (transport.ts), with the real Pi and two loopback servers:
// A is the configured endpoint, B the address A redirects to. B must receive no connection and no byte, for an
// OpenAI-compatible and an Anthropic-compatible endpoint and for 307, 308 and 302; a normal streamed answer from A
// still arrives whole.
//
//   PIPPA_PI_PAYLOAD=<payload> node --experimental-strip-types --test runtime/pippa-tools/real-pi-redirect.test.mjs
//
// PIPPA_TOOLS_DIR runs the same test against another copy of the extensions (for a before/after comparison).
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
const extensions = process.env.PIPPA_TOOLS_DIR || here;
const build = join(here, "../../.build");
const QUESTION = "REDIRECT-QUESTION-0b1c";

function listen(server) {
	return new Promise((resolve, reject) => { server.once("error", reject); server.listen(0, "127.0.0.1", () => resolve(`http://127.0.0.1:${server.address().port}`)); });
}

/** One question to `provider`; the assistant's last message. */
async function ask(root, provider) {
	const child = spawn(node, [cli, "--mode", "rpc", "--no-context-files", "--no-approve", "--no-extensions", "--no-skills",
		...["pippa-tools.ts", "pippa-assist.ts"].flatMap((name) => ["--extension", join(extensions, name)]), "--tools", "read",
		"--system-prompt", "You are a scripted test.", "--no-session", "--provider", provider, "--model", "test"], {
		cwd: root, env: { HOME: root, PATH: process.env.PATH, PI_CODING_AGENT_DIR: join(root, "agent"), PI_OFFLINE: "1",
			PI_SKIP_VERSION_CHECK: "1", PI_TELEMETRY: "0" },
		stdio: ["pipe", "pipe", "pipe"],
	});
	let stderr = "", buffer = "", last;
	child.stderr.on("data", (data) => { stderr += data; });
	try {
		return await new Promise((resolve, reject) => {
			const timer = setTimeout(() => reject(new Error(`No answer: ${stderr.slice(-1500)}`)), 30_000);
			child.on("exit", (code) => reject(new Error(`Pi exited ${code}: ${stderr.slice(-1500)}`)));
			child.stdout.on("data", (data) => {
				buffer += data;
				for (let end; (end = buffer.indexOf("\n")) >= 0;) {
					const line = buffer.slice(0, end); buffer = buffer.slice(end + 1);
					let event; try { event = JSON.parse(line); } catch { continue; }
					if (event.type === "message_end" && event.message?.role === "assistant") last = event.message;
					if (event.type === "agent_settled") { clearTimeout(timer); resolve(last); }
				}
			});
			child.stdin.write(JSON.stringify({ id: "q", type: "prompt", message: QUESTION }) + "\n");
		});
	} finally {
		if (child.exitCode === null && child.signalCode === null) { child.kill("SIGKILL"); await new Promise((resolve) => child.once("exit", resolve)); }
	}
}

test("real Pi: a provider's redirect never reaches the other address; a normal streamed answer is unchanged", {
	skip: !cli && "PIPPA_PI_PAYLOAD or PIPPA_PI_CLI not set", timeout: 120_000,
}, async () => {
	assert.match(execFileSync(node, [cli, "--version"], { encoding: "utf8" }).trim(), /^1\.5\./);
	await mkdir(build, { recursive: true });
	const root = await mkdtemp(join(build, "pippa-redirect-realpi-"));
	await mkdir(join(root, "agent"), { recursive: true });
	// B: the address a redirect points to. Every connection and byte counts.
	const other = { connections: 0, bytes: 0 };
	const serverB = createServer((req, res) => { req.on("data", (chunk) => { other.bytes += chunk.length; }); req.on("end", () => { res.writeHead(500); res.end(); }); });
	serverB.on("connection", (socket) => { other.connections++; socket.on("data", (chunk) => { other.bytes += chunk.length; }); });
	let mode = "ok";
	const seenA = [];
	const serverA = createServer((req, res) => {
		let text = "";
		req.on("data", (chunk) => { text += chunk; });
		req.on("end", () => {
			seenA.push({ url: req.url, mode, question: text.includes(QUESTION) });
			if (mode !== "ok") { res.writeHead(Number(mode), { Location: `${baseB}${req.url}` }); res.end(); return; }
			res.writeHead(200, { "Content-Type": "text/event-stream" });
			if (req.url.startsWith("/anthropic")) {
				const event = (type, data) => `event: ${type}\ndata: ${JSON.stringify({ type, ...data })}\n\n`;
				res.write(event("message_start", { message: { id: "m", type: "message", role: "assistant", model: "test", content: [],
					stop_reason: null, usage: { input_tokens: 1, output_tokens: 0 } } }));
				res.write(event("content_block_start", { index: 0, content_block: { type: "text", text: "" } }));
				for (const part of ["Streamed ", "answer ", "B."]) res.write(event("content_block_delta", { index: 0, delta: { type: "text_delta", text: part } }));
				res.write(event("content_block_stop", { index: 0 }));
				res.write(event("message_delta", { delta: { stop_reason: "end_turn" }, usage: { output_tokens: 3 } }));
				res.end(event("message_stop", {}));
				return;
			}
			const chunk = (delta, finish_reason) => `data: ${JSON.stringify({ id: "f", object: "chat.completion.chunk", created: 0, model: "test",
				choices: [{ index: 0, delta, finish_reason }] })}\n\n`;
			res.write(chunk({ role: "assistant", content: "Streamed " }, null));
			res.write(chunk({ content: "answer " }, null));
			res.write(chunk({ content: "A." }, "stop"));
			res.end("data: [DONE]\n\n");
		});
	});
	let baseB;
	try {
		const baseA = await listen(serverA);
		baseB = await listen(serverB);
		const model = [{ id: "test", name: "Test", contextWindow: 16384, maxTokens: 1024 }];
		await writeFile(join(root, "agent/models.json"), JSON.stringify({ providers: {
			compatible: { baseUrl: `${baseA}/v1`, api: "openai-completions", apiKey: "fixture-key", models: model },
			messages: { baseUrl: `${baseA}/anthropic`, api: "anthropic-messages", apiKey: "fixture-key", models: model },
		} }));

		// Ordinary answers, streamed in parts, arrive whole.
		const plain = await ask(root, "compatible");
		assert.equal(plain?.stopReason, "stop", JSON.stringify(plain));
		assert.equal(plain.content.map((part) => part.text ?? "").join(""), "Streamed answer A.");
		const messages = await ask(root, "messages");
		assert.equal(messages?.stopReason, "stop", JSON.stringify(messages));
		assert.equal(messages.content.map((part) => part.text ?? "").join(""), "Streamed answer B.");

		for (const status of ["307", "308", "302"]) {
			for (const provider of ["compatible", "messages"]) {
				mode = status;
				const before = seenA.length;
				const answer = await ask(root, provider);
				assert.ok(seenA.slice(before).some((request) => request.question), `${provider} ${status}: the request reached A`);
				assert.equal(answer?.stopReason, "error", `${provider} ${status}: ${JSON.stringify(answer)}`);
				assert.deepEqual(other, { connections: 0, bytes: 0 }, `${provider} ${status}: B received nothing`);
			}
		}
	} finally {
		for (const server of [serverA, serverB]) { server.closeAllConnections(); await new Promise((resolve) => server.close(resolve)); }
		await rm(root, { recursive: true, force: true });
	}
});
