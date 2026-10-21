// Scripted-provider lifecycle checks, not an evaluation of model reasoning or native macOS permissions.
// Verify that a useful remaining step can complete after a native failure or partial task success.
import assert from "node:assert/strict";
import { spawn, execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

const payload = process.env.PIPPA_PI_PAYLOAD;
const cli = process.env.PIPPA_PI_CLI
	|| (payload && join(payload, "release/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js"));
const node = process.env.PIPPA_PI_NODE || (payload && existsSync(join(payload, "bin/node")) ? join(payload, "bin/node") : process.execPath);
const here = fileURLToPath(new URL(".", import.meta.url));
const build = join(here, "../../.build");
const nativeTool = "mcp__pippa__reminder_add";

for (const outcome of ["denied", "unavailable", "completed", "unclear"]) {
	test(`real Pi recovery: ${outcome} native action preserves a useful remaining read`, {
		skip: !cli && "PIPPA_PI_CLI or PIPPA_PI_PAYLOAD not set", timeout: 30_000,
	}, async () => {
		assert.match(execFileSync(node, [cli, "--version"], { encoding: "utf8" }).trim(), /^1\.3\./);
		await mkdir(build, { recursive: true });
		const root = await mkdtemp(join(build, "pippa-recovery-realpi-"));
		const agent = join(root, "agent"), work = join(root, "work");
		await Promise.all([agent, work].map((path) => mkdir(path, { recursive: true })));
		const effects = join(work, "effects.txt"), fixture = join(root, "native-fixture.ts");
		const hasEffect = outcome === "completed" || outcome === "unclear";
		const result = outcome === "completed" ? { done: true, status: "created", dispatched: true, title: "Fixture" }
			: outcome === "unclear" ? { done: false, status: "unclear", dispatched: true, tell: "Check Reminders before trying again." }
			: { done: false, status: outcome, dispatched: false, tell: "No reminder was created." };
		await writeFile(join(work, "task.txt"), "Call the fixture dentist at 09:00.\n");
		await writeFile(fixture, `import { appendFile } from "node:fs/promises";
export default function (pi) {
  pi.registerTool({ name: ${JSON.stringify(nativeTool)}, label: "Fixture reminder", description: "Synthetic native result",
    parameters: { type: "object", properties: { title: { type: "string" } }, required: ["title"] },
    async execute() {
      await appendFile(${JSON.stringify(effects)}, ${JSON.stringify(hasEffect ? "created\n" : "attempted\n")});
      return { content: [{ type: "text", text: ${JSON.stringify(JSON.stringify(result))} }] };
    }
  });
}`);
		const steps = [
			{ name: nativeTool, args: { title: "Fixture" } },
			{ name: "read", args: { path: "missing.txt" } },
			{ name: "read", args: { path: "task.txt" } },
			...(hasEffect ? [{ name: nativeTool, args: { title: "Fixture" } }] : []),
		];
		const finalText = outcome === "completed" ? "Reminder created. Call the fixture dentist at 09:00."
			: outcome === "unclear" ? "Check Reminders before trying again. Call the fixture dentist at 09:00."
			: "The reminder could not be created. Call the fixture dentist at 09:00.";
		let requests = 0;
		const providerMessages = [];
		const server = createServer((req, res) => {
			let body = "";
			req.on("data", (chunk) => { body += chunk; });
			req.on("end", () => {
				providerMessages.push(JSON.parse(body).messages);
				const step = steps[requests++];
				const chunk = (delta, finish_reason = null) => `data: ${JSON.stringify({ id: "fixture", object: "chat.completion.chunk",
					created: 0, model: "test", choices: [{ index: 0, delta, finish_reason }] })}\n\n`;
				res.writeHead(200, { "Content-Type": "text/event-stream" });
				if (step) {
					res.write(chunk({ role: "assistant", tool_calls: [{ index: 0, id: `call_${requests}`, type: "function",
						function: { name: step.name, arguments: JSON.stringify(step.args) } }] }));
					res.write(chunk({}, "tool_calls"));
				} else {
					res.write(chunk({ role: "assistant", content: finalText }));
					res.write(chunk({}, "stop"));
				}
				res.end("data: [DONE]\n\n");
			});
		});
		let child;
		try {
			await new Promise((resolve, reject) => { server.once("error", reject); server.listen(0, "127.0.0.1", resolve); });
			await writeFile(join(agent, "models.json"), JSON.stringify({ providers: { "pippa-local": {
				baseUrl: `http://127.0.0.1:${server.address().port}/v1`, api: "openai-completions", apiKey: "fixture",
				models: [{ id: "test", name: "Test", contextWindow: 16384, maxTokens: 1024 }],
			} } }));
			child = spawn(node, [cli, "--mode", "rpc", "--no-session", "--no-context-files", "--no-approve", "--no-skills", "--no-extensions",
				"--extension", join(here, "pippa-assist.ts"), "--extension", fixture, "--tools", `read,${nativeTool}`,
				"--system-prompt", "You are a scripted test.", "--provider", "pippa-local", "--model", "test"], {
				cwd: work, env: { HOME: root, PATH: process.env.PATH, PI_CODING_AGENT_DIR: agent,
					PI_OFFLINE: "1", PI_SKIP_VERSION_CHECK: "1", PI_TELEMETRY: "0" }, stdio: ["pipe", "pipe", "pipe"],
			});
			let buffer = "", stderr = "", timer;
			const events = [];
			child.stderr.on("data", (data) => { stderr += data; });
			const settled = await new Promise((resolve, reject) => {
				timer = setTimeout(() => reject(new Error(`Pi did not settle: ${stderr.slice(-1000)}`)), 15_000);
				child.once("error", reject);
				child.once("exit", (code) => reject(new Error(`Pi exited ${code}: ${stderr.slice(-1000)}`)));
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
				child.stdin.write(JSON.stringify({ type: "prompt", message: "Make the fixture reminder and read task.txt. Preserve completed actions and report any remaining failure." }) + "\n");
			}).finally(() => clearTimeout(timer));
			assert.equal(settled.aborted, false, stderr);
			assert.equal(requests, steps.length + 1, "recovery finishes within its fixed call budget");
			assert.equal(await readFile(effects, "utf8"), hasEffect ? "created\n" : "attempted\n", "the native adapter runs only once");
			const ends = events.filter((event) => event.type === "tool_execution_end");
			assert.equal(ends.length, steps.length);
			assert.equal(ends[1].isError, true, "the first read really fails");
			assert.equal(ends[2].isError, false, "the repaired read still runs");
			assert.match(JSON.stringify(ends[2].result), /Call the fixture dentist at 09:00/);
			if (hasEffect) {
				const blocked = JSON.parse(ends[3].result.content[0].text);
				assert.equal(blocked.status, "not_dispatched");
				assert.match(blocked.tell, outcome === "completed" ? /already worked/ : /unclear outcome/);
			}
			assert.equal(events.filter((event) => event.type === "entry_appended" && event.entry?.customType === "pippa-loop-stop").length, 0);
			const toolMessages = providerMessages.at(-1).filter((message) => message.role === "tool");
			assert.match(JSON.stringify(toolMessages), /Call the fixture dentist at 09:00/, "the model receives the successful remaining source");
			assert.deepEqual(JSON.parse(toolMessages.find((message) => message.tool_call_id === "call_1").content), result,
				"the model retains the exact native outcome while repairing the independent read");
			assert.ok(events.some((event) => event.type === "message_end" && event.message?.role === "assistant"
				&& event.message.content?.some((part) => part.type === "text" && part.text === finalText)));
		} finally {
			if (child && child.exitCode === null && child.signalCode === null) {
				child.kill("SIGKILL"); await new Promise((resolve) => child.once("exit", resolve));
			}
			server.closeAllConnections(); await new Promise((resolve) => server.close(resolve));
			await rm(root, { recursive: true, force: true });
		}
	});
}
