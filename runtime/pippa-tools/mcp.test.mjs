// Tests the registration of Pippa's MCP server (pippa-mcp.ts) without Pi and without network: a stand-in `pi` accepts
// `registerMcpServer`.
//
//   node --experimental-strip-types --test runtime/pippa-tools/mcp.test.mjs
import assert from "node:assert/strict";
import { test } from "node:test";

const { default: register, serverConfig, SERVER_NAME, TOOLS, WRITE_TOOLS } = await import("./pippa-mcp.ts");

const token = "ab".repeat(32);

function load(env) {
	const registered = [];
	const saved = { ...process.env };
	for (const key of ["PIPPA_MCP_URL", "PIPPA_MCP_TOKEN", "PIPPA_MCP_EXPOSURE"]) delete process.env[key];
	Object.assign(process.env, env);
	try {
		register({ registerMcpServer: (name, config) => registered.push({ name, config }) });
		return { registered, tokenLeft: process.env.PIPPA_MCP_TOKEN };
	} finally {
		for (const key of Object.keys(process.env)) if (!(key in saved)) delete process.env[key];
		Object.assign(process.env, saved);
	}
}

test("registers the server for this session only, directly, with the key in the header; the key leaves the environment", () => {
	const { registered, tokenLeft } = load({ PIPPA_MCP_URL: "http://127.0.0.1:53124/mcp", PIPPA_MCP_TOKEN: token });
	assert.equal(registered.length, 1);
	assert.equal(registered[0].name, SERVER_NAME);
	assert.equal(registered[0].config.url, "http://127.0.0.1:53124/mcp");
	assert.equal(registered[0].config.exposure, "direct");
	assert.deepEqual(registered[0].config.headers, { Authorization: `Bearer ${token}` });
	assert.equal(tokenLeft, undefined, "bash commands must not inherit the key");
});

test("no server without a matching environment (terminal Pi, foreign hosts, broken key)", () => {
	assert.equal(load({}).registered.length, 0);
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
	assert.deepEqual(TOOLS, ["calendar_read", "reminders_read", "mail_selected", "mail_search", "excel_selection", "read_document"]);
	assert.ok(TOOLS.every((name) => !/send|write|add|delete|create|draft/.test(name)));
});

test("writing tools as in the Swift server, none sends or deletes", () => {
	assert.deepEqual(WRITE_TOOLS, ["calendar_add", "reminder_add", "mail_draft"]);
	assert.ok(WRITE_TOOLS.every((name) => !/send|delete|remove|invite/.test(name)));
});
