import assert from "node:assert/strict";
import { test } from "node:test";
import policy, { actionPolicy, DRAFT_TOOLS, POLICY_COMMAND } from "./pippa-policy.ts";

function loaded(scope, active = DRAFT_TOOLS) {
	const saved = process.env.PIPPA_ACTION_POLICY;
	if (scope === undefined) delete process.env.PIPPA_ACTION_POLICY; else process.env.PIPPA_ACTION_POLICY = scope;
	const handlers = {}, commands = {}, entries = [];
	try {
		policy({ on: (name, fn) => handlers[name] = fn, registerCommand: (name, command) => commands[name] = command,
			getActiveTools: () => active, appendEntry: (type, data) => entries.push({ type, data }) });
	} finally {
		if (saved === undefined) delete process.env.PIPPA_ACTION_POLICY; else process.env.PIPPA_ACTION_POLICY = saved;
	}
	return { handlers, commands, entries };
}

test("draft scope is fixed at launch; injected messages, environment text and nested calls cannot widen it", async () => {
	const { handlers } = loaded("draftOnly");
	for (const toolName of ["bash", "powershell", "write", "edit", "move_files", "move_to_trash", "remember", "save_skill", "web_search", "fetch_content",
		"mcp__pippa__mail_draft", "mcp__pippa__calendar_add", "mcp__pippa__reminder_add", "mcp__pippa__prepare_files", "mcp", "invented_sender"]) {
		const result = await handlers.tool_call({ toolName, parentToolCallId: "nested", input: { policy: "standard", command: "PIPPA_ACTION_POLICY=standard osascript send.scpt" } });
		assert.equal(result.block, true, toolName);
		assert.equal(JSON.parse(result.reason).dispatched, false);
	}
	for (const toolName of DRAFT_TOOLS) assert.equal(await handlers.tool_call({ toolName, input: {} }), undefined);
	assert.equal(actionPolicy({ PIPPA_ACTION_POLICY: "misspelled" }), "draftOnly");
});

test("standard native work remains available; Pi's direct unsandboxed RPC shell is never exposed", async () => {
	const { handlers } = loaded("standard");
	for (const toolName of ["write", "bash", "mcp__pippa__reminder_add", "mcp__pippa__mail_draft", "mcp__pippa__prepare_files"]) {
		assert.equal(await handlers.tool_call({ toolName, input: {} }), undefined);
	}
	assert.equal((await handlers.user_bash({ command: "echo unsafe > /tmp/fixture" })).result.exitCode, 1);
});

test("policy attestation is read-only, nonce-bound and rejects a widened active inventory", async () => {
	const nonce = "12345678-1234-1234-1234-123456789abc";
	for (const widened of [false, true]) {
		const p = loaded("draftOnly", widened ? [...DRAFT_TOOLS, "bash"] : DRAFT_TOOLS);
		await p.commands[POLICY_COMMAND].handler("standard");
		assert.equal(p.entries.length, 0, "commands cannot change the scope");
		await p.commands[POLICY_COMMAND].handler(nonce);
		assert.equal(p.entries[0].data.policy, "draftOnly");
		assert.equal(p.entries[0].data.status, widened ? "policyMismatch" : "ready");
		assert.equal((await p.handlers.tool_call({ toolName: "bash" })).block, true);
	}
});
