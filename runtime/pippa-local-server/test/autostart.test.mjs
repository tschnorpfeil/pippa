// Pippa's terminal extension without a model and without the real ~/.pi: a fake HOME under .build/, a fake oMLX
// (fake-omlx-server.mjs, a tiny node HTTP server in place of the runtime's python3), a stand-in `pi` that collects the
// handlers.
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
// Must not reach the server: it gets only the launch file's environment (plus HOME and TMPDIR).
process.env.PIPPA_TEST_LEAK = "1";
const support = join(home, "Library/Application Support/Pippa");
mkdirSync(support, { recursive: true });

const { default: extension } = await import("../index.ts");
const common = await import("../common.mjs");
const { ensureServer } = await import("../ensure.mjs");

// The runtime's python3, played by the fake server with this test's node in the shebang.
const runtime = join(support, "mlx-runtime/0.0.1");
const python = join(runtime, "bin/python3");
mkdirSync(join(runtime, "bin"), { recursive: true });
writeFileSync(python, `#!${process.execPath}\nimport(${JSON.stringify(join(here, "fake-omlx-server.mjs"))});\n`);
chmodSync(python, 0o755);
const base = join(support, "omlx");
const modelID = "ornith-1.5-9b-mlx-4bit";
mkdirSync(join(base, "models", modelID), { recursive: true });
const starts = join(root, "starts.jsonl");
const key = "k".repeat(64);
const keyFile = join(support, "local-server-key");
writeFileSync(keyFile, key + "\n", { mode: 0o600 });

const freePort = () =>
	new Promise((resolve) => {
		const s = createServer().listen(0, "127.0.0.1", () => {
			const { port } = s.address();
			s.close(() => resolve(port));
		});
	});

/** oMLX's settings.json as Pippa writes it (PiLocalServer.writeServerSettings): host, port and key live here. */
function writeSettings(port, { host = "127.0.0.1", apiKey = key } = {}) {
	writeFileSync(join(base, "settings.json"), JSON.stringify({ server: { host, port }, auth: { api_key: apiKey } }), { mode: 0o600 });
}

/** The launch file v2 as PiLocalServer.launchConfiguration writes it, and the matching settings.json. */
function writeConfig(port, extra = {}) {
	const config = {
		schemaVersion: 2,
		provider: "pippa-local",
		port,
		binary: python,
		arguments: ["-c", "from omlx.cli import main; main()", "serve", "--base-path", base, "--headless"],
		environment: {
			PATH: "/usr/bin:/bin:/usr/sbin:/sbin", HF_HUB_OFFLINE: "1", TRANSFORMERS_OFFLINE: "1", PYTHONNOUSERSITE: "1",
			OMLX_HEADLESS: "1", FAKE_OMLX_LOG: starts,
		},
		modelID,
		logFile: join(support, "local-server.log"),
		keyFile,
		app: join(root, "Pippa.app"),
		...extra,
	};
	writeFileSync(join(support, "pippa-local-server.json"), JSON.stringify(config));
	writeSettings(port, { apiKey: config.keyFile ? key : "" });
	return config;
}

const configFile = join(support, "pippa-local-server.json");
const lockFile = join(support, "local-server.lock");
const startLines = () => (existsSync(starts) ? readFileSync(starts, "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l)) : []);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(condition, ms = 5000) {
	for (const end = Date.now() + ms; Date.now() < end; await sleep(50)) if (await condition()) return true;
	return false;
}

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
		if (pid !== process.pid && common.isAlive(pid)) try { process.kill(pid, "SIGTERM"); } catch {}
	}
	await until(() => !existsSync(lockFile));
	rmSync(lockFile, { force: true });
	rmSync(starts, { force: true });
}

beforeEach(stopAll);

after(async () => {
	await stopAll();
	rmSync(root, { recursive: true, force: true });
});

test("config v2: no key on the command line, loopback and own port if named, env of strings, clear sentence when missing", () => {
	const file = join(root, "c.json");
	const good = { schemaVersion: 2, provider: "pippa-local", port: 1234, binary: "/x/bin/python3", arguments: ["serve", "--base-path", "/x"], environment: { A: "1" } };
	const load = (raw) => { writeFileSync(file, JSON.stringify(raw)); return common.loadConfig(file); };
	const config = load(good);
	assert.equal(config.basePath, "/x");
	assert.deepEqual(config.environment, { A: "1" });
	assert.equal(config.logFile, join(root, "local-server.log"));
	assert.throws(() => load({ ...good, schemaVersion: 1 }), /schemaVersion/);
	assert.throws(() => load({ ...good, arguments: [...good.arguments, "--api-key", "x"] }), /settings\.json, not in the arguments/);
	assert.throws(() => load({ ...good, arguments: [...good.arguments, "--api-key=x"] }), /not in the arguments/);
	assert.throws(() => load({ ...good, arguments: [...good.arguments, "--host", "0.0.0.0"] }), /127\.0\.0\.1/);
	assert.throws(() => load({ ...good, arguments: [...good.arguments, "--port", "9"] }), /--port/);
	assert.throws(() => load({ ...good, environment: { A: 1 } }), /environment/);
	assert.throws(() => load({ ...good, binary: "python3" }), /absolute/);
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

test("pippa-local, no server: starts it with Pippa's exact binary, arguments and environment, shows a status, then the request goes on", async () => {
	const port = await freePort();
	const config = writeConfig(port);
	const { handlers, ui, ctx } = loadPi();
	const model = { provider: "pippa-local", id: modelID, baseUrl: `http://127.0.0.1:${port}/v1` };
	await handlers.before_provider_request({ payload: { model: modelID } }, ctx(model));
	assert.equal(await common.health(port, key), 200);
	assert.equal(await common.health(port, "wrong"), 401, "the fake checks the key");
	const [start, ...more] = startLines();
	assert.equal(more.length, 0);
	assert.deepEqual(start.args, config.arguments);
	assert.equal(start.cwd, base);
	for (const [name, value] of Object.entries(config.environment)) assert.equal(start.env[name], value, name);
	assert.equal(start.env.HOME, home);
	assert.equal(start.env.PIPPA_TEST_LEAK, undefined, "only the launch file's environment");
	assert.ok(!JSON.stringify(start).includes(key), "the key is neither in the arguments nor in the environment");
	const models = await (await fetch(`http://127.0.0.1:${port}/v1/models`, { headers: { Authorization: `Bearer ${key}` } })).json();
	assert.deepEqual(models.data.map((m) => m.id), [modelID]);
	const lock = common.readLock(lockFile);
	assert.equal(lock.owner, "pi");
	assert.equal(lock.pid, start.pid);
	assert.equal(lock.port, port);
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
	const options = { configFile, lockFile };
	const results = await Promise.all([ensureServer(config, options), ensureServer(config, options), ensureServer(config, options)]);
	assert.equal(startLines().length, 1);
	assert.ok(results.includes("started"));
	await stopAll();
});

test("the server keeps running; when it exits the lock goes, and the next request starts a new one", async () => {
	const port = await freePort();
	const config = writeConfig(port);
	assert.equal(await ensureServer(config, { configFile, lockFile }), "started");
	const first = common.readLock(lockFile);
	await sleep(500);
	assert.equal(await common.health(port, key), 200, "no idle stop of its own");
	process.kill(first.pid, "SIGKILL");
	assert.ok(await until(() => !existsSync(lockFile) && !common.isAlive(first.holder)), "lock removed, supervisor gone");
	assert.equal(await ensureServer(config, { configFile, lockFile }), "started");
	assert.equal(startLines().length, 2);
	// Stopping the supervisor stops its server and gives back the lock.
	const second = common.readLock(lockFile);
	process.kill(second.holder, "SIGTERM");
	assert.ok(await until(() => !existsSync(lockFile) && !common.isAlive(second.pid)), "server and lock gone");
	assert.equal(await common.health(port, key), 0);
});

test("a quiet log for idleStopSeconds stops the server and gives back the lock", async () => {
	const port = await freePort();
	const config = writeConfig(port, { idleStopSeconds: 1 });
	assert.equal(await ensureServer(config, { configFile, lockFile }), "started");
	const running = common.readLock(lockFile);
	assert.ok(await until(() => !existsSync(lockFile) && !common.isAlive(running.pid) && !common.isAlive(running.holder), 8000), "stopped when idle");
	assert.equal(await common.health(port, key), 0);
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
		const result = await ensureServer(config, { configFile, lockFile, spawnSupervisor: () => { started = true; } });
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

test("clear sentences: runtime missing, model missing, settings off loopback, setup missing, port taken by another program", async () => {
	const port = await freePort();
	const { handlers, ui, ctx } = loadPi();
	const model = { provider: "pippa-local" };
	writeConfig(port, { binary: join(support, "mlx-runtime/9.9.9/bin/python3") });
	await assert.rejects(handlers.before_provider_request({ payload: {} }, ctx(model)), /AI runtime is missing/);
	writeConfig(port, { modelID: "gone-model" });
	await assert.rejects(handlers.before_provider_request({ payload: {} }, ctx(model)), /model gone-model is missing/);
	writeConfig(port);
	writeSettings(port, { host: "0.0.0.0" });
	await assert.rejects(handlers.before_provider_request({ payload: {} }, ctx(model)), /settings\.json does not match/);
	rmSync(configFile);
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
	assert.equal(ui.notes.length, 5);
	assert.ok(ui.notes.every((n) => n.type === "error"));
	assert.equal(startLines().length, 0);
});

test("a hand-made provider (owner's setup): config names it, no key file", async () => {
	const port = await freePort();
	writeConfig(port, { provider: "local", keyFile: undefined });
	const { handlers, ctx } = loadPi({ hasUI: false });
	await handlers.before_provider_request({ payload: {} }, ctx({ provider: "local", baseUrl: `http://127.0.0.1:${port}/v1` }));
	assert.equal(startLines().length, 1);
	assert.equal(await common.health(port, ""), 200);
	await stopAll();
});

test("removeLockIf never unlinks a lock file when readLock returns null", () => {
	const partial = join(root, "partial.lock");
	writeFileSync(partial, "{");
	assert.equal(common.removeLockIf(partial, () => true), false);
	assert.equal(existsSync(partial), true);
	rmSync(partial, { force: true });
});
