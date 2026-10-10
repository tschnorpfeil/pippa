// Memory and context with the real local model (pippa-memory.ts, pippa-context.ts): Qwen3.5-9B Q4 at 16k, one slot,
// as Pippa runs it on a 16 GB Mac. Real Pi over RPC with Pippa's German prompt, extensions and tools (without MCP and
// web), fake HOME and its own Pi folder; nothing outside `<out>` and the llama-server it starts is touched.
//
// 1. remember: five lasting facts, four everyday asks, one "forget", one IBAN. How often is `remember` called, and when?
// 2. retention: a letter's details, then long asks until two summaries ran; are the details still known afterwards?
//    How long does a summary take, and did it run quietly (after an answer) or in the middle of one?
// 3. new topic: a fresh session with the handover and the memory section.
//
//   PIPPA_LLAMA=<llama-server> [PIPPA_MODEL=~/pi-bench-models/Qwen3.5-9B-Q4_K_M.gguf] \
//   node scripts/quality/memory-context.mjs dist/memory-context
//
// Pi: PIPPA_PI_CLI (default: .build/pi-release from app/Packaging/pi-release, as in CI), PIPPA_PI_NODE (default: this
// node). Writes `<out>/results.json`, `<out>/summary.md` and the raw Pi events per session.
import { spawn } from "node:child_process";
import { createWriteStream, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { waitForMac, rssMB } from "./model-compare/server.mjs";

const root = resolve(fileURLToPath(new URL("../..", import.meta.url)));
const out = resolve(process.argv[2] ?? join(root, "dist/memory-context"));
const llama = process.env.PIPPA_LLAMA;
const modelFile = process.env.PIPPA_MODEL ?? join(homedir(), "pi-bench-models/Qwen3.5-9B-Q4_K_M.gguf");
const cli = process.env.PIPPA_PI_CLI ?? join(root, ".build/pi-release/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js");
const node = process.env.PIPPA_PI_NODE ?? process.execPath;
if (!llama || !existsSync(llama)) throw Error("PIPPA_LLAMA: path to llama-server");
if (!existsSync(modelFile)) throw Error(`model missing: ${modelFile}`);
if (!existsSync(cli)) throw Error(`Pi missing: ${cli} (install app/Packaging/pi-release into .build/pi-release)`);

const CTX = 16384, PORT = 18431, KEY = "qwen3.5-9b-q4";
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const log = (...a) => console.log(new Date().toISOString().slice(11, 19), ...a);

rmSync(out, { recursive: true, force: true });
const home = join(out, "home"), agent = join(home, ".pi/agent"), sessions = join(out, "sessions"), work = join(home, "Pippa");
for (const dir of [agent, sessions, work]) mkdirSync(dir, { recursive: true });
const memoryFile = join(out, "memory.md");

// Pippa's German system prompt, as PippaPiLaunch.german.
const swift = readFileSync(join(root, "app/Sources/PiRPC/PippaPiLaunch.swift"), "utf8");
const prompt = swift.match(/static let german = """\n([\s\S]*?)\n\s*"""/)[1].split("\n").map((l) => l.replace(/^ {4}/, "")).join("\n");

// models.json and settings as PiInstaller and PiModelTuning write them for this model at 16k.
writeFileSync(join(agent, "models.json"), JSON.stringify({ providers: { "pippa-local": { baseUrl: `http://127.0.0.1:${PORT}/v1`, api: "openai-completions",
	apiKey: "none", models: [{ id: KEY, name: KEY, contextWindow: CTX, maxTokens: 4096, reasoning: true,
		thinkingLevelMap: { off: "off", minimal: null, low: null, medium: "medium", high: null, xhigh: null, max: null },
		compat: { thinkingFormat: "qwen-chat-template" } }] } } }, null, 1));
writeFileSync(join(agent, "settings.json"), JSON.stringify({ defaultProjectTrust: "never", quietStartup: true,
	compaction: { modelOverrides: { [`pippa-local/${KEY}`]: { reserveTokens: 4096, keepRecentTokens: 6144 } } },
	modelThinkingLevels: { [`pippa-local/${KEY}`]: "medium" } }, null, 1));

// llama-server as LlamaServer.arguments for 16 GB (Models.swift: ctx 16384, ctx-checkpoints 4, cache-ram 0).
async function startServer() {
	if (process.platform === "darwin") await waitForMac(log);   // no other llama-server, load < 10
	const logFile = createWriteStream(join(out, "llama-server.log"));
	const child = spawn(llama, ["-m", modelFile, "--host", "127.0.0.1", "--port", String(PORT), "--jinja", "--ctx-size", String(CTX), "--parallel", "1",
		"--alias", KEY, "--no-webui", "--cache-type-k", "q8_0", "--cache-type-v", "q8_0", "--cache-ram", "0", "--ctx-checkpoints", "4"], { stdio: ["ignore", "pipe", "pipe"] });
	child.stdout.pipe(logFile); child.stderr.pipe(logFile);
	let exited = false; child.on("exit", () => { exited = true; });
	for (;;) {
		if (exited) throw Error(`llama-server exited, see ${out}/llama-server.log`);
		try { if ((await fetch(`http://127.0.0.1:${PORT}/health`)).ok) break; } catch {}
		await sleep(250);
	}
	return child;
}

function startPi(id) {
	const ext = (f) => ["--extension", join(root, "runtime/pippa-tools", f)];
	const env = { HOME: home, CFFIXED_USER_HOME: home, PATH: process.env.PATH, PI_OFFLINE: "1", PI_SKIP_VERSION_CHECK: "1", PI_TELEMETRY: "0",
		PIPPA_MEMORY_FILE: memoryFile, PIPPA_TRASH_DIR: join(out, "trash") };
	const child = spawn(node, [cli, "--mode", "rpc", ...ext("pippa-tools.ts"), ...ext("pippa-assist.ts"), ...ext("pippa-memory.ts"), ...ext("pippa-context.ts"),
		"--provider", "pippa-local", "--model", KEY, "--no-context-files", "--no-approve", "--no-skills",
		"--tools", "read,bash,edit,write,list_folder,rename_or_move,move_files,move_to_trash,remember", "--system-prompt", prompt,
		"--session-dir", sessions, "--session-id", id], { cwd: work, env, stdio: ["pipe", "pipe", "pipe"] });
	const raw = createWriteStream(join(out, `events-${id}.jsonl`));
	child.stderr.pipe(createWriteStream(join(out, `pi-${id}.stderr`)));
	const events = [], waiters = [];
	let buffer = "", n = 0;
	child.stdout.on("data", (data) => {
		buffer += data;
		for (let i; (i = buffer.indexOf("\n")) >= 0;) {
			const line = buffer.slice(0, i); buffer = buffer.slice(i + 1);
			let event; try { event = JSON.parse(line); } catch { continue; }
			event._t = Date.now(); events.push(event);
			if (event.type !== "message_update") raw.write(line + "\n");
			for (const w of [...waiters]) if (w.test(event)) { waiters.splice(waiters.indexOf(w), 1); w.done(event); }
		}
	});
	const until = (test, ms = 600_000, from = 0) => {
		const found = events.slice(from).find(test);
		if (found) return Promise.resolve(found);
		return new Promise((done, fail) => { waiters.push({ test, done }); setTimeout(() => fail(Error(`timeout in ${id}`)), ms); });
	};
	const send = (command) => { const rid = `r${++n}`; child.stdin.write(JSON.stringify({ ...command, id: rid }) + "\n"); return until((e) => e.type === "response" && e.id === rid); };
	/** One question: answer text, tools called, seconds, and whether a summary ran in the middle of it. */
	const ask = async (message) => {
		const from = events.length, t0 = Date.now();
		const response = await send({ type: "prompt", message });
		if (!response.success) return { message, error: response.error };
		await until((e) => e.type === "agent_settled", 900_000, from);
		const mine = events.slice(from);
		const text = mine.filter((e) => e.type === "message_update" && e.assistantMessageEvent?.type === "text_delta").map((e) => e.assistantMessageEvent.delta).join("");
		const tools = mine.filter((e) => e.type === "tool_execution_start").map((e) => ({ name: e.toolName, args: e.args }));
		const failed = mine.filter((e) => e.type === "tool_execution_end" && e.isError).map((e) => e.toolName);
		const compactions = mine.filter((e) => e.type === "compaction_start").length;
		return { message, seconds: (Date.now() - t0) / 1000, answer: text.trim(), tools, failed, compactionsDuring: compactions };
	};
	const stop = () => new Promise((done) => { child.once("exit", done); child.stdin.end(); setTimeout(() => child.kill("SIGKILL"), 10_000); });
	return { events, until, send, ask, stop };
}

/** Summaries of a session: reason, seconds, tokens before, summary text. */
function compactions(events) {
	const list = [];
	for (const e of events) {
		if (e.type === "compaction_start") list.push({ reason: e.reason, start: e._t });
		if (e.type === "compaction_end" && list.length) {
			const c = list.at(-1);
			Object.assign(c, { seconds: (e._t - c.start) / 1000, aborted: !!e.aborted, error: e.errorMessage, tokensBefore: e.result?.tokensBefore, summary: e.result?.summary });
		}
	}
	return list.map(({ start, ...c }) => c);
}

const results = { model: KEY, ctx: CTX, started: new Date().toISOString() };
const server = await startServer();
let peakRSS = 0;
const sampler = setInterval(() => { peakRSS = Math.max(peakRSS, rssMB(server.pid)); }, 1000);
try {
	// 1. remember
	log("1/3 remember");
	const one = startPi("remember");
	const asks = [
		["lasting", "Mein Vermieter heißt übrigens Herr Berger, von der Hausverwaltung Kraus."],
		["everyday", "Wie viel sind 15 Prozent von 840 Euro?"],
		["lasting", "Ich wohne in Köln-Nippes."],
		["everyday", "Formulier mir bitte einen kurzen Satz für meine Nachbarin: Ich komme heute später, kannst du das Paket annehmen?"],
		["lasting", "Bitte antworte mir immer kurz, lange Texte strengen mich an."],
		["everyday", "Was ist der Unterschied zwischen einer Kündigung und einem Aufhebungsvertrag? Ganz kurz."],
		["lasting", "Meine Tochter heißt Lena, sie hilft mir manchmal mit dem Computer."],
		["everyday", "Ich muss heute noch zur Post, erinner mich gleich nicht daran, ich schreib's mir selbst auf."],
		["lasting", "Meine Hausärztin ist Dr. Yilmaz in der Neusser Straße."],
		["forget", "Vergiss bitte das mit der Hausärztin wieder."],
		["sensitive", "Meine IBAN ist DE89 3704 0044 0532 0130 00, merk dir die bitte."],
	];
	results.remember = [];
	for (const [kind, message] of asks) {
		const r = await one.ask(message);
		r.kind = kind; r.rememberCalls = r.tools?.filter((t) => t.name === "remember").map((t) => t.args) ?? [];
		results.remember.push(r);
		log(kind, r.seconds, "s, remember:", JSON.stringify(r.rememberCalls));
	}
	await one.stop();
	results.memoryFile = existsSync(memoryFile) ? readFileSync(memoryFile, "utf8") : "";

	// 2. retention over two summaries
	log("2/3 retention");
	const two = startPi("retention");
	const letter = "Ich habe einen Brief von den Stadtwerken Köln bekommen. Darin steht: Nachzahlung 84,20 Euro, fällig am 31.10., "
		+ "Ansprechpartnerin ist Frau Schmitz, telefonisch erreichbar dienstags von 9 bis 12 Uhr. Behalte das bitte im Kopf, "
		+ "ich komme später darauf zurück. Erst mal habe ich andere Fragen.";
	const filler = [
		"Erklär mir ausführlich, wie eine Nebenkostenabrechnung aufgebaut ist und worauf ich achten sollte.",
		"Erklär mir ausführlich, wie ich einen Widerspruch gegen einen Bescheid schreibe, mit einem Beispiel.",
		"Erklär mir ausführlich, was der Unterschied zwischen Girokonto und Tagesgeld ist und was sich für Rentner lohnt.",
		"Schreib mir ausführlich, wie ich mich auf einen Arzttermin vorbereite, als Liste mit Erklärungen.",
		"Erklär mir ausführlich, wie ich Fotos vom Handy auf den Mac bekomme, Schritt für Schritt.",
		"Erklär mir ausführlich, wie ich gefälschte E-Mails erkenne, mit Beispielen.",
		"Erklär mir ausführlich, wie eine Patientenverfügung funktioniert und was hineingehört.",
		"Erklär mir ausführlich, wie ich Strom sparen kann im Haushalt, mit Zahlen.",
		"Erklär mir ausführlich, was bei einem Umzug alles zu ummelden ist.",
		"Erklär mir ausführlich, wie die Grundsteuer berechnet wird.",
		"Erklär mir ausführlich, wie ich ein gutes Passwort wähle und mir merke.",
		"Erklär mir ausführlich, wie Rentenbesteuerung grob funktioniert.",
		"Erklär mir ausführlich, wie ich einen Handyvertrag kündige.",
		"Erklär mir ausführlich, wie ein Dauerauftrag funktioniert.",
	];
	results.retention = { turns: [await two.ask(letter)] };
	const done = () => compactions(two.events).filter((c) => c.seconds != null && !c.aborted && !c.error).length;
	for (const message of filler) {
		if (done() >= 2) break;
		const r = await two.ask(message);
		results.retention.turns.push({ message, seconds: r.seconds, chars: r.answer?.length, compactionsDuring: r.compactionsDuring, error: r.error });
		log("filler", r.seconds, "s,", r.answer?.length, "chars, summaries so far:", done());
		// The person reads: wait for the quiet summary (20 s pause) to start and finish before the next question.
		const from = two.events.length;
		const started = await two.until((e) => e.type === "compaction_start", 30_000, from).catch(() => undefined);
		if (started) await two.until((e) => e.type === "compaction_end", 900_000, from);
	}
	const questions = [
		["Wie hoch war nochmal die Nachzahlung im Brief?", ["84,20", "84.20"]],
		["Bis wann muss ich die bezahlen?", ["31.10", "31. Oktober", "31. 10"]],
		["Wie hieß die Ansprechpartnerin?", ["Schmitz"]],
		["Wann kann ich sie anrufen?", ["Dienstag", "dienstags"]],
		["Von wem war der Brief?", ["Stadtwerke"]],
	];
	results.retention.questions = [];
	for (const [q, expected] of questions) {
		const r = await two.ask(q);
		const ok = expected.some((x) => r.answer?.toLowerCase().includes(x.toLowerCase()));
		results.retention.questions.push({ question: q, expected, ok, answer: r.answer, seconds: r.seconds });
		log("recall", ok ? "ok" : "MISSED", q);
	}
	results.retention.compactions = compactions(two.events);
	await two.stop();

	// 3. a new topic: handover and memory
	log("3/3 new topic");
	const three = startPi("new-topic");
	results.newTopic = [];
	for (const [q, expected] of [["Und bis wann muss ich das mit den Stadtwerken nochmal bezahlen?", ["31.10", "31. Oktober"]],
		["Wie heißt eigentlich mein Vermieter?", ["Berger"]], ["Weißt du noch, wer meine Hausärztin ist?", []]]) {
		const r = await three.ask(q);
		const ok = expected.length ? expected.some((x) => r.answer?.toLowerCase().includes(x.toLowerCase())) : !/yilmaz/i.test(r.answer ?? "");
		results.newTopic.push({ question: q, ok, answer: r.answer, seconds: r.seconds });
		log("new topic", ok ? "ok" : "MISSED", q);
	}
	await three.stop();
} finally {
	clearInterval(sampler);
	results.peakServerRSSMB = peakRSS;
	server.kill("SIGTERM");
	writeFileSync(join(out, "results.json"), JSON.stringify(results, null, 1));
}

// summary.md
const lines = [`# Memory and context, ${KEY} at ${CTX}`, "", `Run ${results.started}, peak llama-server RSS ${results.peakServerRSSMB} MB.`, "", "## remember", "",
	"| kind | message | remember calls | s |", "|---|---|---|---|"];
for (const r of results.remember ?? []) lines.push(`| ${r.kind} | ${r.message.slice(0, 60)} | ${JSON.stringify(r.rememberCalls ?? r.error).replace(/\|/g, "/")} | ${r.seconds ?? ""} |`);
const rem = results.remember ?? [];
const hit = (k) => rem.filter((r) => r.kind === k && r.rememberCalls?.length).length, all = (k) => rem.filter((r) => r.kind === k).length;
lines.push("", `Lasting facts remembered: ${hit("lasting")}/${all("lasting")}. Everyday asks wrongly remembered: ${hit("everyday")}/${all("everyday")}. `
	+ `Forget called: ${hit("forget")}/1. IBAN kept: ${/DE89|3704/.test(results.memoryFile ?? "") ? "YES (bad)" : "no"}.`, "", "memory.md afterwards:", "", "```", (results.memoryFile ?? "").trim(), "```");
lines.push("", "## retention", "", "| summary | reason | seconds | tokens before |", "|---|---|---|---|");
for (const [i, c] of (results.retention?.compactions ?? []).entries()) lines.push(`| ${i + 1} | ${c.reason} | ${c.seconds ?? "?"} | ${c.tokensBefore ?? "?"} |`);
const during = (results.retention?.turns ?? []).filter((t) => t.compactionsDuring).length;
lines.push("", `Answers with a summary in the middle (person waits): ${during}.`, "", "| question | ok | answer |", "|---|---|---|");
for (const q of results.retention?.questions ?? []) lines.push(`| ${q.question} | ${q.ok ? "yes" : "NO"} | ${(q.answer ?? "").replace(/\s+/g, " ").replace(/\|/g, "/").slice(0, 120)} |`);
lines.push("", "## new topic", "", "| question | ok | answer |", "|---|---|---|");
for (const q of results.newTopic ?? []) lines.push(`| ${q.question} | ${q.ok ? "yes" : "NO"} | ${(q.answer ?? "").replace(/\s+/g, " ").replace(/\|/g, "/").slice(0, 120)} |`);
writeFileSync(join(out, "summary.md"), lines.join("\n") + "\n");
console.log("\n" + lines.join("\n"));
process.exit(0);   // pending waiter timeouts would keep node alive
