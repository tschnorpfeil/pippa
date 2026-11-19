#!/usr/bin/env node
// Pippa 1.0 spike runner (docs/pippa-1.0.md): one mail triage over 240 invented mails with Pippa's local model at a
// 16K window, with the synthetic Mail server exposed three ways. Measures instead of arguing.
//
//   node scripts/spikes/pippa-1.0/run.mjs <payload from bundle-pi-payload.sh --with-node> <variant> [minutes]
//
// Variants: direct   tools declared to the model, pages of 20 (rules 3 and 4 as today)
//           only     codemode.mode "only": the model reaches the tools only through scripts
//           both     tools declared and codemode active: does the model pick scripts by itself?
//           plan     like direct, plus mail_sort: a dry run without the model that mail_move applies by plan id
//           smoke    one sentence, no tools: checks the setup
// Online model instead: SPIKE_ONLINE_URL (OpenAI-compatible base URL), SPIKE_ONLINE_MODEL, SPIKE_ONLINE_KEY_FILE and
// SPIKE_WINDOW; the output folder gets the model's name.
// Needs the local oMLX server running (port and key file from Pippa's launch file). Uses a fake HOME under .build/, so
// ~/.pi is never read or written. Results: .build/spike-1.0/<variant>/{events.jsonl,calls.jsonl,summary.json}.
import { spawn } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { mkdir, rm, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repo = resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const payload = resolve(process.argv[2] ?? "");
const variant = process.argv[3] ?? "";
const minutes = Number(process.argv[4] ?? 25);
const node = join(payload, "bin/node");
const cli = join(payload, "release/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js");
if (!existsSync(cli) || !["direct", "only", "both", "plan", "smoke"].includes(variant)) {
	console.error("Usage: run.mjs <payload dir> direct|only|both|plan|smoke [minutes]");
	process.exit(2);
}

const online = process.env.SPIKE_ONLINE_URL;
const launch = online
	? { modelID: process.env.SPIKE_ONLINE_MODEL, keyFile: process.env.SPIKE_ONLINE_KEY_FILE }
	: JSON.parse(readFileSync(process.env.PIPPA_LAUNCH_FILE ?? join(homedir(), "Library/Application Support/Pippa/pippa-local-server.json"), "utf8"));
const WINDOW = Number(process.env.SPIKE_WINDOW ?? 16384), MAX_TOKENS = online ? 16384 : 4096;
const out = join(repo, ".build/spike-1.0", online ? `${launch.modelID.replace(/[^\w.-]/g, "_")}-${variant}` : variant);
const home = join(out, "home"), agent = join(home, ".pi/agent"), work = join(home, "work");
await rm(out, { recursive: true, force: true });
await Promise.all([agent, work].map((dir) => mkdir(dir, { recursive: true })));

const modelKey = `pippa-local/${launch.modelID}`;
await writeFile(join(agent, "models.json"), JSON.stringify({ providers: { "pippa-local": {
	api: "openai-completions", baseUrl: online ?? `http://127.0.0.1:${launch.port}/v1`, apiKey: `!/bin/cat '${launch.keyFile}'`,
	models: [online ? { id: launch.modelID, name: launch.modelID, contextWindow: WINDOW, maxTokens: MAX_TOKENS, reasoning: true }
		: { id: launch.modelID, name: "Ornith 1.5 9B", contextWindow: WINDOW, maxTokens: MAX_TOKENS, reasoning: true,
		compat: { thinkingFormat: "qwen-chat-template" },
		thinkingLevelMap: { off: "off", minimal: null, low: null, medium: "medium", high: null, xhigh: null, max: null } }],
} } }, null, 1));
// Compaction as PiModelTuning sets it: reserve min(maxTokens, window / 4), keep window * 3 / 8.
const settings = online ? { ...(variant === "only" ? { codemode: { mode: "only" } } : {}) } : {
	compaction: { modelOverrides: { [modelKey]: { reserveTokens: Math.min(MAX_TOKENS, WINDOW / 4), keepRecentTokens: WINDOW * 3 / 8 } } },
	modelThinkingLevels: { [modelKey]: "medium" },
	...(variant === "only" ? { codemode: { mode: "only" } } : {}),
};
await writeFile(join(agent, "settings.json"), JSON.stringify(settings, null, 1));
const calls = join(out, "calls.jsonl");
if (variant !== "smoke") {
	await writeFile(join(agent, "mcp.json"), JSON.stringify({ autoEnableCodemode: false, mcpServers: { pippa: {
		command: node, args: [join(repo, "scripts/spikes/pippa-1.0/mail-server.mjs")], exposure: "direct",
		env: { SPIKE_LOG: calls, SPIKE_PAGE: process.env.SPIKE_PAGE ?? "20", ...(variant === "plan" ? { SPIKE_SORT: "1" } : {}) },
		description: "Mail on this Mac: folders, inbox pages, moving mails into folders.",
	} } }, null, 1));
}

// Pippa's own system prompt, read from the Swift source so the spike cannot drift from the app.
const swift = readFileSync(join(repo, "app/Sources/PiRPC/PippaPiLaunch.swift"), "utf8");
const systemPrompt = /static let english = """\n([\s\S]*?)\n\s*"""/.exec(swift)[1].split("\n").map((line) => line.trim()).join("\n");
const prompt = variant === "smoke" ? "Say hello in one short sentence."
	: "Tidy my inbox: move the mails into my existing folders where they clearly belong. Personal and unclear mails stay in the inbox. Do a dry run first, check it, then move. Tell me the count per folder at the end.";
const tools = { smoke: [], direct: ["mcp__pippa__*"], plan: ["mcp__pippa__*"], only: ["codemode", "mcp__pippa__*"], both: ["codemode", "mcp__pippa__*"] }[variant];
const args = [cli, "--mode", "json", "--no-context-files", "--no-skills", "--no-session", "--provider", "pippa-local", "--model", launch.modelID,
	"--system-prompt", systemPrompt, ...(tools.length ? ["--tools", tools.join(",")] : ["--no-tools"]), prompt];

const started = Date.now();
const child = spawn(node, args, { cwd: work, env: { HOME: home, PATH: `${join(payload, "bin")}:/usr/bin:/bin:/usr/sbin:/sbin`,
	PI_TELEMETRY: "0", PI_OFFLINE: "1", PI_SKIP_VERSION_CHECK: "1" }, stdio: ["ignore", "pipe", "pipe"] });
const timer = setTimeout(() => { summary.timedOut = true; child.kill("SIGTERM"); }, minutes * 60_000);

const summary = { variant, window: WINDOW, timedOut: false, assistantTurns: 0, toolCalls: {}, toolErrors: 0, scriptsFailed: 0, nestedCalls: 0,
	compactions: 0, retries: 0, peakInputTokens: 0, outputTokens: 0, finalText: "" };
let buffer = "", events = "", stderr = "";
child.stderr.on("data", (chunk) => { stderr += chunk; });
child.stdout.on("data", (chunk) => {
	buffer += chunk;
	for (let at; (at = buffer.indexOf("\n")) >= 0; buffer = buffer.slice(at + 1)) {
		const line = buffer.slice(0, at);
		let event;
		try { event = JSON.parse(line); } catch { continue; }
		// Streaming deltas are most of the volume and add nothing to the measurement.
		if (event.type !== "message_update") events += line + "\n";
		if (event.type === "message_end" && event.message?.role === "assistant") {
			summary.assistantTurns++;
			const usage = event.message.usage ?? {};
			summary.peakInputTokens = Math.max(summary.peakInputTokens, (usage.input ?? 0) + (usage.cacheRead ?? 0));
			summary.outputTokens += usage.output ?? 0;
			const text = (event.message.content ?? []).filter((part) => part.type === "text").map((part) => part.text).join("\n").trim();
			if (text) summary.finalText = text;
			if (event.message.stopReason === "error") summary.modelError = event.message.errorMessage;
		}
		if (event.type === "tool_execution_start") {
			if (event.parentToolCallId) summary.nestedCalls++;
			else summary.toolCalls[event.toolName] = (summary.toolCalls[event.toolName] ?? 0) + 1;
		}
		if (event.type === "tool_execution_end" && event.isError && !event.parentToolCallId) {
			summary.toolErrors++;
			if (event.toolName === "codemode") summary.scriptsFailed++;
		}
		if (event.type === "compaction_end") summary.compactions++;
		if (event.type === "auto_retry_start") summary.retries++;
	}
});
child.on("close", async (code) => {
	clearTimeout(timer);
	summary.exitCode = code;
	summary.seconds = Math.round((Date.now() - started) / 1000);
	if (existsSync(calls)) {
		const lines = readFileSync(calls, "utf8").trim().split("\n").filter(Boolean).map((line) => JSON.parse(line));
		summary.serverCalls = lines.length;
		summary.dryRuns = lines.filter((line) => line.tool === "mail_move" && line.dryRun).length;
		summary.realMoves = lines.filter((line) => line.tool === "mail_move" && !line.dryRun && !line.error).length;
		summary.serverErrors = lines.filter((line) => line.error).length;
		summary.placement = lines.filter((line) => line.score).at(-1)?.score ?? null;
	}
	if (stderr.trim()) summary.stderrTail = stderr.trim().slice(-600);
	await writeFile(join(out, "events.jsonl"), events);
	await writeFile(join(out, "summary.json"), JSON.stringify(summary, null, 1));
	console.log(JSON.stringify(summary, null, 1));
});
