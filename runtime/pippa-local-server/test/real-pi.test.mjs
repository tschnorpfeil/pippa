// The extension inside a real Pi (`pi -p`), fake HOME, fake oMLX (fake-omlx-server.mjs). Skipped unless a Pi CLI is named:
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
	// The files the app installs (app/Packaging/runtime-files.json), so a new import cannot be missed here.
	const shipped = JSON.parse(readFileSync(join(here, "../../../app/Packaging/runtime-files.json"), "utf8"))["pippa-local-server"];
	for (const f of shipped) copyFileSync(join(here, "..", f), join(extensionDir, f));

	const port = await new Promise((resolve) => {
		const s = createServer().listen(0, "127.0.0.1", () => { const { port } = s.address(); s.close(() => resolve(port)); });
	});
	// The runtime's python3, played by the fake server; oMLX's settings.json carries host, port and key.
	const binary = join(support, "mlx-runtime/0.0.1/bin/python3");
	mkdirSync(join(support, "mlx-runtime/0.0.1/bin"), { recursive: true });
	writeFileSync(binary, `#!${node}\nimport(${JSON.stringify(join(here, "fake-omlx-server.mjs"))});\n`);
	chmodSync(binary, 0o755);
	const key = "k".repeat(64);
	const keyFile = join(support, "local-server-key");
	writeFileSync(keyFile, key + "\n", { mode: 0o600 });
	const base = join(support, "omlx");
	const modelID = "ornith-1.5-9b-mlx-4bit";
	mkdirSync(join(base, "models", modelID), { recursive: true });
	writeFileSync(join(base, "settings.json"), JSON.stringify({ server: { host: "127.0.0.1", port }, auth: { api_key: key } }), { mode: 0o600 });
	const starts = join(root, "starts.jsonl");
	writeFileSync(join(support, "pippa-local-server.json"), JSON.stringify({
		schemaVersion: 2, provider: "pippa-local", port, binary, keyFile, modelID, logFile: join(support, "local-server.log"),
		arguments: ["-c", "from omlx.cli import main; main()", "serve", "--base-path", base, "--headless"],
		environment: { PATH: "/usr/bin:/bin", HF_HUB_OFFLINE: "1", OMLX_HEADLESS: "1", FAKE_OMLX_LOG: starts },
	}));
	writeFileSync(join(home, ".pi/agent/models.json"), JSON.stringify({ providers: { "pippa-local": {
		baseUrl: `http://127.0.0.1:${port}/v1`, api: "openai-completions", apiKey: `!/bin/cat '${keyFile}'`,
		models: [{ id: modelID, name: "Ornith 1.5 9B", contextWindow: 16384, maxTokens: 512 }],
	} } }));
	const env = { HOME: home, PATH: "/usr/bin:/bin", PI_OFFLINE: "1", PI_SKIP_VERSION_CHECK: "1", PI_TELEMETRY: "0" };
	const run = () => new Promise((resolve) => {
		const child = execFile(node, [cli, "-p", "--provider", "pippa-local", "--model", modelID, "--no-session", "say pong"],
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
		const lock = JSON.parse(readFileSync(join(support, "local-server.lock"), "utf8"));
		assert.equal(lock.owner, "pi");
	} finally {
		const lockFile = join(support, "local-server.lock");
		if (existsSync(lockFile)) {
			const lock = JSON.parse(readFileSync(lockFile, "utf8"));
			try { process.kill(lock.holder, "SIGTERM"); } catch {}
			for (let i = 0; i < 50 && existsSync(lockFile); i++) await new Promise((r) => setTimeout(r, 100));
		}
		rmSync(root, { recursive: true, force: true });
	}
});
