// Exercises shipped registration and admission without provider calls; one scripted local model checks MCP schemas.
// All data and endpoints are disposable fixtures.
// PIPPA_PI_PAYLOAD=<payload> node --experimental-strip-types --test runtime/pippa-tools/real-pi-readiness.test.mjs
// PIPPA_PI_EXTENSIONS_DIR optionally selects trusted built extensions; see docs/development.md for the signed-app check.
import assert from "node:assert/strict";
import { spawn, execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { DRAFT_TOOLS, DRAFT_LAUNCH_TOOLS, POLICY_COMMAND } from "./pippa-policy.ts";
import { READINESS_COMMAND, REQUIRED_TOOLS } from "./pippa-mcp.ts";

const payload = process.env.PIPPA_PI_PAYLOAD;
const cli = process.env.PIPPA_PI_CLI || (payload && join(payload, "release/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js"));
const node = process.env.PIPPA_PI_NODE || (payload && existsSync(join(payload, "bin/node")) ? join(payload, "bin/node") : process.execPath);
const here = fileURLToPath(new URL(".", import.meta.url));
const build = join(here, "../../.build");
const extensionsDirectory = process.env.PIPPA_PI_EXTENSIONS_DIR || here;
// Read the production allowlist so this test also catches changes to dynamic MCP wildcard activation.
const launchSource = await readFile(join(here, "../../app/Sources/PiRPC/PippaPiLaunch.swift"), "utf8");
const productionTools = [...launchSource.match(/public static let tools = \[([\s\S]*?)\]/)[1].matchAll(/"([^"]+)"/g)].map((match) => match[1]);
const pippaExtensions = ["pippa-policy.ts", "pippa-tools.ts", "pippa-assist.ts", "pippa-memory.ts", "pippa-context.ts", "pippa-mcp.ts"];
const preparationSchema = { type: "object", additionalProperties: false, required: ["paths"], properties: {
	paths: { type: "array", items: { type: "string" }, minItems: 1, maxItems: 50 },
	quality: { enum: ["original", "balanced", "compact"] }, size_limit_mb: { enum: [5, 10, 20] },
} };


for (const scenario of ["ready", "draft-only", "collision", "missing-file-preparation", "authentication-failure", "file-preparation-enums"]) {
	test(`real Pi native admission: ${scenario}, ${scenario === "file-preparation-enums" ? "then enum-only MCP arguments reach the tool" : "with no provider request"}`, {
		skip: !cli && "PIPPA_PI_PAYLOAD or PIPPA_PI_CLI not set", timeout: 25_000,
	}, async () => {
		assert.match(execFileSync(node, [cli, "--version"], { encoding: "utf8" }).trim(), /^1\.4\./);
		await mkdir(build, { recursive: true });
		const root = await mkdtemp(join(build, "pippa-readiness-realpi-"));
		const agent = join(root, "agent"), work = join(root, "work");
		await Promise.all([agent, work].map((path) => mkdir(path, { recursive: true })));
		let providerRequests = 0, discoveries = 0, settled;
		const providerBodies = [], nativeCalls = [];
		const preparationInput = { paths: [join(work, "second.pdf"), join(work, "first.jpg")], quality: "balanced", size_limit_mb: 5 };
		const token = "ab".repeat(32);
		const server = createServer((req, res) => {
			if (req.url !== "/mcp") {
				providerRequests++;
				if (scenario !== "file-preparation-enums") { res.writeHead(500); res.end(); return; }
				let body = "";
				req.on("data", (chunk) => { body += chunk; });
				req.on("end", () => {
					providerBodies.push(JSON.parse(body));
					res.writeHead(200, { "Content-Type": "text/event-stream" });
					const chunk = (delta, finish_reason) => `data: ${JSON.stringify({ id: "fixture", object: "chat.completion.chunk", created: 0,
						model: "test", choices: [{ index: 0, delta, finish_reason }] })}\n\n`;
					if (providerRequests === 1) {
						res.write(chunk({ role: "assistant", tool_calls: [{ index: 0, id: "prepare_fixture", type: "function",
							function: { name: "mcp__pippa__prepare_files", arguments: JSON.stringify(preparationInput) } }] }, null));
						res.write(chunk({}, "tool_calls"));
					} else { res.write(chunk({ role: "assistant", content: "Fixture PDF prepared." }, "stop")); }
					res.end("data: [DONE]\n\n");
				});
				return;
			}
			if (scenario === "authentication-failure" || req.headers.authorization !== `Bearer ${token}`) {
				res.writeHead(403); res.end(); return;
			}
			if (req.method !== "POST") { res.writeHead(405); res.end(); return; }
			let text = "";
			req.on("data", (chunk) => { text += chunk; });
			req.on("end", () => {
				const request = JSON.parse(text);
				if (request.id === undefined) { res.writeHead(202); res.end(); return; }
				let result;
				if (request.method === "initialize") result = { protocolVersion: "2024-11-05", capabilities: { tools: {} }, serverInfo: { name: "pippa-fixture", version: "1" } };
				else if (request.method === "tools/list") {
					discoveries++;
					result = { tools: REQUIRED_TOOLS.filter((name) => scenario !== "missing-file-preparation" || name !== "mcp__pippa__prepare_files")
						.map((name) => ({ name: name.replace("mcp__pippa__", ""), description: "Fixture tool",
							inputSchema: name === "mcp__pippa__prepare_files" ? preparationSchema : { type: "object", properties: {} } })) };
				} else if (request.method === "tools/call") {
					nativeCalls.push(request.params);
					result = { content: [{ type: "text", text: JSON.stringify({ done: true, dispatched: true }) }], isError: false };
				} else result = {};
				res.writeHead(200, { "Content-Type": "application/json" });
				res.end(JSON.stringify({ jsonrpc: "2.0", id: request.id, result }));
			});
		});
		let child;
		try {
			await new Promise((resolve, reject) => { server.once("error", reject); server.listen(0, "127.0.0.1", resolve); });
			const base = `http://127.0.0.1:${server.address().port}`;
			await writeFile(join(agent, "models.json"), JSON.stringify({ providers: { "pippa-local": {
				baseUrl: `${base}/v1`, api: "openai-completions", apiKey: "fixture",
				models: [{ id: "test", name: "Test", contextWindow: 16384, maxTokens: 1024 }],
			} } }));
			const marker = join(root, "unrelated-server-started");
			const configured = JSON.stringify({ mcpServers: {
				pippa: { enabled: false, url: `${base}/unrelated` },
				unrelated_http: { url: `${base}/unrelated`, exposure: "direct" },
				unrelated_process: { command: node, args: ["-e", `require("node:fs").writeFileSync(${JSON.stringify(marker)}, "started")`] },
			} });
			if (scenario === "collision") {
				await writeFile(join(agent, "mcp.json"), configured);
				await mkdir(join(work, ".pi"));
				await writeFile(join(work, ".pi/mcp.json"), configured);
			}
			child = spawn(node, [cli, "--mode", "rpc", "--no-session", "--no-context-files", "--no-approve", "--no-skills", "--no-extensions",
				...pippaExtensions.flatMap((name) => ["--extension", join(extensionsDirectory, name)]), "--tools", (scenario === "draft-only" ? DRAFT_LAUNCH_TOOLS : productionTools).join(","),
				"--provider", "pippa-local", "--model", "test"], {
				cwd: work, env: { HOME: root, PATH: process.env.PATH, PI_CODING_AGENT_DIR: agent,
					PIPPA_ACTION_POLICY: scenario === "draft-only" ? "draftOnly" : "standard", PIPPA_MCP_URL: `${base}/mcp`, PIPPA_MCP_TOKEN: token, PI_OFFLINE: "1", PI_SKIP_VERSION_CHECK: "1", PI_TELEMETRY: "0" },
				stdio: ["pipe", "pipe", "pipe"],
			});
			let stderr = "", buffer = "", serial = 0;
			const entries = [], notices = [], pending = new Map();
			child.stderr.on("data", (data) => { stderr += data; });
			child.stdout.on("data", (data) => {
				buffer += data;
				for (let end; (end = buffer.indexOf("\n")) >= 0;) {
					const line = buffer.slice(0, end); buffer = buffer.slice(end + 1);
					let event; try { event = JSON.parse(line); } catch { continue; }
					if (event.type === "entry_appended") entries.push(event.entry);
					if (event.type === "extension_ui_request" || event.type === "extension_error") notices.push(event);
					if (event.type === "response") pending.get(event.id)?.resolve(event);
					if (event.type === "agent_settled") settled?.resolve(event);
				}
			});
			child.on("error", (error) => { for (const waiter of pending.values()) waiter.reject(error); });
			child.on("exit", (code) => { for (const waiter of pending.values()) waiter.reject(new Error(`Pi exited ${code}: ${stderr.slice(-1000)}`)); });
			async function command(type, fields = {}) {
				const id = `ready-${++serial}`; let timer;
				try {
					return await new Promise((resolve, reject) => {
						pending.set(id, { resolve, reject });
						timer = setTimeout(() => reject(new Error(`No ${type} response: ${stderr.slice(-1000)}`)), 12_000);
						child.stdin.write(JSON.stringify({ id, type, ...fields }) + "\n");
					});
				} finally { clearTimeout(timer); pending.delete(id); }
			}
			const commands = await command("get_commands");
			assert.ok(commands.data.commands.some((entry) => entry.name === READINESS_COMMAND && entry.source === "extension"));
			const nonce = randomUUID();
			const response = await command("prompt", { message: `/${READINESS_COMMAND} ${nonce}` });
			assert.equal(response.data.disposition, "handled", stderr);
			const receipts = entries.filter((entry) => entry.customType === READINESS_COMMAND);
			assert.equal(receipts.length, 1, stderr);
			assert.equal(receipts[0].data.nonce, nonce);
			const unavailable = scenario === "authentication-failure" || scenario === "missing-file-preparation";
			assert.equal(receipts[0].data.status, unavailable ? "toolsUnavailable" : "ready", JSON.stringify({ receipt: receipts[0].data, stderr, notices, discoveries, log: await readFile(join(agent, "mcp.log"), "utf8").catch(() => "") }));
			assert.equal(providerRequests, 0, "readiness must never call a model");
			if (!unavailable) {
				assert.ok(discoveries > 0);
				assert.deepEqual(receipts[0].data.registeredTools, REQUIRED_TOOLS);
				assert.deepEqual(receipts[0].data.tools, scenario === "draft-only" ? DRAFT_TOOLS.filter((name) => name.startsWith("mcp__")) : REQUIRED_TOOLS);
				assert.ok(commands.data.commands.some((entry) => entry.name === POLICY_COMMAND && entry.source === "extension"));
				await command("prompt", { message: `/${POLICY_COMMAND} ${nonce}` });
				const scope = entries.find((entry) => entry.customType === POLICY_COMMAND).data;
				assert.equal(scope.status, "ready");
				assert.equal(scope.policy, scenario === "draft-only" ? "draftOnly" : "standard");
				if (scenario === "draft-only") assert.deepEqual(new Set(scope.tools), new Set(DRAFT_TOOLS));
				assert.equal(providerRequests, 0);
			}
			if (scenario === "collision") {
				assert.equal(await readFile(join(agent, "mcp.json"), "utf8"), configured);
				assert.equal(await readFile(join(work, ".pi/mcp.json"), "utf8"), configured);
				assert.equal(existsSync(marker), false, "unrelated configured stdio server must never start");
			}
			if (scenario === "file-preparation-enums") {
				let timer;
				try {
					const finished = new Promise((resolve, reject) => { settled = { resolve, reject };
						timer = setTimeout(() => reject(new Error(`No enum-schema completion: ${stderr}`)), 8_000); });
					await command("prompt", { message: "Prepare the fixture PDFs/photos in the specified order, balanced quality and a 5 MB goal." });
					assert.equal((await finished).aborted, false);
				} finally { clearTimeout(timer); settled = undefined; }
				assert.equal(providerRequests, 2, "one scripted tool call and one final response");
				const declared = providerBodies[0].tools.find((tool) => tool.function.name === "mcp__pippa__prepare_files").function.parameters;
				assert.deepEqual(declared.properties.quality.enum, preparationSchema.properties.quality.enum);
				assert.deepEqual(declared.properties.size_limit_mb.enum, preparationSchema.properties.size_limit_mb.enum);
				assert.deepEqual(nativeCalls.map(({ name, arguments: args }) => ({ name, arguments: args })),
					[{ name: "prepare_files", arguments: preparationInput }], "MCP forwards ordered paths and enum arguments unchanged");
			}
		} finally {
			if (child && child.exitCode === null && child.signalCode === null) { child.kill("SIGKILL"); await new Promise((resolve) => child.once("exit", resolve)); }
			server.closeAllConnections(); await new Promise((resolve) => server.close(resolve));
			await rm(root, { recursive: true, force: true });
		}
	});
}
