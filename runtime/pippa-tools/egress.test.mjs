// The online AI's guard (egress.ts) and its native readiness (pippa-mcp.ts), without Pi and without a model.
//
//   node --experimental-strip-types --test runtime/pippa-tools/egress.test.mjs
import assert from "node:assert/strict";
import { test } from "node:test";

const { egress, blockReason, onlyAllowedTools, hideWorkingFolder, HIDDEN_FOLDER, readOnly, readOnlyBlockReason, READ_ONLY_LOCAL_TOOLS, READ_ONLY_MCP_TOOLS } = await import("./egress.ts");
const { requiredTools, discoverNativeTools, REQUIRED_TOOLS, READ_ONLY_TOOLS, READ_ONLY_FORBIDDEN_TOOLS, serverConfig, withCodemode } = await import("./pippa-mcp.ts");

const online = { PIPPA_EGRESS: "online", PIPPA_EGRESS_TOOLS: "ask,web_search,mcp__pippa__calendar_add" };

test("egress: off without the variable; an unknown value allows nothing", () => {
	assert.equal(egress({}), undefined);
	assert.deepEqual([...egress(online).tools], ["ask", "web_search", "mcp__pippa__calendar_add"]);
	assert.deepEqual([...egress({ PIPPA_EGRESS: "cloud", PIPPA_EGRESS_TOOLS: "read,bash" }).tools], []);
});

test("egress: every tool outside the list is blocked with a sentence for the person", () => {
	const guard = egress(online);
	for (const tool of ["read", "bash", "write", "search_files", "list_folder", "move_files", "remember", "mcp__pippa__mail_read", "mcp__pippa__front_read"]) {
		assert.match(blockReason(guard, tool), /stays_on_mac/, tool);
	}
	assert.equal(blockReason(guard, "ask"), undefined);
	assert.equal(blockReason(guard, "mcp__pippa__calendar_add"), undefined);
});

test("egress: provider requests carry only listed tools, in every request shape", () => {
	const guard = egress(online);
	const chat = { tools: [{ type: "function", function: { name: "read" } }, { type: "function", function: { name: "ask" } }] };
	const anthropic = { tools: [{ name: "bash", input_schema: {} }], tool_choice: { type: "auto" } };
	assert.deepEqual(onlyAllowedTools(guard, chat).tools.map((t) => t.function.name), ["ask"]);
	const none = onlyAllowedTools(guard, anthropic);
	assert.equal(none.tools, undefined); assert.equal(none.tool_choice, undefined);
	assert.equal(onlyAllowedTools(guard, { tools: [{ name: "ask" }] }), undefined, "unchanged requests stay as they are");
});

test("egress: a forced tool_choice naming a removed tool goes with it, in every request shape", () => {
	const guard = egress(online);
	const chat = { tools: [{ type: "function", function: { name: "read" } }, { type: "function", function: { name: "ask" } }],
		tool_choice: { type: "function", function: { name: "read" } } };
	const responses = { tools: [{ type: "function", name: "bash" }, { type: "function", name: "ask" }], tool_choice: { type: "function", name: "bash" } };
	const anthropic = { tools: [{ name: "write", input_schema: {} }, { name: "ask", input_schema: {} }], tool_choice: { type: "tool", name: "write" } };
	for (const payload of [chat, responses, anthropic]) {
		const next = onlyAllowedTools(guard, payload);
		assert.equal(next.tools.length, 1);
		assert.equal("tool_choice" in next, false, JSON.stringify(payload.tool_choice));
	}
	const kept = onlyAllowedTools(guard, { ...anthropic, tool_choice: { type: "tool", name: "ask" } });
	assert.deepEqual(kept.tool_choice, { type: "tool", name: "ask" }, "a choice naming a kept tool stays");
	assert.deepEqual(onlyAllowedTools(guard, { ...chat, tool_choice: "auto" }).tool_choice, "auto", "a choice naming no tool stays");
	const allowedOnly = onlyAllowedTools(guard, { tools: [{ name: "ask" }], tool_choice: { type: "tool", name: "bash" } });
	assert.equal("tool_choice" in allowedOnly, false, "a disallowed tool_choice is dropped even when tools needed no filtering");
});

test("egress: Pi's working-folder section is replaced", () => {
	const event = { systemPromptOptions: { sections: { memory: "x" } } };
	hideWorkingFolder(event);
	assert.equal(event.systemPromptOptions.sections.cwd, HIDDEN_FOLDER);
});

// pippa-tools.ts itself needs Pi's packages; real-pi-online.test.mjs runs it in the real Pi.

test("readiness online: exactly the allowed Pippa tools, and any other one registered is a mismatch", async () => {
	assert.deepEqual(requiredTools({}).required, REQUIRED_TOOLS);
	const expected = requiredTools(online);
	assert.deepEqual(expected.required, ["mcp__pippa__calendar_add"]);
	assert.equal(expected.forbidden.length, REQUIRED_TOOLS.length - 1);
	const config = serverConfig({ PIPPA_MCP_URL: "http://127.0.0.1:1/mcp", PIPPA_MCP_TOKEN: "ab".repeat(32) });
	const fake = (names) => ({
		getMcpServers: () => [{ name: "pippa", config: { ...config } }],
		getAllTools: () => names.map((name) => ({ name })), getActiveTools: () => names,
	});
	assert.equal((await discoverNativeTools(fake(["mcp__pippa__calendar_add"]), config, 0, undefined, expected)).status, "ready");
	assert.equal((await discoverNativeTools(fake(["mcp__pippa__calendar_add", "mcp__pippa__mail_read"]), config, 0, undefined, expected)).status,
		"registrationMismatch");
});

test("read-only mode: allows only local and MCP readers, blocks writes/shell/ask/online, never loads codemode", async () => {
	assert.equal(readOnly({}), undefined);
	assert.equal(readOnly({ PIPPA_READ_ONLY: "0" }), undefined);
	const guard = readOnly({ PIPPA_READ_ONLY: "1" });
	assert.ok(guard);
	for (const tool of [...READ_ONLY_LOCAL_TOOLS, ...READ_ONLY_MCP_TOOLS]) {
		assert.equal(readOnlyBlockReason(guard, tool), undefined, tool);
	}
	for (const tool of ["bash", "write", "edit", "ask", "move_files", "remember", "web_search", "fetch_content", "codemode",
		"mcp__pippa__calendar_add", "mcp__pippa__mail_send", "mcp__pippa__browse"]) {
		assert.match(readOnlyBlockReason(guard, tool), /read_only/, tool);
	}
	const filtered = onlyAllowedTools(guard, {
		tools: [{ type: "function", function: { name: "read" } }, { type: "function", function: { name: "bash" } }, { type: "function", function: { name: "mcp__pippa__calendar_read" } }],
		tool_choice: { type: "function", function: { name: "bash" } },
	});
	assert.deepEqual(filtered.tools.map((t) => t.function.name), ["read", "mcp__pippa__calendar_read"]);
	assert.equal("tool_choice" in filtered, false);

	const env = { PIPPA_READ_ONLY: "1", PIPPA_MCP_EXPOSURE: "direct+codemode" };
	assert.equal(withCodemode(env), false);
	assert.equal(serverConfig({ PIPPA_MCP_URL: "http://127.0.0.1:1/mcp", PIPPA_MCP_TOKEN: "ab".repeat(32), PIPPA_MCP_EXPOSURE: "codemode", PIPPA_READ_ONLY: "1" }).exposure, "direct");
	const expected = requiredTools(env);
	assert.deepEqual(expected.required, READ_ONLY_TOOLS);
	assert.deepEqual(expected.forbidden, READ_ONLY_FORBIDDEN_TOOLS);
	assert.equal(expected.codemode, false);
	// Combining read-only and online egress fails closed.
	const conflict = requiredTools({ PIPPA_READ_ONLY: "1", ...online });
	assert.deepEqual(conflict.required, []);
	assert.deepEqual(conflict.forbidden, REQUIRED_TOOLS);

	const config = serverConfig({ PIPPA_MCP_URL: "http://127.0.0.1:1/mcp", PIPPA_MCP_TOKEN: "ab".repeat(32), PIPPA_READ_ONLY: "1" });
	const fake = (names) => ({
		getMcpServers: () => [{ name: "pippa", config: { ...config } }],
		getAllTools: () => names.map((name) => ({ name })), getActiveTools: () => names,
	});
	assert.equal((await discoverNativeTools(fake(READ_ONLY_TOOLS), config, 0, undefined, expected)).status, "ready");
	assert.equal((await discoverNativeTools(fake([...READ_ONLY_TOOLS, "mcp__pippa__calendar_add"]), config, 0, undefined, expected)).status, "registrationMismatch");
	assert.equal((await discoverNativeTools(fake([...READ_ONLY_TOOLS, "codemode"]), config, 0, undefined, expected)).status, "registrationMismatch");
});
