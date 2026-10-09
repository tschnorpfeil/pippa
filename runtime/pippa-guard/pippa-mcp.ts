/**
 * Registers Pippa's MCP server for this one Pi session. Only Pippa loads this file, next to the guard and file tools:
 *
 *   pi --mode rpc --extension …/pippa-guard.ts --extension …/pippa-tools.ts --extension …/pippa-mcp.ts
 *
 * The app serves MCP itself on 127.0.0.1 (Calendar, Reminders, Mail, Excel read; TCC asks for "Pippa") and passes
 * address and key only in the environment of this Pi process:
 * - `PIPPA_MCP_URL`   e.g. http://127.0.0.1:53124/mcp (only loopback is accepted)
 * - `PIPPA_MCP_TOKEN` 64 hex characters, new on every app start
 * - `PIPPA_MCP_EXPOSURE` optional, `direct` (default) or `codemode` (for measuring only)
 *
 * `pi.registerMcpServer` instead of `~/.pi/agent/mcp.json`: nothing is written into the person's configuration, a
 * terminal Pi never sees the server, and restarting the app makes the old key worthless. The key is deleted from
 * `process.env` afterwards so no bash command inherits it.
 */
type ExtensionAPI = any;

export const SERVER_NAME = "pippa";

/** Read-only tools of the server (app/Sources/PippaCore/MCP/PippaMCPTools.swift, PippaMCPTurn.swift). None changes
 * anything on the Mac; `web_search` and `read_web_page` go online after the person clicks (self-asking.ts). */
export const TOOLS = ["calendar_read", "reminders_read", "mail_selected", "mail_search", "excel_selection", "read_document", "search_documents", "web_search", "read_web_page"];

/** PippaMCPWrite.swift: change something on the Mac but never leave it (no sending, no invitation). Events and
 * reminders can be undone, the mail draft stays unsent in Mail. Kind `appEntry` (policy.ts). */
export const WRITE_TOOLS = ["calendar_add", "reminder_add", "mail_draft"];

/** Entry as in `mcp.json`, or `undefined` if the environment does not fit (then no server, no error). */
export function serverConfig(env: Record<string, string | undefined>) {
	const url = env.PIPPA_MCP_URL ?? "";
	const token = env.PIPPA_MCP_TOKEN ?? "";
	if (!/^[0-9a-f]{64}$/.test(token)) return undefined;
	let parsed: URL;
	try {
		parsed = new URL(url);
	} catch {
		return undefined;
	}
	if (parsed.protocol !== "http:" || parsed.hostname !== "127.0.0.1" || parsed.pathname !== "/mcp") return undefined;
	const exposure = env.PIPPA_MCP_EXPOSURE === "codemode" ? "codemode" : "direct";
	return {
		url: parsed.toString(),
		headers: { Authorization: `Bearer ${token}` },
		exposure,
		description: "Pippa: read Calendar, Reminders, Mail, Excel and documents on this Mac; add events and reminders, unsent Mail drafts; look things up online after the person agrees.",
		// Online lookup waits for the person's click (card in the conversation), and text recognition on many pages
		// takes a while: 5 minutes instead of 1. The app's server keeps the connection open accordingly (PippaMCPServer).
		timeout: 300,
	};
}

export default function (pi: ExtensionAPI) {
	const config = serverConfig(process.env);
	delete process.env.PIPPA_MCP_TOKEN;
	if (!config) return;
	pi.registerMcpServer(SERVER_NAME, config);
}
