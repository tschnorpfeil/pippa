// Tests the registration of Pippa's MCP server (pippa-mcp.ts) without Pi and without network: a stand-in `pi` accepts
// `registerMcpServer`.
//
//   node --experimental-strip-types --test runtime/pippa-tools/mcp.test.mjs
import assert from "node:assert/strict";
import { test } from "node:test";

const { default: register, serverConfig, SERVER_NAME, TOOLS, WRITE_TOOLS, BROWSER_TOOLS, discoverNativeTools, REQUIRED_TOOLS, READINESS_COMMAND } = await import("./pippa-mcp.ts");

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
	assert.deepEqual(TOOLS, ["calendar_read", "reminders_read", "mail_search", "mail_read", "photos_search", "front_read", "read_document"]);
	assert.ok(TOOLS.every((name) => !/send|write|add|delete|create|draft/.test(name)));
});

test("admission requires exactly the readers and writers of the Swift server", () => {
	assert.deepEqual(REQUIRED_TOOLS, ["calendar_read", "reminders_read", "mail_search", "mail_read", "photos_search", "front_read", "read_document",
		"calendar_add", "reminder_add", "mail_draft", "prepare_files", "browse"].map((name) => `mcp__pippa__${name}`));
});

test("the browser tool is separate from the readers and the Mac-only writers", () => {
	assert.deepEqual(BROWSER_TOOLS, ["browse"]);
	assert.ok(!TOOLS.includes("browse") && !WRITE_TOOLS.includes("browse"));
});

test("writing tools as in the Swift server, none sends or deletes", () => {
	assert.deepEqual(WRITE_TOOLS, ["calendar_add", "reminder_add", "mail_draft", "prepare_files"]);
	assert.ok(WRITE_TOOLS.every((name) => !/send|delete|remove|invite/.test(name)));
});

function fixture() {
	const config = serverConfig({ PIPPA_MCP_URL: "http://127.0.0.1:53124/mcp", PIPPA_MCP_TOKEN: token });
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

for (const name of ["mcp__pippa__prepare_files", "mcp__pippa__browse"]) test(`${name} must be registered and active for admission`, async () => {
	const f = fixture();
	assert.ok(REQUIRED_TOOLS.includes(name));
	f.pi.getActiveTools = () => REQUIRED_TOOLS.filter((tool) => tool !== name);
	assert.equal((await discoverNativeTools(f.pi, f.config, 0)).status, "toolsUnavailable");
	f.pi.getActiveTools = () => REQUIRED_TOOLS;
	f.pi.getAllTools = () => REQUIRED_TOOLS.filter((tool) => tool !== name).map((name) => ({ name }));
	assert.equal((await discoverNativeTools(f.pi, f.config, 0)).status, "toolsUnavailable");
});

test("matching names from a changed registration do not establish readiness; cancellation terminates polling", async () => {
	const f = fixture();
	f.pi.getMcpServers = () => [{ name: "pippa", config: { ...f.config, headers: { Authorization: "different" } } }];
	assert.equal((await discoverNativeTools(f.pi, f.config, 0)).status, "registrationMismatch");
	const controller = new AbortController(); controller.abort();
	assert.equal((await discoverNativeTools(f.pi, f.config, 0, controller.signal)).status, "cancelled");
});

test("readiness rejects a registration with narrowed or widened tool exposure", async () => {
	const f = fixture();
	f.pi.getMcpServers = () => [{ name: "pippa", config: { ...f.config, toolExposure: { "*": "hidden" } } }];
	assert.equal((await discoverNativeTools(f.pi, f.config, 0)).status, "registrationMismatch");
});

test("direct+codemode keeps the server direct and loads Pi's codemode tool with mode on and no model catalog", async () => {
	const { CODEMODE_EXPOSURE, withCodemode } = await import("./pippa-mcp.ts");
	const env = { PIPPA_MCP_URL: "http://127.0.0.1:53124/mcp", PIPPA_MCP_TOKEN: token, PIPPA_MCP_EXPOSURE: CODEMODE_EXPOSURE };
	assert.equal(serverConfig(env).exposure, "direct");
	assert.equal(withCodemode(env), true);
	assert.equal(withCodemode({ ...env, PIPPA_MCP_EXPOSURE: "direct" }), false);
	const run = async (extra) => {
		const registered = [];
		let codemodeOptions;
		const pi = { registerMcpServer: (name, config) => registered.push({ name, config }), registerCommand: () => {} };
		const saved = { ...process.env };
		for (const key of ["PIPPA_MCP_URL", "PIPPA_MCP_TOKEN", "PIPPA_MCP_EXPOSURE", "PIPPA_EGRESS", "PIPPA_EGRESS_TOOLS"]) delete process.env[key];
		Object.assign(process.env, env, extra);
		try {
			await register(pi, () => () => {}, (options) => { codemodeOptions = options; return () => {}; });
		} finally {
			for (const key of Object.keys(process.env)) if (!(key in saved)) delete process.env[key];
			Object.assign(process.env, saved);
		}
		return { registered, codemodeOptions };
	};
	const mac = await run({});
	assert.deepEqual(mac.codemodeOptions, { mode: "on", models: false });
	assert.equal(mac.registered[0].config.exposure, "direct");
	// The limits of an online AI without Mac access win over the switch: no scripts there.
	const limited = await run({ PIPPA_EGRESS: "online", PIPPA_EGRESS_TOOLS: "ask" });
	assert.equal(limited.codemodeOptions, undefined);
	const plain = await run({ PIPPA_MCP_EXPOSURE: "direct" });
	assert.equal(plain.codemodeOptions, undefined);
});

test("readiness with codemode: ready once codemode is active too; codemode where it was not asked for is a mismatch", async () => {
	const { requiredTools } = await import("./pippa-mcp.ts");
	const f = fixture();
	const expected = requiredTools({ PIPPA_MCP_EXPOSURE: "direct+codemode" });
	assert.equal(expected.codemode, true);
	assert.equal(requiredTools({}).codemode, false);
	assert.equal(requiredTools({ PIPPA_MCP_EXPOSURE: "direct+codemode", PIPPA_EGRESS: "online", PIPPA_EGRESS_TOOLS: "ask" }).codemode, false);
	const withScripts = [...REQUIRED_TOOLS, "codemode"];
	f.pi.getAllTools = () => withScripts.map((name) => ({ name }));
	// Registered, not yet active: waits, then gives up.
	f.pi.getActiveTools = () => REQUIRED_TOOLS;
	assert.equal((await discoverNativeTools(f.pi, f.config, 0, undefined, expected)).status, "toolsUnavailable");
	f.pi.getActiveTools = () => withScripts;
	const ready = await discoverNativeTools(f.pi, f.config, 0, undefined, expected);
	assert.equal(ready.status, "ready");
	assert.deepEqual(ready.tools, REQUIRED_TOOLS, "the receipt names Pippa's tools only, as the app expects");
	// The AI on this Mac and an online AI without Mac access: an active codemode is unexpected.
	assert.equal((await discoverNativeTools(f.pi, f.config, 0, undefined, requiredTools({}))).status, "registrationMismatch");
	const limited = requiredTools({ PIPPA_EGRESS: "online", PIPPA_EGRESS_TOOLS: "mcp__pippa__calendar_add" });
	f.pi.getActiveTools = () => ["mcp__pippa__calendar_add", "codemode"];
	f.pi.getAllTools = () => ["mcp__pippa__calendar_add", "codemode"].map((name) => ({ name }));
	assert.equal((await discoverNativeTools(f.pi, f.config, 0, undefined, limited)).status, "registrationMismatch");
	// Anything else unexpected still counts with codemode on: a forbidden tool, a changed registration.
	f.pi.getActiveTools = () => withScripts;
	f.pi.getAllTools = () => withScripts.map((name) => ({ name }));
	f.pi.getMcpServers = () => [{ name: "pippa", config: { ...f.config, exposure: "codemode" } }];
	assert.equal((await discoverNativeTools(f.pi, f.config, 0, undefined, expected)).status, "registrationMismatch");
});
