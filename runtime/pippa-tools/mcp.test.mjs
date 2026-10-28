// Tests the registration of Pippa's MCP server (pippa-mcp.ts) without Pi and without network: a stand-in `pi` accepts
// `registerMcpServer`.
//
//   node --experimental-strip-types --test runtime/pippa-tools/mcp.test.mjs
import assert from "node:assert/strict";
import { test } from "node:test";

const { default: register, serverConfig, SERVER_NAME, TOOLS, WRITE_TOOLS, VIEW_TOOLS, discoverNativeTools, REQUIRED_TOOLS, READINESS_COMMAND } = await import("./pippa-mcp.ts");

const token = "ab".repeat(32);

async function load(env, connectorFactory) {
	const registered = [];
	const commands = [];
	let connectorOptions;
	const saved = { ...process.env };
	for (const key of ["PIPPA_MCP_URL", "PIPPA_MCP_TOKEN", "PIPPA_MCP_EXPOSURE", "PIPPA_ACTION_POLICY"]) delete process.env[key];
	Object.assign(process.env, env);
	try {
		await register({ registerMcpServer: (name, config) => registered.push({ name, config }), registerCommand: (name, command) => commands.push({ name, command }) }, connectorFactory ?? ((options) => { connectorOptions = options; return () => {}; }));
		return { registered, commands, connectorOptions, tokenLeft: process.env.PIPPA_MCP_TOKEN };
	} finally {
		for (const key of Object.keys(process.env)) if (!(key in saved)) delete process.env[key];
		Object.assign(process.env, saved);
	}
}

test("registers the server for this session only, directly, with the key in the header; the key leaves the environment", async () => {
	const { registered, tokenLeft, connectorOptions } = await load({ PIPPA_MCP_URL: "http://127.0.0.1:53124/mcp", PIPPA_MCP_TOKEN: token });
	assert.deepEqual(connectorOptions.loadConfig(), { servers: [], errors: [], autoEnableCodemode: false });
	assert.equal(registered.length, 1);
	assert.equal(registered[0].name, SERVER_NAME);
	assert.equal(registered[0].config.url, "http://127.0.0.1:53124/mcp");
	assert.equal(registered[0].config.exposure, "direct");
	assert.deepEqual(registered[0].config.headers, { Authorization: `Bearer ${token}` });
	assert.equal(tokenLeft, undefined, "bash commands must not inherit the key");
});

test("no server without a matching environment (terminal Pi, foreign hosts, broken key)", async () => {
	assert.equal((await load({})).registered.length, 0);
	assert.equal(serverConfig({ PIPPA_MCP_URL: "http://192.168.1.2:53124/mcp", PIPPA_MCP_TOKEN: token }), undefined);
	assert.equal(serverConfig({ PIPPA_MCP_URL: "https://127.0.0.1:53124/mcp", PIPPA_MCP_TOKEN: token }), undefined);
	assert.equal(serverConfig({ PIPPA_MCP_URL: "http://localhost:53124/mcp", PIPPA_MCP_TOKEN: token }), undefined);
	assert.equal(serverConfig({ PIPPA_MCP_URL: "http://127.0.0.1:53124/other", PIPPA_MCP_TOKEN: token }), undefined);
	assert.equal(serverConfig({ PIPPA_MCP_URL: "http://127.0.0.1:53124/mcp", PIPPA_MCP_TOKEN: "x" }), undefined);
	assert.equal(serverConfig({ PIPPA_MCP_URL: "nonsense", PIPPA_MCP_TOKEN: token }), undefined);
});

test("codemode only on explicit request (measuring)", () => {
	assert.equal(serverConfig({ PIPPA_MCP_URL: "http://127.0.0.1:1/mcp", PIPPA_MCP_TOKEN: token, PIPPA_MCP_EXPOSURE: "codemode" }).exposure, "codemode");
	assert.equal(serverConfig({ PIPPA_MCP_URL: "http://127.0.0.1:1/mcp", PIPPA_MCP_TOKEN: token, PIPPA_MCP_EXPOSURE: "hidden" }).exposure, "direct");
});

test("tool names as in the Swift server, none writes or sends", () => {
	assert.deepEqual(TOOLS, ["calendar_read", "reminders_read", "mail_selected", "mail_search", "excel_selection", "photos_search", "front_read", "read_document"]);
	assert.ok(TOOLS.every((name) => !/send|write|add|delete|create|draft/.test(name)));
});

test("writing tools as in the Swift server, none sends or deletes", () => {
	assert.deepEqual(WRITE_TOOLS, ["calendar_add", "reminder_add", "mail_draft", "prepare_files"]);
	assert.ok(WRITE_TOOLS.every((name) => !/send|delete|remove|invite/.test(name)));
});

test("the chart view is read-only, required for standard admission and hidden in draft scope", async () => {
	assert.deepEqual(VIEW_TOOLS, ["make_chart"]);
	assert.ok(!TOOLS.includes("make_chart") && !WRITE_TOOLS.includes("make_chart"));
	const name = "mcp__pippa__make_chart", f = fixture();
	assert.ok(REQUIRED_TOOLS.includes(name));
	f.pi.getActiveTools = () => REQUIRED_TOOLS.filter((tool) => tool !== name);
	assert.equal((await discoverNativeTools(f.pi, f.config, 0)).status, "toolsUnavailable");
	const draft = fixture("draftOnly");
	assert.equal(draft.config.toolExposure.make_chart, undefined);
	assert.equal(draft.config.toolExposure["*"], "hidden");
	draft.pi.getActiveTools = () => TOOLS.map((tool) => `mcp__pippa__${tool}`);
	assert.equal((await discoverNativeTools(draft.pi, draft.config, 0, undefined, "draftOnly")).status, "ready");
});

function fixture(policy = "standard") {
	const config = serverConfig({ PIPPA_MCP_URL: "http://127.0.0.1:53124/mcp", PIPPA_MCP_TOKEN: token, PIPPA_ACTION_POLICY: policy });
	const pi = { getMcpServers: () => [{ name: "pippa", config }], getActiveTools: () => REQUIRED_TOOLS, getAllTools: () => REQUIRED_TOOLS.map((name) => ({ name })) };
	return { config, pi };
}

test("readiness is an extension command, absent in ordinary terminal Pi", async () => {
	assert.equal((await load({})).commands.length, 0);
	const loaded = await load({ PIPPA_MCP_URL: "http://127.0.0.1:53124/mcp", PIPPA_MCP_TOKEN: token });
	assert.equal(loaded.commands[0].name, READINESS_COMMAND);
});

test("connector factory failure cannot advertise successful registration or a readiness command", async () => {
	const config = serverConfig({ PIPPA_MCP_URL: "http://127.0.0.1:53124/mcp", PIPPA_MCP_TOKEN: token });
	let registrations = 0;
	const saved = { ...process.env };
	Object.assign(process.env, { PIPPA_MCP_URL: config.url, PIPPA_MCP_TOKEN: token });
	try {
		await assert.rejects(register({ registerMcpServer: () => registrations++, registerCommand: () => registrations++ },
			() => { throw new Error("Fixture connector failed"); }), /Fixture connector failed/);
		assert.equal(registrations, 0);
		assert.equal(process.env.PIPPA_MCP_TOKEN, undefined);
	} finally {
		for (const key of Object.keys(process.env)) if (!(key in saved)) delete process.env[key];
		Object.assign(process.env, saved);
	}
});

test("admission waits for actual discovery and requires every active tool", async () => {
	const f = fixture();
	let reads = 0;
	f.pi.getActiveTools = () => ++reads < 3 ? REQUIRED_TOOLS.slice(1) : REQUIRED_TOOLS;
	assert.equal((await discoverNativeTools(f.pi, f.config, 500)).status, "ready");
	assert.ok(reads >= 3);
	f.pi.getActiveTools = () => REQUIRED_TOOLS.slice(1);
	assert.equal((await discoverNativeTools(f.pi, f.config, 0)).status, "toolsUnavailable");
	f.pi.getActiveTools = () => [];
	assert.equal((await discoverNativeTools(f.pi, f.config, 0)).status, "toolsUnavailable");
});

test("file preparation must be registered and active for standard admission, and remains hidden in draft scope", async () => {
	const name = "mcp__pippa__prepare_files", f = fixture();
	assert.ok(REQUIRED_TOOLS.includes(name));
	f.pi.getActiveTools = () => REQUIRED_TOOLS.filter((tool) => tool !== name);
	assert.equal((await discoverNativeTools(f.pi, f.config, 0)).status, "toolsUnavailable");
	const draft = fixture("draftOnly");
	assert.equal(draft.config.toolExposure.prepare_files, undefined);
	draft.pi.getActiveTools = () => TOOLS.map((tool) => `mcp__pippa__${tool}`);
	assert.equal((await discoverNativeTools(draft.pi, draft.config, 0, undefined, "draftOnly")).status, "ready");
	draft.pi.getAllTools = () => REQUIRED_TOOLS.filter((tool) => tool !== name).map((name) => ({ name }));
	assert.equal((await discoverNativeTools(draft.pi, draft.config, 0, undefined, "draftOnly")).status, "toolsUnavailable");
});

test("matching names from a changed registration do not establish readiness; cancellation terminates polling", async () => {
	const f = fixture();
	f.pi.getMcpServers = () => [{ name: "pippa", config: { ...f.config, headers: { Authorization: "different" } } }];
	assert.equal((await discoverNativeTools(f.pi, f.config, 0)).status, "registrationMismatch");
	const controller = new AbortController(); controller.abort();
	assert.equal((await discoverNativeTools(f.pi, f.config, 0, controller.signal)).status, "cancelled");
});

test("draft readiness requires all registered native tools but only active local readers", async () => {
	const f = fixture("draftOnly"), readers = TOOLS.map((name) => `mcp__pippa__${name}`);
	f.pi.getActiveTools = () => readers;
	const ready = await discoverNativeTools(f.pi, f.config, 0, undefined, "draftOnly");
	assert.equal(ready.status, "ready");
	assert.deepEqual(ready.tools, readers);
	assert.deepEqual(ready.registeredTools, REQUIRED_TOOLS);
	f.pi.getAllTools = () => readers.map((name) => ({ name }));
	assert.equal((await discoverNativeTools(f.pi, f.config, 0, undefined, "draftOnly")).status, "toolsUnavailable");
});

test("draft exposure hides unknown tools and readiness rejects widened native exposure", async () => {
	const f = fixture("draftOnly");
	assert.equal(f.config.toolExposure["*"], "hidden");
	for (const reader of TOOLS) assert.equal(f.config.toolExposure[reader], "direct");
	for (const writer of WRITE_TOOLS) assert.equal(f.config.toolExposure[writer], undefined);
	f.pi.getMcpServers = () => [{ name: "pippa", config: { ...f.config, toolExposure: { ...f.config.toolExposure, mail_draft: "direct" } } }];
	assert.equal((await discoverNativeTools(f.pi, f.config, 0, undefined, "draftOnly")).status, "registrationMismatch");
});
