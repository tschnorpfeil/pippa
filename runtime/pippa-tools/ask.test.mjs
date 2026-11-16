// `ask` (ask.ts): what the person sees and what the model reads back, without Pi and without a model.
//
//   node --experimental-strip-types --test runtime/pippa-tools/ask.test.mjs
import assert from "node:assert/strict";
import { test } from "node:test";

const { ask, askTool, cleanChoices, otherChoice } = await import("./ask.ts");

/** A fake card: records what was shown and answers from a script. */
function card(...answers) {
	const shown = [];
	return {
		shown,
		select: async (title, options) => { shown.push({ select: title, options }); return answers.shift(); },
		input: async (title) => { shown.push({ input: title }); return answers.shift(); },
	};
}

test("a choice: the choices plus one for their own words, and the answer goes back to the model", async () => {
	const ui = card("Lena Berger");
	const text = await ask({ question: "Welche Lena meinst du?", choices: ["Lena Berger", "Lena Koch"] }, ui, "de");
	assert.deepEqual(ui.shown, [{ select: "Welche Lena meinst du?", options: ["Lena Berger", "Lena Koch", "Etwas anderes …"] }]);
	assert.equal(text, 'The person answered: "Lena Berger". Go on with that; do not ask again about the same thing.');
});

test("their own words: the extra choice opens a text field; no choices asks in words right away", async () => {
	const other = card("Something else…", "  Lena from work  ");
	assert.match(await ask({ question: "Which Lena?", choices: ["Lena B.", "Lena K."] }, other, "en"), /answered: "Lena from work"/);
	assert.deepEqual(other.shown.map((s) => Object.keys(s)[0]), ["select", "input"]);
	const open = card("Rom");
	assert.match(await ask({ question: "Wohin geht die Reise?" }, open, "de"), /answered: "Rom"/);
	assert.deepEqual(open.shown, [{ input: "Wohin geht die Reise?" }]);
});

test("a closed card, an empty answer or no app: never ask again, go on and name the assumption", async () => {
	for (const answers of [[undefined], ["Etwas anderes …", undefined], ["Etwas anderes …", "   "]]) {
		const text = await ask({ question: "Welche?", choices: ["A", "B"] }, card(...answers), "de");
		assert.match(text, /^No answer: .*Do not ask again\. .*what you assumed/);
	}
	assert.match(await ask({ question: "Welche?", choices: ["A", "B"] }, undefined, "de"), /^No one can answer now\. Do not ask\./);
	assert.match(await ask({ question: "   " }, card("x"), "de"), /^Not asked: question is empty/);
});

test("choices: trimmed, distinct, never the extra one, at most four", () => {
	const other = otherChoice("de");
	assert.deepEqual(cleanChoices([" A ", "a", "", null, other, "B\n2", "C", "D", "E"], other), ["A", "B 2", "C", "D"]);
	assert.deepEqual(cleanChoices("A", other), []);
	assert.equal(otherChoice("en-GB"), "Something else…");
});

test("the tool: Pi's card when the app is there, the no-one text when it is not", async () => {
	const tool = askTool();
	assert.equal(tool.name, "ask");
	assert.ok(tool.description.length < 260, "every word costs prompt time with the local model");
	const ui = card("A");
	const shown = await tool.execute("1", { question: "Q?", choices: ["A", "B"] }, undefined, undefined, { hasUI: true, ui });
	assert.match(shown.content[0].text, /answered: "A"/);
	assert.equal(shown.details.asked, true);
	const headless = await tool.execute("2", { question: "Q?", choices: ["A", "B"] }, undefined, undefined, { hasUI: false, ui });
	assert.match(headless.content[0].text, /^No one can answer now/);
	assert.equal(ui.shown.length, 1, "no card without the app");
});

const payload = process.env.PIPPA_PI_PAYLOAD;
const cli = process.env.PIPPA_PI_CLI
	|| (payload ? `${payload}/release/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js` : undefined);

test("real Pi: the model's ask shows Pi's select with the extra choice, and the answer comes back as the tool result", {
	skip: !cli && "PIPPA_PI_CLI not set", timeout: 60_000,
}, async () => {
	const { spawn } = await import("node:child_process");
	const { createServer } = await import("node:http");
	const { mkdirSync, mkdtempSync, writeFileSync } = await import("node:fs");
	const { join } = await import("node:path");
	const { fileURLToPath } = await import("node:url");
	const here = fileURLToPath(new URL(".", import.meta.url));
	mkdirSync(join(here, "../../.build"), { recursive: true });
	const root = mkdtempSync(join(here, "../../.build/pippa-ask-realpi-"));
	const home = join(root, "home"), agent = join(home, ".pi/agent"), work = join(root, "work");
	for (const dir of [agent, work]) mkdirSync(dir, { recursive: true });
	let turn = 0, toolResult;
	const chunk = (delta, finish = null) => `data: ${JSON.stringify({ id: "x", object: "chat.completion.chunk", created: 0, model: "m", choices: [{ index: 0, delta, finish_reason: finish }] })}\n\n`;
	const server = createServer((req, res) => {
		let body = "";
		req.on("data", (c) => (body += c));
		req.on("end", () => {
			const request = JSON.parse(body);
			res.writeHead(200, { "Content-Type": "text/event-stream" });
			if (turn++ === 0) {
				res.end(chunk({ role: "assistant", tool_calls: [{ index: 0, id: "a1", type: "function", function: { name: "ask",
					arguments: JSON.stringify({ question: "Welche Lena?", choices: ["Lena Berger", "Lena Koch"] }) } }] }, "tool_calls") + "data: [DONE]\n\n");
			} else {
				toolResult = request.messages.filter((m) => m.role === "tool").map((m) => (typeof m.content === "string" ? m.content : JSON.stringify(m.content))).join("\n");
				res.end(chunk({ role: "assistant", content: "ok" }, "stop") + "data: [DONE]\n\n");
			}
		});
	}).listen(0, "127.0.0.1");
	await new Promise((done) => server.once("listening", done));
	writeFileSync(join(agent, "models.json"), JSON.stringify({ providers: { "pippa-local": { baseUrl: `http://127.0.0.1:${server.address().port}/v1`,
		api: "openai-completions", apiKey: "x", models: [{ id: "m", name: "M", contextWindow: 16384, maxTokens: 4096 }] } } }));
	const env = { HOME: home, PATH: process.env.PATH, PI_CODING_AGENT_DIR: agent, PI_OFFLINE: "1", PI_SKIP_VERSION_CHECK: "1", PI_TELEMETRY: "0",
		PIPPA_LANGUAGE: "de", PIPPA_MEMORY_FILE: join(root, "memory.md") };
	const child = spawn(process.execPath, [cli, "--mode", "rpc", "--no-session", "--no-context-files", "--no-extensions", "--no-approve",
		"--extension", join(here, "pippa-tools.ts"), "--tools", "read,ask", "--provider", "pippa-local", "--model", "m"], { cwd: work, env, stdio: ["pipe", "pipe", "pipe"] });
	let err = "", buffer = "";
	const asked = [];
	child.stderr.on("data", (d) => (err += d));
	try {
		await new Promise((done, fail) => {
			const timer = setTimeout(() => fail(new Error(`no answer: ${err.slice(-500)}`)), 50_000);
			child.stdout.on("data", (d) => {
				buffer += d;
				for (let i; (i = buffer.indexOf("\n")) >= 0;) {
					const line = buffer.slice(0, i);
					buffer = buffer.slice(i + 1);
					let event;
					try { event = JSON.parse(line); } catch { continue; }
					if (event.type === "extension_error") { clearTimeout(timer); fail(new Error(line)); }
					if (event.type === "extension_ui_request" && ["select", "input"].includes(event.method)) {
						asked.push({ method: event.method, title: event.title, options: event.options });
						child.stdin.write(JSON.stringify({ type: "extension_ui_response", id: event.id, value: "Lena Koch" }) + "\n");
					}
					if (event.type === "agent_settled") { clearTimeout(timer); done(); }
				}
			});
			child.stdin.write(JSON.stringify({ type: "prompt", message: "Schreib Lena" }) + "\n");
		});
	} finally {
		child.kill();
		server.close();
	}
	assert.deepEqual(asked, [{ method: "select", title: "Welche Lena?", options: ["Lena Berger", "Lena Koch", "Etwas anderes …"] }]);
	assert.match(toolResult ?? "", /The person answered: \\?"Lena Koch\\?"/);
});
