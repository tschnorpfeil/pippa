/** Limit declarations for clear read-only requests without changing Pi's permission or registration inventory.
 * MCP discovery can rebuild Pi's active list after before_agent_start. Filter the final provider payload instead;
 * the loader restores declarations, while the existing launch/policy boundary continues to govern execution.
 */
export const EXPAND_TOOL = "pippa_more_tools";
const DOCUMENT_TOOLS = [
  "read",
  "search_files",
  "list_folder",
  "mcp__pippa__read_document",
  "web_search",
  "fetch_content",
  EXPAND_TOOL,
];
const WEB_TOOLS = ["read", "web_search", "fetch_content", EXPAND_TOOL];
export function scopedTools(prompt, allowed) {
  if (!allowed.includes(EXPAND_TOOL)) return [...allowed];
  const text = String(prompt ?? "")
    .toLowerCase()
    .normalize("NFKD")
    .replace(/\p{M}/gu, "");
  if (
    /\/skill:|\b(mail|email|e-mail|entwurf|draft|reply|remind\w*|erinner\w*|termin\w*|kalender|calendar|schedule|verschieb\w*|sortier\w*|losch\w*|delete|move|rename|umbenenn\w*|schreib\w*|write|edit|ander\w*|change|update|revise|copy|kopier\w*|combine|merge|prepare|convert|konvertier\w*|zusammenfug\w*|versandfertig|komprimier\w*|offne\w*|open|save|speicher\w*|erstell\w*|create|code|script|python|javascript|excel|foto\w*|photo\w*)\b/u.test(
      text,
    )
  )
    return [...allowed];
  if (
    /\[in front:|\[im vordergrund:|\b(hier|this app|dieses fenster)\b/.test(
      text,
    )
  )
    return [...allowed];
  const docs =
    /\b(zusammenfass\w*|fass\w*|summari[sz]\w*|vergleich\w*|compare|rechnung\w*|invoice\w*|versicherung\w*|insurance|mietvertrag|lease|brief|letter|dokument\w*|document\w*|datei\w*|files?|ordner|folder|kundigungsfrist|uberblick)\b/u.test(
      text,
    );
  const web =
    /\b(wetter|weather|offnungszeit\w*|opening hours|nachrichten|news|personalausweis|passport)\b/u.test(
      text,
    );
  const desired = docs ? DOCUMENT_TOOLS : web ? WEB_TOOLS : null;
  return desired
    ? allowed.filter((name) => desired.includes(name))
    : [...allowed];
}
export function installToolScope(pi) {
  if (process.env.PIPPA_TOOL_SCOPE === "off") return;
  let prompt = "",
    expanded = false,
    exposed = new Set();
  pi.registerTool({
    name: EXPAND_TOOL,
    label: "More tools",
    description:
      "Make the other tools available (file changes, mail, calendar, reminders, photos, spreadsheets, shell). Call when a tool needed for the request is missing.",
    parameters: { type: "object", properties: {}, additionalProperties: false },
    async execute() {
      expanded = true;
      return {
        content: [
          {
            type: "text",
            text: "The remaining permitted tools are now available. Continue the task.",
          },
        ],
      };
    },
  });
  pi.on("session_start", () => {
    prompt = "";
    expanded = false;
    exposed = new Set();
  });
  pi.on("before_agent_start", (event) => {
    if (event.messageType !== "user" || typeof event.prompt !== "string") {
      expanded = true;
      return;
    }
    prompt = event.prompt;
  });
  pi.on("input", (event) => {
    if (event.streamingBehavior) expanded = true;
  });
  pi.on("before_provider_request", (event) => {
    const payload = event?.payload;
    // Pippa's current providers use OpenAI chat completions. Other API formats retain their full tools.
    if (
      payload?.tool_choice?.type === "function" ||
      !Array.isArray(payload?.tools) ||
      !payload.tools.every(
        (t) => t?.type === "function" && typeof t.function?.name === "string",
      )
    )
      return;
    if (expanded) {
      payload.tools = payload.tools.filter(
        (t) => t.function.name !== EXPAND_TOOL,
      );
      return;
    }
    const allowed = payload.tools.map((t) => t.function.name);
    for (const name of scopedTools(prompt, allowed)) exposed.add(name);
    // Intersection with this request's permitted declarations: never add a tool, even after policy changes.
    payload.tools = payload.tools.filter((t) => exposed.has(t.function.name));
    // When all permitted tools are already visible the loader has no purpose and only costs tokens.
    if (payload.tools.length === allowed.length)
      payload.tools = payload.tools.filter(
        (t) => t.function.name !== EXPAND_TOOL,
      );
  });
}
