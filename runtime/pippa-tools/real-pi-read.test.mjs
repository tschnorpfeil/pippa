// Pippa's `read` (document.ts) inside the pinned Pi: a PDF comes back as text in the same tool call, so the model
// needs no second round; Pi's direct RPC shell is refused. Scripted provider, real PDFKit.
//
//   PIPPA_PI_CLI=<release>/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js \
//   node --experimental-strip-types --test runtime/pippa-tools/real-pi-read.test.mjs
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

/** One page, one line of Helvetica text. */
function pdf(text) {
	const stream = `BT /F1 18 Tf 72 720 Td (${text}) Tj ET`;
	const objects = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
		"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >> >>",
		`<< /Length ${stream.length} >>\nstream\n${stream}\nendstream`];
	let body = "%PDF-1.4\n";
	const offsets = objects.map((object, i) => { const at = body.length; body += `${i + 1} 0 obj\n${object}\nendobj\n`; return at; });
	const xref = body.length;
	body += `xref\n0 5\n0000000000 65535 f \n${offsets.map((o) => `${String(o).padStart(10, "0")} 00000 n \n`).join("")}`;
	return body + `trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
}

test("real Pi: read on a PDF returns its text in the same call; the direct RPC shell is refused", {
	skip: (!cli && "PIPPA_PI_CLI or PIPPA_PI_PAYLOAD not set") || (process.platform !== "darwin" && "macOS only"), timeout: 30_000,
}, async () => {
	assert.match(execFileSync(node, [cli, "--version"], { encoding: "utf8" }).trim(), /^1\.5\./);
	const build = join(here, "../../.build"); await mkdir(build, { recursive: true });
	const root = await mkdtemp(join(build, "pippa-read-realpi-"));
	const agent = join(root, "agent"), work = join(root, "work");
	await mkdir(agent); await mkdir(work);
	await writeFile(join(work, "Rechnung.pdf"), pdf("Stadtwerke Betrag 84,20 EUR"));
	const bodies = [];
	let child;
	const server = createServer((req, res) => {
		let body = "";
		req.on("data", (chunk) => { body += chunk; });
		req.on("end", () => {
			bodies.push(JSON.parse(body));
			const first = bodies.length === 1;
			const delta = first ? { role: "assistant", tool_calls: [{ index: 0, id: "read1", type: "function",
				function: { name: "read", arguments: JSON.stringify({ path: "Rechnung.pdf" }) } }] }
				: { role: "assistant", content: "84,20 EUR." };
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
			"--extension", join(here, "pippa-tools.ts"), "--extension", join(here, "pippa-assist.ts"), "--tools", "read,bash",
			"--system-prompt", "You are a scripted test.", "--provider", "pippa-local", "--model", "test"], { cwd: work, env: { HOME: root, PATH: process.env.PATH,
				PI_CODING_AGENT_DIR: agent, PI_OFFLINE: "1", PI_SKIP_VERSION_CHECK: "1", PI_TELEMETRY: "0" }, stdio: ["pipe", "pipe", "pipe"] });
		let buffer = "", stderr = "", serial = 0, waiting;
		const events = [], pending = new Map();
		child.stderr.on("data", (data) => { stderr += data; });
		child.stdout.on("data", (data) => {
			buffer += data;
			for (let end; (end = buffer.indexOf("\n")) >= 0;) {
				const line = buffer.slice(0, end); buffer = buffer.slice(end + 1);
				let event; try { event = JSON.parse(line); } catch { continue; }
				events.push(event);
				if (event.type === "response") pending.get(event.id)?.(event);
				if (event.type === "extension_error") waiting?.reject(new Error(line));
				if (event.type === "agent_settled") waiting?.resolve(event);
			}
		});
		child.once("exit", (code) => waiting?.reject(new Error(`Pi exited ${code}: ${stderr.slice(-1000)}`)));
		const command = (type, fields) => new Promise((resolve, reject) => {
			const id = `c${++serial}`;
			const timer = setTimeout(() => reject(new Error(`No ${type} reply: ${stderr.slice(-1000)}`)), 10_000);
			pending.set(id, (event) => { clearTimeout(timer); resolve(event); });
			child.stdin.write(JSON.stringify({ id, type, ...fields }) + "\n");
		});

		const direct = await command("bash", { command: `printf bypass > ${join(work, "rpc-bypass.txt")}` });
		assert.equal(direct.data.exitCode, 1, JSON.stringify(direct));
		assert.equal(existsSync(join(work, "rpc-bypass.txt")), false, "Pi's RPC shell must never bypass the sandboxed bash");

		let timer;
		const settled = await new Promise((resolve, reject) => {
			waiting = { resolve, reject };
			timer = setTimeout(() => reject(new Error(`Pi did not settle: ${stderr.slice(-1000)}`)), 20_000);
			command("prompt", { message: "Was steht in Rechnung.pdf?" }).catch(reject);
		}).finally(() => clearTimeout(timer));
		assert.equal(settled.aborted, false);
		assert.equal(bodies.length, 2, "one tool round, then the answer");
		const ends = events.filter((event) => event.type === "tool_execution_end");
		assert.equal(ends.length, 1);
		assert.equal(ends[0].isError, false, JSON.stringify(ends[0]));
		assert.match(ends[0].result.content[0].text, /\[Page 1\]\nStadtwerke Betrag 84,20 EUR/);
		const toolMessage = bodies[1].messages.find((message) => message.role === "tool");
		assert.match(JSON.stringify(toolMessage.content), /Stadtwerke Betrag 84,20 EUR/, "the model gets the text in the same round");
		const declared = bodies[0].tools.find((tool) => tool.function.name === "read").function.description;
		assert.match(declared, /PDF/);
	} finally {
		if (child && child.exitCode === null && child.signalCode === null) {
			child.kill("SIGKILL"); await new Promise((resolve) => child.once("exit", resolve));
		}
		server.closeAllConnections(); await new Promise((resolve) => server.close(resolve));
		await rm(root, { recursive: true, force: true });
	}
});
