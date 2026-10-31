/** Trusted action scope comes from the app at process launch, never from a message, document or tool argument.
 * A draft-only process can read local context and produce answer text; it cannot execute shell, write files,
 * change native apps, remember facts, or reach arbitrary web endpoints. Restart Pi to change this scope.
 * Standard mode remains a general agent; this is not a sandbox around every standard-mode executor. */
export type ActionPolicy = "standard" | "draftOnly";
export const POLICY_COMMAND = "pippa-action-policy";
export const NATIVE_READERS = ["calendar_read", "reminders_read", "mail_search",
	"photos_search", "front_read", "read_document"];
export const DRAFT_TOOLS = ["read", "search_files", "list_folder", ...NATIVE_READERS.map((name) => `mcp__pippa__${name}`)];
// Keep every native tool registered for readiness; MCP exposure hides every non-reader from the model.
export const DRAFT_LAUNCH_TOOLS = ["read", "search_files", "list_folder", "mcp__pippa__*"];
const draftTools = new Set(DRAFT_TOOLS);

/** No setting is normal terminal use; a supplied but unknown scope fails closed. */
export function actionPolicy(env: Record<string, string | undefined> = process.env): ActionPolicy {
	return env.PIPPA_ACTION_POLICY === undefined || env.PIPPA_ACTION_POLICY === "standard" ? "standard" : "draftOnly";
}

export function policyBlock(policy: ActionPolicy, tool: string): string | undefined {
	if (policy === "standard" || draftTools.has(tool)) return undefined;
	return JSON.stringify({ done: false, status: "not_dispatched", dispatched: false, policy: "draftOnly",
		tell: "This task only prepares text for the person to review. Read the relevant local context and return the draft as your answer. Do not execute commands, save or change anything, use the web, or ask for broader access." });
}

export default function (pi: any) {
	const policy = actionPolicy();
	pi.on("tool_call", (event: any) => {
		const reason = policyBlock(policy, event.toolName);
		return reason ? { block: true, reason } : undefined;
	});
	// Pi's direct RPC/! shell bypasses the tool wrapper. Pippa never exposes it; refuse instead of running unsandboxed.
	pi.on("user_bash", () => ({ result: { output: "Direct shell execution is disabled in Pippa. Use the available task tools.",
		exitCode: 1, cancelled: false, truncated: false } }));
	// This read-only attestation cannot widen authority, even if typed by the person as a slash command.
	pi.registerCommand(POLICY_COMMAND, {
		description: "Verify Pippa's action scope before starting a task.",
		handler: async (nonce: string) => {
			if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(nonce)) return;
			const active = pi.getActiveTools();
			const status = policy === "draftOnly" && active.some((name: string) => !draftTools.has(name)) ? "policyMismatch" : "ready";
			pi.appendEntry(POLICY_COMMAND, { v: 1, nonce, policy, status, tools: active });
		},
	});
}
