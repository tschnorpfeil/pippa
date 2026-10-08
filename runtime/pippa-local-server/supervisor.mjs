// Detached supervisor for a llama-server started from the terminal (index.ts spawns it, then it outlives Pi).
//
//   node supervisor.mjs <pippa-local-server.json> <llama-server-pi.lock>
//
// 1. Takes the lock (O_EXCL). Someone else holds it (the app, another terminal Pi): exit 0, the caller waits for /health.
// 2. Starts llama-server with exactly the arguments Pippa wrote, the key only in LLAMA_API_KEY, output to the shared log.
// 3. Idle watchdog (llama-server b11146 has no idle flag): every poll it reads /slots; a slot processing, a changed
//    task id, or a touched lock file (the app and the extension touch it per request) counts as use. After
//    `idleSeconds` without use it stops the server (SIGTERM, then SIGKILL) and removes the lock.
// 4. Server gone for any reason: remove the lock (only if it is still ours) and exit.
//
// Test knobs: PIPPA_LLAMA_POLL_MS (default 5000), PIPPA_LLAMA_IDLE_SECONDS (overrides the config).
import { spawn } from "node:child_process";
import { mkdirSync, openSync, writeSync } from "node:fs";
import { dirname } from "node:path";
import { createLock, health, loadConfig, lockTouchedAt, readKey, removeLockIf, slots, sleep, writeLock } from "./common.mjs";

const [configFile, lockFile] = process.argv.slice(2);
if (!configFile || !lockFile) {
	console.error("usage: supervisor.mjs <config> <lock>");
	process.exit(2);
}

const config = loadConfig(configFile);
const key = readKey(config);
const pollMs = Number(process.env.PIPPA_LLAMA_POLL_MS) || 5000;
const idleMs = (Number(process.env.PIPPA_LLAMA_IDLE_SECONDS) || config.idleSeconds) * 1000;

const lock = { owner: "pi", holder: process.pid, pid: null, port: config.port, startedAt: new Date().toISOString() };
if (!createLock(lockFile, lock)) process.exit(0);

const ours = (current) => current.holder === process.pid;
let child;
let stopping = false;

function finish(code) {
	removeLockIf(lockFile, ours);
	process.exit(code);
}

async function stopServer(reason) {
	if (stopping) return;
	stopping = true;
	log(`stopping llama-server (${reason})`);
	if (child && child.exitCode === null && child.signalCode === null) {
		child.kill("SIGTERM");
		for (let i = 0; i < 30 && child.exitCode === null && child.signalCode === null; i++) await sleep(100);
		if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
	}
	finish(0);
}

let logFd;
function log(line) {
	try {
		if (logFd !== undefined) writeSync(logFd, `[pippa-local-server] ${new Date().toISOString()} ${line}\n`);
	} catch {}
}

try {
	mkdirSync(dirname(config.logFile), { recursive: true });
	logFd = openSync(config.logFile, "a", 0o600);
	// R7 of the app: the slot folder must exist (0700) when the arguments name one.
	const slotIndex = config.arguments.indexOf("--slot-save-path");
	if (slotIndex >= 0 && config.arguments[slotIndex + 1]) mkdirSync(config.arguments[slotIndex + 1], { recursive: true, mode: 0o700 });

	const env = { ...process.env };
	delete env.LLAMA_API_KEY;
	if (key) env.LLAMA_API_KEY = key;
	log(`starting ${config.binary} on 127.0.0.1:${config.port} for the terminal (idle ${Math.round(idleMs / 1000)} s)`);
	child = spawn(config.binary, config.arguments, { stdio: ["ignore", logFd, logFd], env, cwd: dirname(config.logFile) });
	await new Promise((resolve, reject) => {
		child.once("spawn", resolve);
		child.once("error", reject);
	});
} catch (error) {
	log(`cannot start: ${error.message}`);
	finish(1);
}

writeLock(lockFile, { ...lock, pid: child.pid });
child.on("exit", (code, signal) => {
	if (!stopping) log(`llama-server exited (${signal ?? code})`);
	finish(0);
});
for (const signal of ["SIGTERM", "SIGINT", "SIGHUP"]) process.on(signal, () => stopServer(signal));

// Wait until the model is loaded; the idle clock starts only then.
while ((await health(config.port, key)) !== 200) await sleep(Math.min(pollMs, 250));

let lastUse = Date.now();
let fingerprint;
for (;;) {
	await sleep(pollMs);
	if (stopping) break;
	const touched = lockTouchedAt(lockFile);
	if (touched > lastUse) lastUse = touched;
	const current = await slots(config.port, key);
	if (current === null) {
		// Unreadable /slots: never unload on a guess while the server answers /health.
		if ((await health(config.port, key)) === 200) lastUse = Date.now();
	} else {
		const print = JSON.stringify(current.map((s) => [s.id, s.id_task ?? null, s.n_past ?? null]));
		if (current.some((s) => s.is_processing) || (fingerprint !== undefined && print !== fingerprint)) lastUse = Date.now();
		fingerprint = print;
	}
	if (Date.now() - lastUse >= idleMs) await stopServer("idle");
}
