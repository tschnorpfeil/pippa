// Pippa's own settings, grants, history, notes and Pi's credentials stay out of reach of every tool the model can
// call (protected.ts), with the real Pi, the launch the app gives the AI on this Mac and an online AI with Mac access
// (issue #196), and the environment PiSession sets. Synthetic markers in a fake home folder only.
//
//   PIPPA_PI_PAYLOAD=<payload> node --experimental-strip-types --test runtime/pippa-tools/real-pi-protected.test.mjs
//
// The scripted model reaches for the settings file, the pinned credential folder, the shared ~/.pi credentials, the
// notes file and another session's history, by absolute path, through a symlink, in other letter case and through the
// /System/Volumes/Data firmlink, with read, write, list_folder, move_files, the app's document reader and the shell
// (with every shell question answered yes). Nothing of it reaches the provider and nothing changes; a letter in the
// working folder and a document in the home folder are still read.
import assert from "node:assert/strict";
import { spawn, execFileSync } from "node:child_process";
import { existsSync, realpathSync } from "node:fs";
import { mkdir, mkdtemp, readdir, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { fileURLToPath, pathToFileURL } from "node:url";
import { test } from "node:test";
import { READINESS_COMMAND, REQUIRED_TOOLS } from "./pippa-mcp.ts";

const payload = process.env.PIPPA_PI_PAYLOAD;
const cli = process.env.PIPPA_PI_CLI || (payload && join(payload, "release/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js"));
const node = process.env.PIPPA_PI_NODE || (payload && existsSync(join(payload, "bin/node")) ? join(payload, "bin/node") : process.execPath);
const here = fileURLToPath(new URL(".", import.meta.url));
const build = join(here, "../../.build");

const SECRETS = { settings: "SETTINGS-SECRET-1a2b", pinned: "PINNED-SECRET-3c4d", shared: "SHARED-AUTH-SECRET-5e6f",
	notes: "NOTES-SECRET-7a8b", history: "HISTORY-SECRET-9c0d", models: "MODELS-SECRET-2f3a" };
const USEFUL = { work: "WORK-LETTER-4b5c", home: "HOME-DOCUMENT-6d7e", shell: "SHELL-READ-8f9a" };

test("real Pi: no model-facing tool reads or changes Pippa's settings, grants, history, notes or Pi's credentials", {
	skip: !cli && "PIPPA_PI_PAYLOAD or PIPPA_PI_CLI not set", timeout: 90_000,
}, async (t) => {
	assert.match(execFileSync(node, [cli, "--version"], { encoding: "utf8" }).trim(), /^1\.6\./);
	await mkdir(build, { recursive: true });
	// Under /Users, so the same files are also reachable through /System/Volumes/Data.
	const root = realpathSync(await mkdtemp(join(build, "pippa-protected-realpi-")));
	const support = join(root, "Library/Application Support/Pippa");
	const work = join(support, "pi-work"), sessions = join(support, "pi-sessions");
	const pinned = join(support, "pi-recipients", "4242", "snapshot");
	const shared = join(root, ".pi/agent");
	await Promise.all([work, sessions, pinned, shared, join(root, "Documents")].map((path) => mkdir(path, { recursive: true })));
	const docs = join(root, "Documents");
	const sortable = join(docs, "sortable"), archive = join(docs, "archive");
	await Promise.all([sortable, archive].map((path) => mkdir(path)));
	const protectedChild = join(sortable, "private.txt");
	const plannedTarget = join(archive, "item.txt");
	const alternatePath = join(docs, "Clock AM.txt");
	const usefulAlternate = join(work, "Letter PM.txt");
	await symlink(join(shared, "auth.json"), alternatePath.replace(" AM.", "\u202fAM."));
	const outwardAlias = join(sessions, "outward.txt"), workAlias = join(sessions, "workspace");
	await symlink(join(docs, "doc letter.txt"), outwardAlias);
	await symlink(work, workAlias);
	const settingsFile = join(support, "inference-settings.json");
	const memoryFile = join(support, "memory.md");
	const files = {
		[protectedChild]: "SYNTHETIC-PRIVATE-DESCENDANT",
		[join(docs, "item.txt")]: "SORTABLE-ITEM",
		[settingsFile]: JSON.stringify({ policy: "online", macAccess: { key: SECRETS.settings } }),
		[join(pinned, "auth.json")]: JSON.stringify({ "other-fixture": { type: "api_key", key: SECRETS.pinned } }),
		[join(shared, "auth.json")]: JSON.stringify({ "other-fixture": { type: "api_key", key: SECRETS.shared } }),
		[join(shared, "models.json")]: JSON.stringify({ note: SECRETS.models }),
		[memoryFile]: `- ${SECRETS.notes}\n`,
		[join(sessions, "other-conversation.jsonl")]: JSON.stringify({ text: SECRETS.history }) + "\n",
		[join(work, "letter.txt")]: USEFUL.work,
		[usefulAlternate.replace(" PM.", "\u202fPM.")]: USEFUL.work,
		[join(docs, "doc letter.txt")]: USEFUL.home,
	};
	for (const [path, text] of Object.entries(files)) await writeFile(path, text);
	await symlink(join(shared, "auth.json"), join(work, "alias.json"));
	await symlink(sessions, join(root, "Documents/history"));
	await symlink(settingsFile, join(root, "Documents/settings-link.json"));

	const token = "ab".repeat(32);
	const bodies = [];
	const mcpCalls = [];
	let requests = 0;
	const calls = [
		// An ordinary write through the same (guarded) tool still works.
		["write", { path: "~/Documents/new.txt", content: "WRITTEN-OK" }],
		["read", { path: settingsFile }],
		["read", { path: pathToFileURL(settingsFile).href }],
		["read", { path: settingsFile.replace("Application Support", "Application\u00a0Support") }],
		["read", { path: alternatePath }],
		["write", { path: pathToFileURL(settingsFile).href, content: "FORGED" }],
		["write", { path: pathToFileURL(join(docs, "doc letter.txt")).href, content: USEFUL.home + "-updated" }],
		["edit", { path: pathToFileURL(join(docs, "doc letter.txt")).href, edits: [{ oldText: "-updated", newText: "-edited" }] }],
		["move_files", { from: sortable, to: join(docs, "renamed") }],
		["move_files", { from: outwardAlias, to: join(docs, "outward.txt") }],
		["move_files", { folder: docs, groups: [{ into: "archive", files: ["item.txt"] }] }],
		["bash", { command: 'printf "marker-status:%s" "${PIPPA_FIXTURE_MARKER-unset}"' }],
		["move_files", { from: workAlias, to: join(docs, "workspace") }],
		["read", { path: "~/.PI/agent/auth.json" }],
		["read", { path: "alias.json" }],
		["read", { path: `/System/Volumes/Data${memoryFile}` }],
		["read", { path: join(root, "Documents/history/other-conversation.jsonl") }],
		["read", { path: join(pinned, "auth.json") }],
		["write", { path: join(root, "Documents/settings-link.json"), content: "{\"macAccess\":\"FORGED\"}" }],
		["write", { path: join(pinned, "auth.json"), content: "FORGED" }],
		["list_folder", { path: sessions }],
		["move_files", { from: join(sessions, "other-conversation.jsonl"), to: work }],
		["mcp__pippa__read_document", { path: join(shared, "auth.json") }],
		["bash", { command: `cat ~/.pi/agent/auth.json "${memoryFile}" alias.json "$HOME/Library/Application Support/Pippa/pi-sessions/"*` }],
		["bash", { command: `cat ~/.PI/AGENT/models.json; cat "/System/Volumes/Data${pinned}/auth.json"` }],
		["bash", { command: `printf FORGED > "${settingsFile}"; ln ~/.pi/agent/auth.json hard.json && cat hard.json; cp "${pinned}/auth.json" copy.json && cat copy.json` }],
		// Paths the command does not name outright: only the sandbox stands in the way.
		["bash", { command: `d="$HOME/.p"; cat "\${d}i/agent/auth.json"; ln "\${d}i/agent/auth.json" hard2.json; cat hard2.json; ls "$HOME/Documents/history/"` }],
		["bash", { command: `cd "$HOME/Library/Application Support/Pippa" && cat inference-settings.json memory.md pi-recipients/*/*/auth.json; printf FORGED > inference-settings.json` }],
		["read", { path: "Letter PM.txt" }],
		["read", { path: pathToFileURL(join(docs, "doc letter.txt")).href }],
		["bash", { command: `printf '%s-%s' SHELL-READ 8f9a; cat "$HOME/Documents/doc letter.txt" letter.txt` }],
	];

	const server = createServer((req, res) => {
		let text = "";
		req.on("data", (chunk) => { text += chunk; });
		req.on("end", () => {
			if (req.url === "/mcp") {
				if (req.headers.authorization !== `Bearer ${token}`) { res.writeHead(403); res.end(); return; }
				if (req.method !== "POST") { res.writeHead(405); res.end(); return; }
				const request = JSON.parse(text);
				if (request.id === undefined) { res.writeHead(202); res.end(); return; }
				let result = {};
				if (request.method === "initialize") result = { protocolVersion: "2024-11-05", capabilities: { tools: {} }, serverInfo: { name: "pippa-fixture", version: "1" } };
				else if (request.method === "tools/list") result = { tools: REQUIRED_TOOLS.map((name) => ({ name: name.split("__").pop(), description: "Fixture", inputSchema: { type: "object", properties: {} } })) };
				else if (request.method === "tools/call") { mcpCalls.push(request.params); result = { content: [{ type: "text", text: "fixture" }], isError: false }; }
				res.writeHead(200, { "Content-Type": "application/json" });
				res.end(JSON.stringify({ jsonrpc: "2.0", id: request.id, result }));
				return;
			}
			bodies.push(text);
			res.writeHead(200, { "Content-Type": "text/event-stream" });
			const chunk = (delta, finish_reason) => `data: ${JSON.stringify({ id: "fixture", object: "chat.completion.chunk", created: 0,
				model: "test", choices: [{ index: 0, delta, finish_reason }] })}\n\n`;
			if (++requests % 2 === 1) {
				const start = requests === 1 ? 0 : 12;
				const batch = requests === 1 ? calls.slice(0, 12) : calls.slice(12);
				res.write(chunk({ role: "assistant", tool_calls: batch.map(([name, args], index) =>
					({ index, id: `call_${start + index}`, type: "function", function: { name, arguments: JSON.stringify(args) } })) }, null));
				res.write(chunk({}, "tool_calls"));
			} else res.write(chunk({ role: "assistant", content: "Fixture answer." }, "stop"));
			res.end("data: [DONE]\n\n");
		});
	});

	let child;
	try {
		await new Promise((resolve, reject) => { server.once("error", reject); server.listen(0, "127.0.0.1", resolve); });
		const base = `http://127.0.0.1:${server.address().port}`;
		// The pinned folder is the online Pi's PI_CODING_AGENT_DIR (PiRecipientSnapshot): its provider configuration.
		await writeFile(join(pinned, "models.json"), JSON.stringify({ providers: { fixture: {
			baseUrl: `${base}/v1`, api: "openai-completions", apiKey: "fixture",
			models: [{ id: "test", name: "Test", contextWindow: 16384, maxTokens: 1024 }],
		} } }));
		// The app loadout with web search and notes off, plus Pi’s edit tool for the guarded mutation check.
		const tools = ["read", "bash", "write", "edit", "search_files", "list_folder", "move_files", "ask", "mcp__pippa__*"];
		child = spawn(node, [cli, "--mode", "rpc", "--no-context-files", "--no-approve", "--no-extensions", "--no-skills",
			...["pippa-tools.ts", "pippa-assist.ts", "pippa-mcp.ts"].flatMap((name) => ["--extension", join(here, name)]),
			"--tools", tools.join(","), "--system-prompt", "You are a scripted test.", "--session-dir", sessions,
			"--session-id", `${randomUUID()}_mac-abc123`, "--provider", "fixture", "--model", "test"], {
			cwd: work, env: { HOME: root, PATH: process.env.PATH, PI_CODING_AGENT_DIR: pinned, PI_OFFLINE: "1", PI_SKIP_VERSION_CHECK: "1",
				PI_TELEMETRY: "0", PIPPA_MCP_URL: `${base}/mcp`, PIPPA_MCP_TOKEN: token, PIPPA_MEMORY_FILE: memoryFile,
				PIPPA_PROTECTED_PATHS: JSON.stringify([support, shared, pinned, protectedChild, plannedTarget]), PIPPA_WORK_DIR: work, PIPPA_LANGUAGE: "en", PIPPA_FIXTURE_MARKER: "SYNTHETIC-CHILD-ENV" },
			stdio: ["pipe", "pipe", "pipe"],
		});
		let stderr = "", buffer = "", serial = 0, settled;
		const ended = [], pending = new Map(), entries = [];
		child.stderr.on("data", (data) => { stderr += data; });
		child.stdout.on("data", (data) => {
			buffer += data;
			for (let end; (end = buffer.indexOf("\n")) >= 0;) {
				const line = buffer.slice(0, end); buffer = buffer.slice(end + 1);
				let event; try { event = JSON.parse(line); } catch { continue; }
				// Every question of the shell gets a yes: the protected places stay closed whatever the person grants.
				if (event.type === "extension_ui_request" && event.method === "confirm") {
					child.stdin.write(JSON.stringify({ type: "extension_ui_response", id: event.id, confirmed: true }) + "\n");
				}
				if (event.type === "entry_appended") entries.push(event.entry);
				if (event.type === "tool_execution_end") ended.push(event);
				if (event.type === "response") pending.get(event.id)?.resolve(event);
				if (event.type === "agent_settled") settled?.resolve(event);
			}
		});
		const command = (type, fields = {}) => new Promise((resolve, reject) => {
			const id = `p-${++serial}`;
			const timer = setTimeout(() => reject(new Error(`No ${type} response: ${stderr.slice(-1500)}`)), 15_000);
			pending.set(id, { resolve: (event) => { clearTimeout(timer); resolve(event); }, reject });
			child.stdin.write(JSON.stringify({ id, type, ...fields }) + "\n");
		});
		await command("prompt", { message: `/${READINESS_COMMAND} ${randomUUID()}` });
		const receipt = entries.find((entry) => entry.customType === READINESS_COMMAND)?.data;
		assert.equal(receipt?.status, "ready", JSON.stringify(receipt) + stderr.slice(-800));
		for (const message of ["Check the fixtures.", "Look around."]) {
			let timer;
			const finished = new Promise((resolve, reject) => { settled = { resolve, reject };
				timer = setTimeout(() => reject(new Error(`No answer: ${stderr.slice(-1500)}`)), 60_000); });
			try {
				const answer = await command("prompt", { message });
				assert.notEqual(answer.success, false, JSON.stringify(answer));
				await finished;
			} finally { clearTimeout(timer); }
		}

		assert.equal(ended.length, calls.length, JSON.stringify(ended.map((event) => event.toolName)) + stderr.slice(-2000));
		const result = (index) => JSON.stringify(ended.find((event) => event.toolCallId === `call_${index}`)?.result ?? "");
		// What the model got back from each reach for a protected place.
		const leaks = [];
		for (let index = 0; index < calls.length - 3; index++) {
			for (const [name, secret] of Object.entries(SECRETS)) if (result(index).includes(secret)) leaks.push(`${calls[index][0]} #${index}: ${name}`);
		}
		await t.test("D1: Pi's actual file path is protected and useful URL mutations keep the previous versions", async () => {
			assert.deepEqual(leaks, [], "no tool result holds protected content");
			assert.equal(await readFile(settingsFile, "utf8"), files[settingsFile]);
			assert.equal(await readFile(join(docs, "doc letter.txt"), "utf8"), USEFUL.home + "-edited");
			const backups = join(support, "Backups");
			const versions = await Promise.all((existsSync(backups) ? await readdir(backups) : []).map((name) => readFile(join(backups, name), "utf8")));
			assert.ok(versions.includes(USEFUL.home), "URL write backed up the same file");
			assert.ok(versions.includes(USEFUL.home + "-updated"), "URL edit backed up the same file");
			const restores = entries.filter((entry) => entry.customType === "pippa-change")
				.flatMap((entry) => entry.data.changes).filter((change) => change.kind === "restore");
			assert.equal(restores.filter((change) => change.file === join(docs, "doc letter.txt")).length, 2, "both successful mutations can be undone");
		});
		await t.test("D3: protected ancestors, symlink entries and planned destinations cannot move", () => {
			assert.deepEqual([existsSync(protectedChild), existsSync(outwardAlias), existsSync(workAlias), !existsSync(plannedTarget)], [true, true, true, true]);
		});
		await t.test("D4: a runtime-only marker is absent in the actual shell", () => {
			const markerCall = calls.findIndex(([name, args]) => name === "bash" && args.command.includes("marker-status"));
			assert.match(result(markerCall), /marker-status:unset/);
			assert.ok(!bodies.slice(1).join("\n").includes("SYNTHETIC-CHILD-ENV"));
		});
		for (const index of [calls.length - 5, calls.length - 4]) assert.match(result(index), /Operation not permitted/, `the sandbox refused: ${result(index)}`);
		const sent = bodies.slice(1).join("\n");
		assert.ok(bodies.length >= 2, `the answer goes on after the tool results: ${stderr.slice(-800)}`);
		for (const [name, secret] of Object.entries(SECRETS)) assert.equal(sent.includes(secret), false, `${name} (${secret}) reached the provider`);
		for (const [name, marker] of Object.entries(USEFUL)) assert.ok(sent.includes(marker), `${name} must stay readable: ${result(calls.length - 1)}`);
		assert.ok(result(calls.length - 3).includes(USEFUL.work), "read in the working folder");
		assert.ok(result(calls.length - 2).includes(USEFUL.home), "read in the home folder");
		assert.deepEqual(mcpCalls, [], "the app's document reader is never asked for a protected file");
		for (const [path, text] of Object.entries(files)) assert.equal(await readFile(path, "utf8"), path === join(docs, "doc letter.txt") ? text + "-edited" : text, `${path} unchanged`);
		assert.equal(await readFile(join(root, "Documents/new.txt"), "utf8"), "WRITTEN-OK", "an ordinary write still works");
		assert.deepEqual((await readdir(work)).sort(), ["Letter\u202fPM.txt", "alias.json", "letter.txt"], "nothing moved or copied into the working folder");
		const backups = join(support, "Backups");
		for (const name of existsSync(backups) ? await readdir(backups) : []) {
			const text = await readFile(join(backups, name), "utf8");
			for (const secret of Object.values(SECRETS)) assert.equal(text.includes(secret), false, `backup ${name} holds ${secret}`);
		}
	} finally {
		if (child && child.exitCode === null && child.signalCode === null) { child.kill("SIGKILL"); await new Promise((resolve) => child.once("exit", resolve)); }
		server.closeAllConnections(); await new Promise((resolve) => server.close(resolve));
		await rm(root, { recursive: true, force: true });
	}
});
