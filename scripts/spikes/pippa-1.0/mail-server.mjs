#!/usr/bin/env node
// Synthetic Mail MCP server for the Pippa 1.0 spike (docs/pippa-1.0.md). Stdio, newline-delimited JSON-RPC.
// 240 invented mails in an inbox and seven existing folders. No real mail, names or companies.
//
// Tools, shaped like the 1.0 proposal: mail_folders (tree with counts and samples), mail_search (pages of at most
// SPIKE_PAGE entries, cursor), mail_move (refs, target folder, dry_run; verifies against the target folder).
// With SPIKE_SORT=1 also mail_sort: a plan without the model, from which senders already file into which folder;
// mail_move then applies it by its plan id.
// Every call and the final placement go to SPIKE_LOG (JSONL), which run.mjs scores against the invented truth.
import { appendFileSync } from "node:fs";
import { createInterface } from "node:readline";

const PAGE = Number(process.env.SPIKE_PAGE ?? 20);
const LOG = process.env.SPIKE_LOG;
const log = (entry) => { if (LOG) appendFileSync(LOG, JSON.stringify(entry) + "\n"); };

const KINDS = [
	{ folder: "Invoices", count: 45, from: ["billing@powerworks.example", "invoice@telco-one.example", "accounts@waterboard.example"],
	  subject: (i) => `Your invoice no. 2026-${String(1000 + i)}` },
	{ folder: "Newsletters", count: 60, from: ["news@gardenleaf.example", "weekly@bookcorner.example", "digest@cyclingclub.example"],
	  subject: (i) => `Newsletter week ${1 + (i % 46)}: this week's picks` },
	{ folder: "Travel", count: 30, from: ["booking@railtrip.example", "stay@harbourhotel.example"],
	  subject: (i) => `Your booking ${String.fromCharCode(65 + (i % 26))}${7000 + i} is confirmed` },
	{ folder: "Insurance", count: 25, from: ["service@shieldmutual.example"],
	  subject: (i) => `Policy ${50000 + i}: your annual statement` },
	{ folder: "School", count: 30, from: ["office@hillside-primary.example"],
	  subject: (i) => `Parents' letter ${i + 1}: dates and reminders` },
	// Stay in the inbox: personal mail, and traps whose subject contains a folder word.
	{ folder: null, count: 44, from: ["anna@friends.example", "ben@friends.example", "carla@family.example", "dev@family.example"],
	  subject: (i) => ["Dinner on Friday?", "Photos from the weekend", "Can you call me back?", "Birthday plans", "Thanks for yesterday", "Quick question"][i % 6] },
	{ folder: null, count: 6, from: ["anna@friends.example", "carla@family.example"],
	  subject: (i) => ["Who pays the invoice for the trip?", "Did you see the school newsletter?", "Travel insurance, do we need one?",
	                   "Booking a table for Saturday", "Your invoice idea for grandma's gift", "Policy on shoes in the hallway :)"][i] },
];

// Deterministic shuffle so the inbox is mixed and every run sees the same order.
let seed = 20261119;
const random = () => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648; };
const mails = [];
for (const kind of KINDS) for (let i = 0; i < kind.count; i++) {
	mails.push({ truth: kind.folder, from: kind.from[i % kind.from.length], subject: kind.subject(i) });
}
for (let i = mails.length - 1; i > 0; i--) { const j = Math.floor(random() * (i + 1)); [mails[i], mails[j]] = [mails[j], mails[i]]; }
const start = Date.UTC(2026, 10, 18, 9, 0);
mails.forEach((mail, i) => { mail.ref = `m${String(i + 1).padStart(3, "0")}`; mail.date = new Date(start - i * 5_400_000).toISOString().slice(0, 16) + "Z"; mail.box = "Inbox"; });

const FOLDERS = ["Invoices", "Newsletters", "Travel", "Insurance", "School", "Archive", "Receipts 2025"];
const SAMPLES = {
	Invoices: [["billing@powerworks.example", "Your invoice no. 2026-0412"], ["invoice@telco-one.example", "Your invoice no. 2026-0398"]],
	Newsletters: [["news@gardenleaf.example", "Newsletter week 40: this week's picks"], ["weekly@bookcorner.example", "Newsletter week 39: this week's picks"]],
	Travel: [["booking@railtrip.example", "Your booking K6120 is confirmed"], ["stay@harbourhotel.example", "Your booking B6011 is confirmed"]],
	Insurance: [["service@shieldmutual.example", "Policy 48112: your annual statement"]],
	School: [["office@hillside-primary.example", "Parents' letter: dates and reminders"]],
	Archive: [["anna@friends.example", "Old holiday plans"]],
	"Receipts 2025": [["shop@stationery.example", "Receipt for your order"]],
};
const BASE = { Invoices: 212, Newsletters: 530, Travel: 64, Insurance: 31, School: 88, Archive: 1204, "Receipts 2025": 97 };

const SORT = process.env.SPIKE_SORT === "1";
// Who already files where: in the app this comes from the senders found in each folder.
const SENDER_FOLDER = new Map(KINDS.filter((kind) => kind.folder).flatMap((kind) => kind.from.map((from) => [from, kind.folder])));
const plans = new Map();

const inBox = (box) => mails.filter((mail) => mail.box === box);
const cursors = new Map();

const text = { type: "string" }, integer = { type: "integer" };
const TOOLS = [
	{ name: "mail_folders", description: "Existing folders with counts and sample mails.",
	  inputSchema: { type: "object", properties: {}, additionalProperties: false },
	  outputSchema: { type: "object", properties: { inbox: integer, folders: { type: "array", items: { type: "object",
	    properties: { name: text, count: integer, samples: { type: "array", items: { type: "object", properties: { from: text, subject: text } } } } } } } },
	  annotations: { readOnlyHint: true } },
	{ name: "mail_search", description: `Inbox mails, newest first, at most ${PAGE} per call. cursor=next page.`,
	  inputSchema: { type: "object", properties: { limit: integer, cursor: text }, additionalProperties: false },
	  outputSchema: { type: "object", properties: { total: integer, mails: { type: "array", items: { type: "object",
	    properties: { ref: text, from: text, subject: text, date: text } } }, cursor: text } },
	  annotations: { readOnlyHint: true } },
	{ name: "mail_move", description: "Move inbox mails to an existing folder. refs from mail_search (max 100). dry_run=true checks without moving. Undoable.",
	  inputSchema: { type: "object", properties: { refs: { type: "array", items: text }, to: text, dry_run: { type: "boolean" } },
	    required: ["refs", "to"], additionalProperties: false },
	  outputSchema: { type: "object", properties: { dry_run: { type: "boolean" }, to: text, moved: integer, verified: integer,
	    not_found: { type: "array", items: text }, inbox_left: integer } },
	  annotations: { readOnlyHint: false, destructiveHint: false } },
];
if (SORT) {
	TOOLS.push({ name: "mail_sort", description: "Dry run for the whole inbox: proposes a folder per mail from senders already filed there. Returns counts, examples and a plan id for mail_move. Moves nothing.",
		inputSchema: { type: "object", properties: {}, additionalProperties: false },
		outputSchema: { type: "object", properties: { plan: text, staying: integer, staying_examples: { type: "array", items: text },
			folders: { type: "array", items: { type: "object", properties: { to: text, count: integer, examples: { type: "array", items: text } } } } } },
		annotations: { readOnlyHint: true } });
	const move = TOOLS.find((tool) => tool.name === "mail_move");
	move.description = "Move inbox mails to an existing folder: plan=id from mail_sort applies that whole plan; or refs (max 100) + to. dry_run=true checks without moving. Undoable.";
	move.inputSchema = { type: "object", properties: { plan: text, refs: { type: "array", items: text }, to: text, dry_run: { type: "boolean" } }, additionalProperties: false };
}

function call(name, args) {
	if (name === "mail_folders") {
		return { inbox: inBox("Inbox").length, folders: FOLDERS.map((folder) => ({ name: folder, count: BASE[folder] + inBox(folder).length,
			samples: SAMPLES[folder].map(([from, subject]) => ({ from, subject })) })) };
	}
	if (name === "mail_search") {
		const limit = args.limit ?? PAGE;
		if (!Number.isInteger(limit) || limit < 1 || limit > PAGE) throw new Error(`limit must be 1 to ${PAGE}.`);
		let offset = 0;
		if (args.cursor !== undefined) {
			if (!cursors.has(args.cursor)) throw new Error("cursor must be the cursor from the last mail_search result.");
			offset = cursors.get(args.cursor);
		}
		const all = inBox("Inbox");
		const page = all.slice(offset, offset + limit).map(({ ref, from, subject, date }) => ({ ref, from, subject, date }));
		const result = { total: all.length, mails: page };
		if (offset + limit < all.length) { result.cursor = `c${cursors.size + 1}`; cursors.set(result.cursor, offset + limit); }
		return result;
	}
	if (name === "mail_sort" && SORT) {
		const groups = new Map();
		const staying = [];
		for (const mail of inBox("Inbox")) {
			const to = SENDER_FOLDER.get(mail.from);
			if (to) groups.set(to, [...(groups.get(to) ?? []), mail]); else staying.push(mail);
		}
		const plan = `p${plans.size + 1}`;
		plans.set(plan, [...groups].map(([to, list]) => ({ to, refs: list.map((mail) => mail.ref) })));
		return { plan, staying: staying.length, staying_examples: staying.slice(0, 3).map((mail) => `${mail.from}: ${mail.subject}`),
			folders: [...groups].map(([to, list]) => ({ to, count: list.length, examples: list.slice(0, 2).map((mail) => `${mail.from}: ${mail.subject}`) })) };
	}
	if (name === "mail_move" && SORT && args.plan !== undefined) {
		const steps = plans.get(args.plan);
		if (!steps) throw new Error("plan must be the plan id from mail_sort.");
		const dry = args.dry_run === true;
		let moved = 0, verified = 0;
		for (const step of steps) for (const ref of step.refs) {
			const mail = mails.find((m) => m.ref === ref && m.box === "Inbox");
			if (!mail) continue;
			if (!dry) { mail.box = step.to; moved++; }
			if (dry || mail.box === step.to) verified++;
		}
		return { dry_run: dry, to: "plan " + args.plan, moved, verified, not_found: [], inbox_left: inBox("Inbox").length };
	}
	if (name === "mail_move") {
		if (!Array.isArray(args.refs) || args.refs.length < 1 || args.refs.length > 100 || args.refs.some((ref) => typeof ref !== "string")) {
			throw new Error("refs must be 1 to 100 refs from mail_search.");
		}
		if (!FOLDERS.includes(args.to)) throw new Error(`to must be an existing folder: ${FOLDERS.join(", ")}.`);
		const dry = args.dry_run === true;
		const found = [], missing = [];
		for (const ref of new Set(args.refs)) {
			const mail = mails.find((m) => m.ref === ref && m.box === "Inbox");
			if (mail) found.push(mail); else missing.push(ref);
		}
		if (!dry) for (const mail of found) mail.box = args.to;
		return { dry_run: dry, to: args.to, moved: dry ? 0 : found.length, verified: dry ? found.length : found.filter((m) => m.box === args.to).length,
			not_found: missing, inbox_left: inBox("Inbox").length };
	}
	throw new Error(`Unknown tool: ${name}`);
}

function score() {
	const out = { correct: 0, wrongFolder: 0, shouldHaveStayed: 0, missed: 0, keptRight: 0 };
	for (const mail of mails) {
		if (mail.box === "Inbox") { if (mail.truth) out.missed++; else out.keptRight++; }
		else if (mail.truth === mail.box) out.correct++;
		else if (mail.truth) out.wrongFolder++;
		else out.shouldHaveStayed++;
	}
	return out;
}

const send = (message) => process.stdout.write(JSON.stringify(message) + "\n");
createInterface({ input: process.stdin }).on("line", (line) => {
	let message;
	try { message = JSON.parse(line); } catch { return; }
	const { id, method, params } = message;
	if (id === undefined) return; // notifications
	if (method === "initialize") {
		return send({ jsonrpc: "2.0", id, result: { protocolVersion: params?.protocolVersion ?? "2025-06-18", capabilities: { tools: {} },
			serverInfo: { name: "pippa-spike-mail", version: "1" } } });
	}
	if (method === "ping") return send({ jsonrpc: "2.0", id, result: {} });
	if (method === "tools/list") return send({ jsonrpc: "2.0", id, result: { tools: TOOLS } });
	if (method === "tools/call") {
		const name = params?.name, args = params?.arguments ?? {};
		try {
			const value = call(name, args);
			const body = JSON.stringify(value);
			log({ tool: name, dryRun: args.dry_run === true, refs: Array.isArray(args.refs) ? args.refs.length : undefined, chars: body.length, score: score() });
			return send({ jsonrpc: "2.0", id, result: { content: [{ type: "text", text: body }], structuredContent: value } });
		} catch (error) {
			log({ tool: name, error: String(error.message) });
			return send({ jsonrpc: "2.0", id, result: { content: [{ type: "text", text: String(error.message) }], isError: true } });
		}
	}
	send({ jsonrpc: "2.0", id, error: { code: -32601, message: "Method not found" } });
});
