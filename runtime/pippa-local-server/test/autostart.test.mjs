// Pippa's terminal extension without a model and without the real ~/.pi: a fake HOME under .build/, a fake
// llama-server (fake-llama-server.mjs, a tiny node HTTP server), a stand-in `pi` that collects the handlers.
//
//   node --experimental-strip-types --test runtime/pippa-local-server/test/autostart.test.mjs
import assert from "node:assert/strict";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:net";
import { createServer as createHTTPServer } from "node:http";
import { join } from "node:path";
import { after, beforeEach, test } from "node:test";
import { fileURLToPath } from "node:url";

const here = fileURLToPath(new URL(".", import.meta.url));
mkdirSync(join(here, "../../../.build"), { recursive: true });
const root = mkdtempSync(join(here, "../../../.build/pippa-local-server-test-"));

// Fake HOME: the extension finds Pippa's support folder from it, never the real one.
const home = join(root, "home");
process.env.HOME = home;
delete process.env.PIPPA_SUPPORT_DIR;
delete process.env.LLAMA_API_KEY;
process.env.PIPPA_LLAMA_POLL_MS = "150";
const support = join(home, "Library/Application Support/Pippa");
mkdirSync(support, { recursive: true });

const { default: extension } = await import("../index.ts");
const common = await import("../common.mjs");
const { ensureServer } = await import("../ensure.mjs");

// Executable fake llama-server with this test's node in the shebang.
const fakeBinary = join(root, "Pippa.app/Contents/Helpers/llama-server");
mkdirSync(join(root, "Pippa.app/Contents/Helpers"), { recursive: true });
writeFileSync(fakeBinary, `#!${process.execPath}\nimport(${JSON.stringify(join(here, "fake-llama-server.mjs"))});\n`);
chmodSync(fakeBinary, 0o755);
const starts = join(root, "starts.jsonl");
process.env.FAKE_LLAMA_LOG = starts;
const modelFile = join(root, "model.gguf");
writeFileSync(modelFile, "");
const keyFile = join(support, "llama-key");
writeFileSync(keyFile, "k".repeat(64) + "\n", { mode: 0o600 });

const freePort = () =>
	new Promise((resolve) => {
		const s = createServer().listen(0, "127.0.0.1", () => {
			const { port } = s.address();
			s.close(() => resolve(port));
		});
	});

function writeConfig(port, extra = {}) {
	const config = {
		schemaVersion: 1,
		provider: "pippa-local",
		port,
		binary: fakeBinary,
		app: join(root, "Pippa.app"),
		modelID: "k2-horizon-7b",
		keyFile,
		idleSeconds: 600,
		logFile: join(support, "llama-server-pi.log"),
		arguments: ["-m", modelFile, "--host", "127.0.0.1", "--port", String(port), "--jinja", "--alias", "k2-horizon-7b",
			"--slot-save-path", join(support, "llama-slots"), "--swa-full"],
		...extra,
	};
	writeFileSync(join(support, "pippa-local-server.json"), JSON.stringify(config));
	return config;
}

const lockFile = join(support, "llama-server-pi.lock");
const startLines = () => (existsSync(starts) ? readFileSync(starts, "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l)) : []);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** A stand-in for Pi: collects handlers, records UI calls. */
function loadPi({ hasUI = true } = {}) {
	const handlers = {};
	const ui = { statuses: [], working: [], notes: [] };
	extension({ on: (name, handler) => { handlers[name] = handler; } });
	const ctx = (model) => ({
		model,
		hasUI,
		ui: {
			notify: (message, type) => ui.notes.push({ message, type }),
			setStatus: (key, text) => ui.statuses.push([key, text]),
			setWorkingMessage: (text) => ui.working.push(text),
		},
	});
	return { handlers, ui, ctx };
}

async function stopAll() {
	const lock = common.readLock(lockFile);
	for (const pid of [lock?.holder, lock?.pid]) {
		if (common.isAlive(pid)) try { process.kill(pid, "SIGTERM"); } catch {}
	}
	for (let i = 0; i < 50 && existsSync(lockFile); i++) await sleep(100);
	rmSync(lockFile, { force: true });
	rmSync(starts, { force: true });
}

beforeEach(stopAll);

after(async () => {
	await stopAll();
	rmSync(root, { recursive: true, force: true });
});

test("config: only loopback, port must match, no key on the command line, clear sentence when missing", () => {
	const file = join(root, "c.json");
	const base = { schemaVersion: 1, provider: "pippa-local", port: 1234, binary: "/x/llama-server", arguments: ["--host", "127.0.0.1", "--port", "1234"] };
	const load = (raw) => { writeFileSync(file, JSON.stringify(raw)); return common.loadConfig(file); };
	assert.equal(load(base).idleSeconds, 600);
	assert.throws(() => load({ ...base, arguments: ["--host", "0.0.0.0", "--port", "1234"] }), /127\.0\.0\.1/);
	assert.throws(() => load({ ...base, arguments: ["--host", "127.0.0.1", "--port", "9"] }), /--port/);
	assert.throws(() => load({ ...base, arguments: [...base.arguments, "--api-key", "x"] }), /keyFile/);
	assert.throws(() => load({ ...base, binary: "llama-server" }), /absolute/);
	assert.throws(() => common.loadConfig(join(root, "nope.json")), /Open Pippa once/);
});

test("other providers: nothing happens, nothing starts", async () => {
	const port = await freePort();
	writeConfig(port);
	const { handlers, ui, ctx } = loadPi();
	assert.equal(await handlers.before_provider_request({ payload: {} }, ctx({ provider: "anthropic", id: "claude" })), undefined);
	assert.equal(await handlers.before_provider_request({ payload: {} }, ctx(undefined)), undefined);
	assert.equal(startLines().length, 0);
	assert.equal(existsSync(lockFile), false);
	assert.deepEqual(ui.notes, []);
});

test("pippa-local, no server: starts it with Pippa's exact arguments, shows a status, then the request goes on", async () => {
	const port = await freePort();
	const config = writeConfig(port);
	const { handlers, ui, ctx } = loadPi();
	const model = { provider: "pippa-local", id: "k2-horizon-7b", baseUrl: `http://127.0.0.1:${port}/v1` };
	await handlers.before_provider_request({ payload: { model: "k2-horizon-7b" } }, ctx(model));
	assert.equal(await common.health(port, "k".repeat(64)), 200);
	const [start, ...more] = startLines();
	assert.equal(more.length, 0);
	assert.deepEqual(start.args, config.arguments);
	assert.equal(start.key, "k".repeat(64), "key only via LLAMA_API_KEY");
	assert.ok(existsSync(join(support, "llama-slots")), "slot folder created");
	const lock = common.readLock(lockFile);
	assert.equal(lock.owner, "pi");
	assert.equal(lock.pid, start.pid);
	assert.ok(common.isAlive(lock.holder));
	assert.deepEqual(ui.statuses.at(0), ["pippa-local-server", "Starting the local model…"]);
	assert.deepEqual(ui.statuses.at(-1), ["pippa-local-server", undefined]);
	// Already running: no second start, no status.
	const again = loadPi();
	await again.handlers.before_provider_request({ payload: {} }, again.ctx(model));
	await again.handlers.session_before_compact({}, again.ctx(model));
	assert.equal(startLines().length, 1);
	assert.deepEqual(again.ui.statuses, []);
	await stopAll();
});

test("two terminal Pis at once: exactly one server", async () => {
	const port = await freePort();
	const config = writeConfig(port);
	const options = { configFile: join(support, "pippa-local-server.json"), lockFile };
	const results = await Promise.all([ensureServer(config, options), ensureServer(config, options), ensureServer(config, options)]);
	assert.equal(startLines().length, 1);
	assert.ok(results.includes("started"));
	await stopAll();
});

test("idle: the terminal's server unloads after idleSeconds without use; a busy slot or a touched lock keeps it", async () => {
	const port = await freePort();
	const config = writeConfig(port, { idleSeconds: 1 });
	const busy = join(root, "busy");
	process.env.FAKE_LLAMA_BUSY = busy;
	try {
		await ensureServer(config, { configFile: join(support, "pippa-local-server.json"), lockFile });
		writeFileSync(busy, "");
		await sleep(1600);
		assert.equal(await common.health(port, "k".repeat(64)), 200, "busy slot keeps it");
		rmSync(busy);
		for (let i = 0; i < 4; i++) { await sleep(400); common.touchLock(lockFile); }
		assert.equal(await common.health(port, "k".repeat(64)), 200, "touched lock keeps it");
		let gone = false;
		for (let i = 0; i < 40 && !gone; i++) { await sleep(100); gone = !existsSync(lockFile); }
		assert.ok(gone, "lock removed after idle");
		await sleep(300);
		assert.equal(await common.health(port, "k".repeat(64)), 0, "server stopped");
	} finally {
		delete process.env.FAKE_LLAMA_BUSY;
		await stopAll();
	}
});

test("the app holds the lock and is still loading: wait, never start a second server", async () => {
	const port = await freePort();
	const config = writeConfig(port);
	// "The app": a live holder (this test process), a server that answers 503 for a while, then 200.
	common.createLock(lockFile, { owner: "app", holder: process.pid, pid: process.pid, port });
	const readyAt = Date.now() + 800;
	const server = createHTTPServer((req, res) => res.writeHead(Date.now() > readyAt ? 200 : 503).end()).listen(port, "127.0.0.1");
	let started = false;
	try {
		const { handlers, ui, ctx } = loadPi();
		await handlers.before_provider_request({ payload: {} }, ctx({ provider: "pippa-local", baseUrl: `http://127.0.0.1:${port}/v1` }));
		const result = await ensureServer(config, { configFile: join(support, "pippa-local-server.json"), lockFile, spawnSupervisor: () => { started = true; } });
		assert.equal(result, "running");
		assert.equal(started, false);
		assert.equal(startLines().length, 0);
		assert.equal(common.readLock(lockFile).owner, "app");
		assert.ok(ui.statuses.some(([, text]) => text === "Starting the local model…"));
	} finally {
		server.close();
		rmSync(lockFile, { force: true });
	}
});

test("stale lock (dead process) is cleared and the server starts", async () => {
	const port = await freePort();
	writeConfig(port);
	common.createLock(lockFile, { owner: "pi", holder: 999999, pid: 999998, port });
	const { handlers, ctx } = loadPi();
	await handlers.before_provider_request({ payload: {} }, ctx({ provider: "pippa-local" }));
	assert.equal(startLines().length, 1);
	assert.ok(common.isAlive(common.readLock(lockFile).holder));
	await stopAll();
});

test("clear sentences: Pippa.app missing, model missing, setup missing, port taken by another program", async () => {
	const port = await freePort();
	const { handlers, ui, ctx } = loadPi();
	const model = { provider: "pippa-local" };
	writeConfig(port, { binary: join(root, "Gone.app/Contents/Helpers/llama-server"), app: join(root, "Gone.app") });
	await assert.rejects(handlers.before_provider_request({ payload: {} }, ctx(model)), /Gone\.app is missing or was moved/);
	writeConfig(port, { arguments: ["-m", join(root, "none.gguf"), "--host", "127.0.0.1", "--port", String(port)] });
	await assert.rejects(handlers.before_provider_request({ payload: {} }, ctx(model)), /model file .*none\.gguf is missing/);
	rmSync(join(support, "pippa-local-server.json"));
	await assert.rejects(handlers.before_provider_request({ payload: {} }, ctx(model)), /not set up for the terminal yet/);
	// A hand-made provider without Pippa's file is left alone.
	assert.equal(await handlers.before_provider_request({ payload: {} }, ctx({ provider: "local" })), undefined);
	writeConfig(port);
	const foreign = createHTTPServer((req, res) => res.writeHead(401).end()).listen(port, "127.0.0.1");
	try {
		await assert.rejects(handlers.before_provider_request({ payload: {} }, ctx(model)), /used by another program/);
	} finally {
		foreign.close();
	}
	assert.equal(ui.notes.length, 4);
	assert.ok(ui.notes.every((n) => n.type === "error"));
	assert.equal(startLines().length, 0);
});

test("a hand-made provider (owner's setup): config names it, no key file", async () => {
	const port = await freePort();
	writeConfig(port, { provider: "local", keyFile: undefined });
	const { handlers, ctx } = loadPi({ hasUI: false });
	await handlers.before_provider_request({ payload: {} }, ctx({ provider: "local", baseUrl: `http://127.0.0.1:${port}/v1` }));
	const [start] = startLines();
	assert.equal(start.key, "");
	assert.equal(await common.health(port, ""), 200);
	await stopAll();
});
