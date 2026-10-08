/**
 * Tools that ask themselves: `web_search` and `read_web_page` on Pippa's own MCP server. Their category is "network"
 * (leaves the Mac), and the question is asked exactly once per request, but not by the guard: Pippa's server shows the
 * card in the conversation (WebAccessGate) with the text that would actually go out after QueryGuard, and fetches only
 * after the click. If the guard asked as well, the person would see two questions, and the guard's would show the raw
 * model text instead of the cleaned one.
 *
 * Only Pippa's server is believed (trusted MCP names, source Pi/Pippa), and only for these two names with
 * `readOnlyHint: true` (changes nothing on the Mac). Same-named tools from other servers or extensions ask like any
 * foreign tool.
 */
export const SELF_ASKING = new Set(["web_search", "read_web_page"]);

/** `trusted`: does the tool come from Pi or Pippa (pippa-guard.ts `trustedSource`)? */
export function asksItself(tool: string, info: any, trustedMcp: Set<string>, trusted: (source: any) => boolean): boolean {
	if (!info) return false;
	const match = tool.match(/^mcp__(.+?)__(.+)$/);
	if (!match || !trustedMcp.has(match[1]) || !SELF_ASKING.has(match[2])) return false;
	if (info.annotations?.readOnlyHint !== true || info.annotations?.destructiveHint === true) return false;
	return trusted(info.sourceInfo);
}

/**
 * Pippa's writing MCP tools mapped to the action in the receipt. They change something on the Mac
 * (`readOnlyHint: false`), can be undone or stay an unsent draft (`destructiveHint: false`) and never leave the Mac
 * (`openWorldHint: false`). Kind "appEntry" (policy.ts): `undo-first` does not ask, `ask-all` asks. Pippa's server
 * builds the receipt itself (`structuredContent.pippaReceipt`); the guard takes it over.
 */
export type AppEntry = "calendarAdd" | "reminderAdd" | "mailDraft";
export const APP_ENTRIES: Record<string, AppEntry> = {
	calendar_add: "calendarAdd",
	reminder_add: "reminderAdd",
	mail_draft: "mailDraft",
};

/**
 * The action if `tool` is one of Pippa's writing tools: only a trusted server (`PIPPA_GUARD_TRUSTED_MCP`), source
 * Pi/Pippa and exactly these hints. Otherwise `undefined` (the guard then asks like for any foreign tool).
 */
export function appEntry(tool: string, info: any, trustedMcp: Set<string>, trusted: (source: any) => boolean): AppEntry | undefined {
	if (!info) return undefined;
	const match = tool.match(/^mcp__(.+?)__(.+)$/);
	if (!match || !trustedMcp.has(match[1]) || !Object.hasOwn(APP_ENTRIES, match[2])) return undefined;
	const hints = info.annotations;
	if (hints?.readOnlyHint !== false || hints?.destructiveHint !== false || hints?.openWorldHint !== false) return undefined;
	return trusted(info.sourceInfo) ? APP_ENTRIES[match[2]] : undefined;
}

/**
 * The receipt from Pippa's server in the `tool_result` (Pi passes the MCP result without `_meta` through as
 * `structuredContent`; the model does not see it). Only known fields of the right type; `undo` only inside `undoRoot`.
 */
export function serverReceipt(event: any, undoRoot: string): { outcome?: string; name?: string; undo?: string; restorable: boolean; reason?: string } | undefined {
	const outer = event?.structuredContent;
	const raw = outer?.pippaReceipt ?? outer?.structuredContent?.pippaReceipt;
	if (!raw || typeof raw !== "object") return undefined;
	const text = (value: unknown, max: number) => (typeof value === "string" && value.length > 0 && value.length <= max ? value : undefined);
	const outcome = ["done", "failed", "unclear"].includes(raw.outcome) ? raw.outcome : undefined;
	const root = undoRoot.endsWith("/") ? undoRoot : `${undoRoot}/`;
	const undo = text(raw.undo, 1024);
	const inside = undo !== undefined && undo.startsWith(root) && !undo.includes("/../");
	return {
		outcome,
		name: text(raw.name, 300),
		undo: inside ? undo : undefined,
		restorable: inside && raw.restorable === true,
		reason: text(raw.reason, 40),
	};
}
