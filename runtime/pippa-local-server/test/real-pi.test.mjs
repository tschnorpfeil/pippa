// The extension inside a real Pi (`pi -p`), fake HOME, fake llama-server. Skipped unless a Pi CLI is named:
//
//   PIPPA_PI_CLI=<release>/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js \
//   PIPPA_PI_NODE=<node 22> node --test runtime/pippa-local-server/test/real-pi.test.mjs
//
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { chmodSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:net";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

// Or Pippa's payload (bundle-pi-payload.sh --with-node), as scripts/bump-pi.sh passes it: PIPPA_PI_PAYLOAD=<dir>.
const payload = process.env.PIPPA_PI_PAYLOAD;
const cli = process.env.PIPPA_PI_CLI
	|| (payload ? join(payload, "release/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js") : undefined);
const node = process.env.PIPPA_PI_NODE || (payload && existsSync(join(payload, "bin/node")) ? join(payload, "bin/node") : process.execPath);
const here = fileURLToPath(new URL(".", import.meta.url));

test("real Pi: plain `pi -p` with pippa-local starts the server, answers, and leaves one supervisor behind", { skip: !cli && "PIPPA_PI_CLI not set" }, async () => {
	mkdirSync(join(here, "../../../.build"), { recursive: true });
	const root = mkdtempSync(join(here, "../../../.build/pippa-local-server-realpi-"));
	const home = join(root, "home");
	const support = join(home, "Library/Application Support/Pippa");
	const extensionDir = join(home, ".pi/agent/extensions/pippa-local-server");
	mkdirSync(support, { recursive: true });
	mkdirSync(extensionDir, { recursive: true });
	for (const f of ["index.ts", "common.mjs", "ensure.mjs", "supervisor.mjs"]) copyFileSync(join(here, "..", f), join(extensionDir, f));

	const port = await new Promise((resolve) => {
		const s = createServer().listen(0, "127.0.0.1", () => { const { port } = s.address(); s.close(() => resolve(port)); });
	});
	const binary = join(root, "Pippa.app/Contents/Helpers/llama-server");
	mkdirSync(join(root, "Pippa.app/Contents/Helpers"), { recursive: true });
	writeFileSync(binary, `#!${node}\nimport(${JSON.stringify(join(here, "fake-llama-server.mjs"))});\n`);
	chmodSync(binary, 0o755);
	const keyFile = join(support, "llama-key");
	writeFileSync(keyFile, "k".repeat(64) + "\n", { mode: 0o600 });
	writeFileSync(join(support, "pippa-local-server.json"), JSON.stringify({
		schemaVersion: 1, provider: "pippa-local", port, binary, keyFile, idleSeconds: 600, modelID: "k2-horizon-7b",
		arguments: ["--host", "127.0.0.1", "--port", String(port), "--jinja", "--alias", "k2-horizon-7b"],
	}));
	writeFileSync(join(home, ".pi/agent/models.json"), JSON.stringify({ providers: { "pippa-local": {
		baseUrl: `http://127.0.0.1:${port}/v1`, api: "openai-completions", apiKey: `!/bin/cat '${keyFile}'`,
		models: [{ id: "k2-horizon-7b", name: "K2 Horizon 7B", contextWindow: 16384, maxTokens: 512 }],
	} } }));
	const starts = join(root, "starts.jsonl");
	const env = { HOME: home, PATH: "/usr/bin:/bin", PI_OFFLINE: "1", PI_SKIP_VERSION_CHECK: "1", PI_TELEMETRY: "0", FAKE_LLAMA_LOG: starts };
	const run = () => new Promise((resolve) => {
		const child = execFile(node, [cli, "-p", "--provider", "pippa-local", "--model", "k2-horizon-7b", "--no-session", "say pong"],
			{ env, cwd: root, timeout: 60_000 }, (error, stdout, stderr) => resolve({ error, stdout, stderr }));
		child.stdin.end(); // `pi -p` reads piped stdin until EOF
	});
	try {
		const first = await run();
		assert.equal(first.error, null, `stdout: ${first.stdout}\nstderr: ${first.stderr}`);
		assert.match(first.stdout, /pong/);
		assert.match(first.stderr, /Starting the local model/);
		const second = await run();   // server already up: no new start
		assert.match(second.stdout, /pong/);
		const lines = readFileSync(starts, "utf8").trim().split("\n");
		assert.equal(lines.length, 1);
		const lock = JSON.parse(readFileSync(join(support, "llama-server-pi.lock"), "utf8"));
		assert.equal(lock.owner, "pi");
	} finally {
		const lockFile = join(support, "llama-server-pi.lock");
		if (existsSync(lockFile)) {
			const lock = JSON.parse(readFileSync(lockFile, "utf8"));
			try { process.kill(lock.holder, "SIGTERM"); } catch {}
			for (let i = 0; i < 50 && existsSync(lockFile); i++) await new Promise((r) => setTimeout(r, 100));
		}
		rmSync(root, { recursive: true, force: true });
	}
});
