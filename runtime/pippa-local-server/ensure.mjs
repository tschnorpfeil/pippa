// Make sure Pippa's llama-server answers before Pi sends a request to it. Used by index.ts; testable on its own.
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import {
	checkStartable,
	health,
	lockIsLive,
	readKey,
	readLock,
	removeStaleLock,
	ServerError,
	sleep,
	touchLock,
} from "./common.mjs";

const supervisorPath = fileURLToPath(new URL("./supervisor.mjs", import.meta.url));

/**
 * Ready → "running". Someone (the app, another terminal Pi) is starting it → wait, "waited". Nothing there → start the
 * supervisor, wait for /health, "started". Throws `ServerError` with a sentence for the person otherwise.
 *
 * options: { configFile, lockFile, onStarting(), timeoutMs, pollMs, node, spawnSupervisor }
 */
export async function ensureServer(config, options) {
	const { configFile, lockFile } = options;
	const key = readKey(config);
	const first = await health(config.port, key);
	if (first === 200) {
		touchLock(lockFile);
		return "running";
	}
	const timeoutMs = options.timeoutMs ?? (Number(process.env.PIPPA_LLAMA_START_TIMEOUT_MS) || 600_000);
	const pollMs = options.pollMs ?? 250;
	const deadline = Date.now() + timeoutMs;
	let spawnedAt = 0;
	let announced = false;
	const announce = () => {
		if (!announced) options.onStarting?.();
		announced = true;
	};

	for (let status = first; ; status = await health(config.port, key)) {
		if (status === 200) {
			touchLock(lockFile);
			return spawnedAt ? "started" : "waited";
		}
		const lock = readLock(lockFile);
		const live = lockIsLive(lock);
		if (live && Number.isInteger(lock.port) && lock.port !== config.port) {
			throw new ServerError(`Pippa's local model is already running on port ${lock.port}, not ${config.port}. Open Pippa once to repair the setup.`);
		}
		if (!live) {
			if (lock) removeStaleLock(lockFile, lock);
			if (spawnedAt) {
				// Our supervisor had its chance: it either lost the lock race (then the lock is live) or the server died.
				if (Date.now() - spawnedAt > 3000) {
					throw new ServerError(`The local model stopped while starting. Details: ${config.logFile}`);
				}
			} else if (status !== 0 && status !== 503) {
				// Something answers on the port, but it is not a llama-server we know (wrong key, another program).
				throw new ServerError(`Port ${config.port} is used by another program (HTTP ${status}), so the local model cannot start there.`);
			} else {
				checkStartable(config);
				announce();
				(options.spawnSupervisor ?? spawnSupervisor)(configFile, lockFile, options.node);
				spawnedAt = Date.now();
			}
		} else {
			announce();
		}
		if (Date.now() > deadline) {
			throw new ServerError(`The local model did not become ready within ${Math.round(timeoutMs / 1000)} s. Details: ${config.logFile}`);
		}
		await sleep(pollMs);
	}
}

/** Detached, own session: survives the terminal and Pi. */
export function spawnSupervisor(configFile, lockFile, node = process.execPath) {
	const child = spawn(node, [supervisorPath, configFile, lockFile], { detached: true, stdio: "ignore", env: process.env });
	child.on("error", () => {});
	child.unref();
	return child;
}
