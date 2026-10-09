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

const { SETTINGS, repairQueries, writeSettings } = await import("../index.ts");
const here = fileURLToPath(new URL(".", import.meta.url));
const extension = join(here, "..", "index.ts");

test("search goes only to Exa, then DuckDuckGo; never OpenAI, even with a ChatGPT sign-in", () => {
	assert.deepEqual(SETTINGS.searchRouting.providers, ["exa", "duckduckgo"]);
	assert.deepEqual(SETTINGS.webSearch.allowedProviders, ["exa", "duckduckgo"]);
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

/** Starts the real Pi with index.ts and a probe extension that reports what Pi sees at session start. */
async function realPi() {
	const home = mkdtempSync(join(tmpdir(), "pippa-web-home-"));
	const probe = join(home, "probe.ts");
	const out = join(home, "probe.json");
	writeFileSync(probe, `import { writeFileSync } from "node:fs";
export default function (pi: any) {
	pi.on("session_start", () => writeFileSync(${JSON.stringify(out)}, JSON.stringify({
		tools: pi.getAllTools().map((tool: any) => tool.name),
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

test("the real Pi loads it: only search, read page and stored content; settings outside ~/.pi; environment put back", async () => {
	const { home, probe } = await realPi();
	const web = probe.tools.filter((name) => ["web_search", "fetch_content", "get_search_content", "source_check", "web_enable"].includes(name));
	assert.deepEqual(web.sort(), ["fetch_content", "get_search_content", "web_search"]);
	assert.equal(probe.xdg, null, "bash commands must not inherit Pippa's config folder");
	assert.ok(existsSync(join(home, "pippa-web", "pi", "web-search.json")));
	assert.ok(!existsSync(join(home, ".pi", "agent", "web-search.json")), "the person's Pi settings stay untouched");
});
