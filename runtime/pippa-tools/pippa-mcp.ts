/**
 * Registers Pippa's MCP server for this one Pi session. Only Pippa loads this file, next to its file tools:
 *
 *   pi --mode rpc --extension …/pippa-tools.ts --extension …/pippa-mcp.ts
 *
 * The app serves MCP itself on 127.0.0.1 (Calendar, Reminders, Mail, Photos, documents, the app in front read; TCC asks for "Pippa") and passes
 * address and key only in the environment of this Pi process:
 * - `PIPPA_MCP_URL`   e.g. http://127.0.0.1:53124/mcp (only loopback is accepted)
 * - `PIPPA_MCP_TOKEN` 64 hex characters, new for every Pi process
 * - `PIPPA_MCP_EXPOSURE` optional, `direct` (default), `direct+codemode` (an online AI with Mac access: the tools stay
 *   declared and Pi's `codemode` tool is active next to them, `codemode.mode: "on"`) or `codemode` (for measuring only)
 *
 * `pi.registerMcpServer` instead of `~/.pi/agent/mcp.json`: nothing is written into the person's configuration, a
 * terminal Pi never sees the server, and restarting the app makes the old key worthless. The key is deleted from
 * `process.env` afterwards so no bash command inherits it.
 */
import { egress } from "./egress.ts";

type ExtensionAPI = any;

export const SERVER_NAME = "pippa";

/** Read-only tools of the server (app/Sources/PippaCore/MCP/PippaMCPTools.swift, PippaMCPTurn.swift). None changes
 * anything on the Mac. Web search is not here: it is the Pi package pi-web-access (runtime/pippa-web). */
export const TOOLS = ["calendar_read", "reminders_read", "mail_search", "mail_read", "mail_folders", "photos_search", "front_read", "notes_read", "contacts_search", "compute", "read_document"];

/** Native changes stay on the Mac (no sending or invitation). Events, reminders and mail moves can be undone,
 * mail drafts remain unsent, and prepared PDFs preserve their original files. */
export const WRITE_TOOLS = ["calendar_add", "reminder_add", "mail_draft", "mail_move", "calendar_update", "reminder_update", "prepare_files"];

/** Sends one draft Pippa saved with mail_draft in this conversation, only after the person pressed Send on Pippa's
 * card (app/Sources/PippaCore/MCP/PippaMCPMailSend.swift). The card and the gate live in the app's server. */
export const SEND_TOOLS = ["mail_send"];

/** Pippa's browser panel (app/Sources/PippaCore/MCP/PippaMCPBrowser.swift): goes online, so the app asks the person
 * before it opens a new site and before every click, typed text or choice (a whole form is one question). Following a
 * plain link (no query) to another page of the same allowed host opens it like `open`. Logins stay with the person. */
export const BROWSER_TOOLS = ["browse"];

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
	// `direct+codemode` keeps the server `direct`; the codemode tool is the extension's own (`withCodemode`).
	// A read-only background routine always stays `direct`.
	const exposure = !isReadOnly(env) && env.PIPPA_MCP_EXPOSURE === "codemode" ? "codemode" : "direct";
	return {
		url: parsed.toString(),
		headers: { Authorization: `Bearer ${token}` },
		exposure,
		description: "Pippa: read Calendar, Reminders, Mail, Notes, Contacts, Safari tabs, Excel, Photos and documents; exact math/date compute; add or update events and reminders; create and send saved Mail drafts after the person's click; move mails into existing folders; prepare verified PDFs locally; browse web pages in Pippa's panel with the person's OK.",
		// Text recognition on many pages takes a while: 5 minutes instead of 1. The app's server keeps the connection
		// open accordingly (PippaMCPServer).
		timeout: 300,
	};
}

/** `PIPPA_MCP_EXPOSURE` for an online AI with Mac access (PippaPiLaunch.MCPEndpoint.directWithCodemode). */
export const CODEMODE_EXPOSURE = "direct+codemode";
export const CODEMODE_TOOL = "codemode";

/** Whether this Pi runs a read-only background routine (`PIPPA_READ_ONLY=1`). */
export function isReadOnly(env: Record<string, string | undefined> = process.env): boolean {
	return env.PIPPA_READ_ONLY === "1";
}

/** Whether this Pi gets Pi's `codemode` tool next to the declared tools. Only by the app's switch; the person's
 * settings (`defaultTools`, `codemode.mode`) never decide it, and this process alone is affected. Never in read-only mode. */
export function withCodemode(env: Record<string, string | undefined> = process.env): boolean {
	return !isReadOnly(env) && env.PIPPA_MCP_EXPOSURE === CODEMODE_EXPOSURE;
}

export const READINESS_COMMAND = "pippa-native-ready";
export const READ_ONLY_TOOLS = TOOLS.map((name) => `mcp__${SERVER_NAME}__${name}`);
export const READ_ONLY_FORBIDDEN_TOOLS = [...WRITE_TOOLS, ...BROWSER_TOOLS, ...SEND_TOOLS].map((name) => `mcp__${SERVER_NAME}__${name}`);
export const REQUIRED_TOOLS = [...TOOLS, ...WRITE_TOOLS, ...BROWSER_TOOLS, ...SEND_TOOLS].map((name) => `mcp__${SERVER_NAME}__${name}`);

/** The tools this process must have: all of them for the AI on this Mac; for a read-only routine only the readers
 * (`PIPPA_READ_ONLY=1`); for an online AI exactly the app's list (egress.ts), and none of the others may even be
 * registered (the app's server lists only those). `codemode`: whether the codemode tool must be active
 * (`withCodemode`); otherwise it must not be. */
export function requiredTools(env: Record<string, string | undefined> = process.env): { required: string[]; forbidden: string[]; codemode: boolean } {
	const online = egress(env);
	const readOnlyMode = isReadOnly(env);
	// Read-only background routines never run against an online route; fail closed if both variables appear.
	if (readOnlyMode && online) return { required: [], forbidden: REQUIRED_TOOLS, codemode: false };
	if (readOnlyMode) return { required: READ_ONLY_TOOLS, forbidden: READ_ONLY_FORBIDDEN_TOOLS, codemode: false };
	const codemode = !online && withCodemode(env);
	if (!online) return { required: REQUIRED_TOOLS, forbidden: [], codemode };
	const required = REQUIRED_TOOLS.filter((name) => online.tools.has(name));
	return { required, forbidden: REQUIRED_TOOLS.filter((name) => !online.tools.has(name)), codemode };
}

/** Background discovery may still be connecting when RPC starts accepting commands. No model call or mutation. */
export async function discoverNativeTools(pi: ExtensionAPI, config: ReturnType<typeof serverConfig>,
	waitMilliseconds = 8_000, signal?: AbortSignal, expected = requiredTools()) {
	const deadline = Date.now() + waitMilliseconds;
	const { required, forbidden } = expected;
	const codemode = expected.codemode === true;
	for (;;) {
		if (signal?.aborted) return { status: "cancelled" };
		const registered = pi.getMcpServers().find((server: any) => server.name === SERVER_NAME)?.config;
		if (!config || config.exposure !== "direct" || registered?.url !== config.url
			|| registered?.headers?.Authorization !== config.headers.Authorization || registered?.exposure !== "direct"
			|| registered?.toolExposure !== undefined) {
			return { status: "registrationMismatch" };
		}
		const registeredTools = pi.getAllTools().map((tool: any) => tool.name);
		const active = pi.getActiveTools();
		if (forbidden.some((name) => registeredTools.includes(name) || active.includes(name))) return { status: "registrationMismatch" };
		// Scripts reach every tool of this process: never active unless the app asked for it.
		if (!codemode && (registeredTools.includes(CODEMODE_TOOL) || active.includes(CODEMODE_TOOL))) return { status: "registrationMismatch" };
		const scripts = !codemode || (registeredTools.includes(CODEMODE_TOOL) && active.includes(CODEMODE_TOOL));
		if (scripts && required.every((name) => registeredTools.includes(name) && active.includes(name))) {
			return { status: "ready", tools: required, registeredTools: required };
		}
		if (Date.now() >= deadline) return { status: "toolsUnavailable" };
		await new Promise((resolve) => setTimeout(resolve, Math.min(50, Math.max(1, deadline - Date.now()))));
	}
}

type Factory = (options: any) => (pi: ExtensionAPI) => unknown;

export default async function (pi: ExtensionAPI, connectorFactory?: Factory, codemodeFactory?: Factory) {
	const config = serverConfig(process.env);
	const codemode = withCodemode(process.env) && !egress(process.env);
	delete process.env.PIPPA_MCP_TOKEN;
	if (!config) return;
	// --no-extensions also disables Pi's built-in MCP connector. Use the same pinned public implementation,
	// scoped to extension registrations: never start unrelated servers from shared or project mcp.json files.
	const pippaPi = connectorFactory && (!codemode || codemodeFactory) ? undefined : await import("@earendil-works/pi-coding-agent");
	const createConnector = connectorFactory ?? pippaPi!.createMcpExtension;
	await createConnector({ loadConfig: () => ({ servers: [], errors: [], autoEnableCodemode: false }) })(pi);
	pi.registerMcpServer(SERVER_NAME, config);
	if (codemode) {
		// The built-in codemode is dropped with --no-extensions too. Mode and the model catalog are fixed here, so the
		// person's `codemode.mode` cannot hide the declared tools, and scripts reach no other model or provider.
		// Registered inactive: the app names it in this process's `--tools` (PippaPiLaunch.addMCP), which Pi needs anyway,
		// since a tool `--tools` does not name is not registered at all.
		await (codemodeFactory ?? pippaPi!.createCodemodeExtension)({ mode: "on", models: false })(pi);
	}
	pi.registerCommand(READINESS_COMMAND, {
		description: "Check Pippa's native tools before starting a conversation.",
		handler: async (args: string, ctx: any) => {
			// No arbitrary payload in the session journal; one fresh, app-generated UUID binds the receipt.
			if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(args)) return;
			const result = await discoverNativeTools(pi, config, 8_000, ctx.signal);
			pi.appendEntry(READINESS_COMMAND, { v: 1, nonce: args, ...result });
		},
	});
}
