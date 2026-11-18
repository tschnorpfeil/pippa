/**
 * What an online AI's Pi may do (issue #193). The app sets PIPPA_EGRESS=online and PIPPA_EGRESS_TOOLS (the same list
 * it passes with --tools) when a Pi provider or an older online connection answers. Then:
 *
 * - pippa-tools.ts registers only `ask`: no file, folder, search, shell or document tools exist in that process;
 * - every tool call outside the list is blocked before it runs (`blockReason`), whatever Pi or a provider declares;
 * - each provider request carries only the listed tools (`onlyAllowedTools`), so a tool from elsewhere is never offered;
 * - the working-folder path in Pi's system prompt is replaced (`hideWorkingFolder`): it names the person's home folder.
 *
 * The person's data reaches the online AI only as text they reviewed and approved in the app.
 */

export type Egress = { tools: Set<string> };

export function egress(env: Record<string, string | undefined> = process.env): Egress | undefined {
	if (env.PIPPA_EGRESS === undefined) return undefined;
	// Any value other than the known one fails closed: no tools at all.
	const tools = env.PIPPA_EGRESS === "online" ? (env.PIPPA_EGRESS_TOOLS ?? "").split(",").map((t) => t.trim()).filter(Boolean) : [];
	return { tools: new Set(tools) };
}

export function allows(egress: Egress, tool: string): boolean {
	return egress.tools.has(tool);
}

/** A sentence the model can pass on when it reached for something that stays on this Mac. */
export function blockReason(egress: Egress, tool: string): string | undefined {
	if (allows(egress, tool)) return undefined;
	return JSON.stringify({
		done: false, status: "stays_on_mac", tool,
		next: "This online AI cannot read or change files, mail, calendar, reminders or photos on this Mac. Tell the person in one "
			+ "sentence: they can add what you need with the + button in Pippa, check it, and send it, or ask the AI on this Mac.",
	});
}

/** Removes every tool the list does not name from a provider request (OpenAI chat, Responses API, Anthropic shapes). */
export function onlyAllowedTools(egress: Egress, payload: any): any {
	if (!payload || !Array.isArray(payload.tools)) return undefined;
	const tools = payload.tools.filter((tool: any) => {
		const name = tool?.function?.name ?? tool?.name;
		return typeof name === "string" && allows(egress, name);
	});
	if (tools.length === payload.tools.length) return undefined;
	const next = { ...payload, tools };
	if (tools.length === 0) { delete next.tools; delete next.tool_choice; }
	return next;
}

export const HIDDEN_FOLDER = "(not shared with the online AI)";

/** Pi puts its working folder (inside the person's home folder) into the system prompt; an online AI gets none. */
export function hideWorkingFolder(event: any): void {
	const sections = event?.systemPromptOptions?.sections;
	if (sections && typeof sections === "object") sections.cwd = HIDDEN_FOLDER;
}
