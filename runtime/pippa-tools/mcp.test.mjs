// Tests the registration of Pippa's MCP server (pippa-mcp.ts) without Pi and without network: a stand-in `pi` accepts
// `registerMcpServer`.
//
//   node --experimental-strip-types --test runtime/pippa-tools/mcp.test.mjs
import assert from "node:assert/strict";
import { test } from "node:test";

const { default: register, serverConfig, SERVER_NAME, TOOLS, WRITE_TOOLS, discoverNativeTools, REQUIRED_TOOLS, READINESS_COMMAND } = await import("./pippa-mcp.ts");

const token = "ab".repeat(32);

async function load(env, connectorFactory) {
	const registered = [];
	const commands = [];
	let connectorOptions;
	const saved = { ...process.env };
	for (const key of ["PIPPA_MCP_URL", "PIPPA_MCP_TOKEN", "PIPPA_MCP_EXPOSURE"]) delete process.env[key];
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
	assert.deepEqual(WRITE_TOOLS, ["calendar_add", "reminder_add", "mail_draft"]);
	assert.ok(WRITE_TOOLS.every((name) => !/send|delete|remove|invite/.test(name)));
});

function fixture() {
	const config = serverConfig({ PIPPA_MCP_URL: "http://127.0.0.1:53124/mcp", PIPPA_MCP_TOKEN: token });
	const pi = { getMcpServers: () => [{ name: "pippa", config }], getActiveTools: () => REQUIRED_TOOLS };
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

test("matching names from a changed registration do not establish readiness; cancellation terminates polling", async () => {
	const f = fixture();
	f.pi.getMcpServers = () => [{ name: "pippa", config: { ...f.config, headers: { Authorization: "different" } } }];
	assert.equal((await discoverNativeTools(f.pi, f.config, 0)).status, "registrationMismatch");
	const controller = new AbortController(); controller.abort();
	assert.equal((await discoverNativeTools(f.pi, f.config, 0, controller.signal)).status, "cancelled");
});
