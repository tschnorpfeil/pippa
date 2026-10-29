/**
 * Registers Pippa's MCP server for this one Pi session. Only Pippa loads this file, next to its file tools:
 *
 *   pi --mode rpc --extension …/pippa-tools.ts --extension …/pippa-mcp.ts
 *
 * The app serves MCP itself on 127.0.0.1 (Calendar, Reminders, Mail, Excel, Photos, the app in front read; TCC asks for "Pippa") and passes
 * address and key only in the environment of this Pi process:
 * - `PIPPA_MCP_URL`   e.g. http://127.0.0.1:53124/mcp (only loopback is accepted)
 * - `PIPPA_MCP_TOKEN` 64 hex characters, new for every Pi process
 * - `PIPPA_MCP_EXPOSURE` optional, `direct` (default) or `codemode` (for measuring only)
 *
 * `pi.registerMcpServer` instead of `~/.pi/agent/mcp.json`: nothing is written into the person's configuration, a
 * terminal Pi never sees the server, and restarting the app makes the old key worthless. The key is deleted from
 * `process.env` afterwards so no bash command inherits it.
 */
import { actionPolicy, NATIVE_READERS, type ActionPolicy } from "./pippa-policy.ts";

type ExtensionAPI = any;

export const SERVER_NAME = "pippa";

/** Read-only tools of the server (app/Sources/PippaCore/MCP/PippaMCPTools.swift, PippaMCPTurn.swift). None changes
 * anything on the Mac. Web search is not here: it is the Pi package pi-web-access (runtime/pippa-web). */
export const TOOLS = NATIVE_READERS;

/** Native changes stay on the Mac (no sending or invitation). Events and reminders can be undone,
 * mail drafts remain unsent, and prepared PDFs preserve their original files. */
export const WRITE_TOOLS = ["calendar_add", "reminder_add", "mail_draft", "prepare_files"];

/** Read-only, but not for draft-only tasks: a chart card Pippa computes from a table file (PippaMCPChart.swift). Not a
 * native reader, so draft exposure hides it through the wildcard. */
export const VIEW_TOOLS = ["make_chart"];

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
		// Exact reader overrides beat the wildcard. Unknown future native tools also stay hidden in draft tasks.
		...(actionPolicy(env) === "draftOnly" ? { toolExposure: { "*": "hidden", ...Object.fromEntries(TOOLS.map((name) => [name, "direct"])) } } : {}),
		description: "Pippa: read Calendar, Reminders, Mail, Excel, Photos and documents; add events, reminders and unsent Mail drafts; prepare verified PDFs locally; chart tables.",
		// Text recognition on many pages takes a while: 5 minutes instead of 1. The app's server keeps the connection
		// open accordingly (PippaMCPServer).
		timeout: 300,
	};
}

function exposureKey(exposure: Record<string, unknown> | undefined): string {
	return JSON.stringify(Object.entries(exposure ?? {}).sort(([a], [b]) => a.localeCompare(b)));
}

export const READINESS_COMMAND = "pippa-native-ready";
export const REQUIRED_TOOLS = [...TOOLS, ...WRITE_TOOLS, ...VIEW_TOOLS].map((name) => `mcp__${SERVER_NAME}__${name}`);

/** Background discovery may still be connecting when RPC starts accepting commands. No model call or mutation. */
export async function discoverNativeTools(pi: ExtensionAPI, config: ReturnType<typeof serverConfig>,
	waitMilliseconds = 8_000, signal?: AbortSignal, policy: ActionPolicy = "standard") {
	const deadline = Date.now() + waitMilliseconds;
	for (;;) {
		if (signal?.aborted) return { status: "cancelled" };
		const registered = pi.getMcpServers().find((server: any) => server.name === SERVER_NAME)?.config;
		if (!config || config.exposure !== "direct" || registered?.url !== config.url
			|| registered?.headers?.Authorization !== config.headers.Authorization || registered?.exposure !== "direct"
			|| exposureKey(registered?.toolExposure) !== exposureKey(config.toolExposure)) {
			return { status: "registrationMismatch" };
		}
		const registeredTools = pi.getAllTools().map((tool: any) => tool.name);
		const tools = policy === "draftOnly" ? TOOLS.map((name) => `mcp__${SERVER_NAME}__${name}`) : REQUIRED_TOOLS;
		const active = pi.getActiveTools();
		if (REQUIRED_TOOLS.every((name) => registeredTools.includes(name)) && tools.every((name) => active.includes(name))) {
			return { status: "ready", tools, registeredTools: REQUIRED_TOOLS };
		}
		if (Date.now() >= deadline) return { status: "toolsUnavailable" };
		await new Promise((resolve) => setTimeout(resolve, Math.min(50, Math.max(1, deadline - Date.now()))));
	}
}

export default async function (pi: ExtensionAPI, connectorFactory?: (options: any) => (pi: ExtensionAPI) => unknown) {
	const config = serverConfig(process.env);
	const policy = actionPolicy();
	delete process.env.PIPPA_MCP_TOKEN;
	if (!config) return;
	// --no-extensions also disables Pi's built-in MCP connector. Use the same pinned public implementation,
	// scoped to extension registrations: never start unrelated servers from shared or project mcp.json files.
	const createConnector = connectorFactory ?? (await import("@earendil-works/pi-coding-agent")).createMcpExtension;
	await createConnector({ loadConfig: () => ({ servers: [], errors: [], autoEnableCodemode: false }) })(pi);
	pi.registerMcpServer(SERVER_NAME, config);
	pi.registerCommand(READINESS_COMMAND, {
		description: "Check Pippa's native tools before starting a conversation.",
		handler: async (args: string, ctx: any) => {
			// No arbitrary payload in the session journal; one fresh, app-generated UUID binds the receipt.
			if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(args)) return;
			const result = await discoverNativeTools(pi, config, 8_000, ctx.signal, policy);
			pi.appendEntry(READINESS_COMMAND, { v: 1, nonce: args, ...result });
		},
	});
}
