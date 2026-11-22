/**
 * `ask`: Pippa asks the person one question with a few choices, shown as a card in the chat and on Pippa Island
 * (Pi's `select`, then `input` for an answer in their own words). The model asks only when it cannot go on without
 * the person; when to ask stands in the system prompt (PippaPiLaunch.swift) and in this tool's description.
 *
 * Every outcome tells the model what to do next, so a small model does not ask again or stop: a closed card means
 * "go on with the most reasonable reading and name it", and without anyone to ask (a run without the app) the same.
 */
export const ASK_DESCRIPTION =
	"Ask one question as a card (never list options in plain text) when you need the person's decision: several things match, readings differ, only they know, or they ask for options or a question. 2-4 short choices; they can type their own. Never ask to confirm a choice the person already stated.";

const MAX_CHOICES = 4;

export type AskUI = {
	select(title: string, options: string[]): Promise<string | undefined>;
	input(title: string, placeholder?: string): Promise<string | undefined>;
};

/** The extra choice that lets the person answer in their own words, in the app's language. */
export function otherChoice(language = process.env.PIPPA_LANGUAGE ?? ""): string {
	return language.startsWith("de") ? "Etwas anderes …" : "Something else…";
}

/** Distinct, trimmed, non-empty choices, at most four; the "other" choice is never one of them. */
export function cleanChoices(raw: unknown, other: string): string[] {
	const seen = new Set<string>();
	const out: string[] = [];
	for (const value of Array.isArray(raw) ? raw : []) {
		const text = String(value ?? "").replace(/\s+/g, " ").trim().slice(0, 120);
		if (!text || text === other || seen.has(text.toLowerCase())) continue;
		seen.add(text.toLowerCase());
		out.push(text);
	}
	return out.slice(0, MAX_CHOICES);
}

const NO_ANSWER = "No answer: the person closed the question. Do not ask again. Go on with the most reasonable reading, and say in one sentence what you assumed.";
const NO_ONE = "No one can answer now. Do not ask. Go on with the most reasonable reading, and say in one sentence what you assumed.";

/** Asks and returns the text the model reads. */
export async function ask(params: any, ui: AskUI | undefined, language = process.env.PIPPA_LANGUAGE ?? ""): Promise<string> {
	const question = String(params?.question ?? "").replace(/\s+/g, " ").trim();
	if (!question) return "Not asked: question is empty. Write the question in the person's language.";
	if (!ui) return NO_ONE;
	const other = otherChoice(language);
	const choices = cleanChoices(params?.choices, other);
	let answer = choices.length ? await ui.select(question, [...choices, other]) : undefined;
	if (!choices.length || answer === other) answer = await ui.input(question);
	answer = answer?.trim();
	if (!answer) return NO_ANSWER;
	return `The person answered: ${JSON.stringify(answer)}. Go on with that; do not ask again about the same thing.`;
}

export function askTool() {
	return {
		name: "ask",
		label: "Nachfragen",
		description: ASK_DESCRIPTION,
		// Plain JSON schema like `remember` (pippa-memory.ts): no import from Pi, so the tests run without it.
		parameters: {
			type: "object",
			properties: {
				question: { type: "string", description: "One short question in the person's language." },
				choices: { type: "array", items: { type: "string" }, description: "2-4 real options, each one short line that tells it apart; omit for an open question." },
			},
			required: ["question"],
			additionalProperties: false,
		},
		annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: false },
		executionMode: "sequential",
		async execute(_id: string, params: any, _signal: AbortSignal | undefined, _onUpdate: unknown, ctx: any) {
			const ui = ctx?.hasUI && ctx?.ui?.select && ctx?.ui?.input
				? { select: (t: string, o: string[]) => ctx.ui.select(t, o), input: (t: string, p?: string) => ctx.ui.input(t, p) }
				: undefined;
			const text = await ask(params, ui);
			return { content: [{ type: "text", text }], details: { asked: Boolean(ui) } };
		},
	};
}
