// Shared by the Pi extension (index.ts) and the detached supervisor (supervisor.mjs). Plain JavaScript, no
// dependencies, so it runs in Pi's Node (Pi 1.0.4 and 1.1.0) and in `node --test` alike.
//
// Files in Pippa's support folder (~/Library/Application Support/Pippa, or $PIPPA_SUPPORT_DIR):
//   pippa-local-server.json   written by Pippa: how to start llama-server for `pippa-local` (binary, arguments, …)
//   llama-server-pi.lock      the one lock/pid file; the app (LlamaServer with a lock file) honours the same file
//   llama-key                 0600 key file (optional; the config names it)
//   llama-server-pi.log       server output, shared with the app
import { closeSync, existsSync, openSync, readFileSync, renameSync, statSync, unlinkSync, utimesSync, writeSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, isAbsolute, join } from "node:path";

export const CONFIG_NAME = "pippa-local-server.json";
export const LOCK_NAME = "llama-server-pi.lock";
export const DEFAULT_IDLE_SECONDS = 600;

export function supportDir(env = process.env) {
	if (env.PIPPA_SUPPORT_DIR) return env.PIPPA_SUPPORT_DIR;
	return join(env.HOME || homedir(), "Library", "Application Support", "Pippa");
}

export const configPath = (env = process.env) => join(supportDir(env), CONFIG_NAME);
export const lockPath = (env = process.env) => join(supportDir(env), LOCK_NAME);

/** A user-facing failure (shown as is, no stack). */
export class ServerError extends Error {
	constructor(message) {
		super(message);
		this.name = "ServerError";
	}
}

/**
 * Read and check Pippa's launch file. Refuses anything that would listen beyond loopback, carries a key on the command
 * line, or names a port other than its own.
 */
export function loadConfig(path) {
	if (!existsSync(path)) {
		throw new ServerError(`Pippa's local model is not set up for the terminal yet. Open Pippa once; it writes ${path}.`);
	}
	let raw;
	try {
		raw = JSON.parse(readFileSync(path, "utf8"));
	} catch (error) {
		throw new ServerError(`Cannot read ${path}: ${error.message}. Open Pippa once to rewrite it.`);
	}
	const bad = (why) => new ServerError(`${path} is not usable (${why}). Open Pippa once to rewrite it.`);
	if (raw?.schemaVersion !== 1) throw bad("unknown schemaVersion");
	if (typeof raw.provider !== "string" || !raw.provider) throw bad("provider missing");
	if (!Number.isInteger(raw.port) || raw.port < 1 || raw.port > 65535) throw bad("port missing");
	if (typeof raw.binary !== "string" || !isAbsolute(raw.binary)) throw bad("binary must be an absolute path");
	const args = raw.arguments;
	if (!Array.isArray(args) || !args.every((a) => typeof a === "string")) throw bad("arguments must be strings");
	const after = (flag) => {
		const i = args.indexOf(flag);
		return i >= 0 ? args[i + 1] : undefined;
	};
	if (after("--host") !== "127.0.0.1") throw bad("--host must be 127.0.0.1");
	if (after("--port") !== String(raw.port)) throw bad("--port must match port");
	if (args.includes("--api-key") || args.includes("--api-key-file")) throw bad("the key belongs in keyFile, not in the arguments");
	if (raw.keyFile !== undefined && (typeof raw.keyFile !== "string" || !isAbsolute(raw.keyFile))) throw bad("keyFile must be an absolute path");
	const idleSeconds = raw.idleSeconds === undefined ? DEFAULT_IDLE_SECONDS : Number(raw.idleSeconds);
	if (!(idleSeconds > 0)) throw bad("idleSeconds must be positive");
	return {
		provider: raw.provider,
		port: raw.port,
		binary: raw.binary,
		arguments: args,
		keyFile: raw.keyFile,
		idleSeconds,
		modelID: typeof raw.modelID === "string" ? raw.modelID : undefined,
		app: typeof raw.app === "string" ? raw.app : undefined,
		logFile: typeof raw.logFile === "string" && isAbsolute(raw.logFile) ? raw.logFile : join(dirname(path), "llama-server-pi.log"),
		modelFile: after("-m") ?? after("--model"),
	};
}

/** Key from the 0600 key file, or "" without one. */
export function readKey(config) {
	if (!config.keyFile) return "";
	try {
		return readFileSync(config.keyFile, "utf8").trim();
	} catch {
		throw new ServerError(`The key file ${config.keyFile} is missing. Open Pippa once to repair the setup.`);
	}
}

/** Before starting anything: do the server binary (inside Pippa.app) and the model file exist? */
export function checkStartable(config) {
	if (!existsSync(config.binary)) {
		const where = config.app ? `${config.app} is missing or was moved` : `${config.binary} is missing`;
		throw new ServerError(`Cannot start the local model: ${where} (no llama-server at ${config.binary}). Install or open Pippa, then try again.`);
	}
	if (config.modelFile && !existsSync(config.modelFile)) {
		throw new ServerError(`Cannot start the local model: the model file ${config.modelFile} is missing. Open Pippa to set up the model again.`);
	}
}

// MARK: Lock

export function isAlive(pid) {
	if (!Number.isInteger(pid) || pid <= 0) return false;
	try {
		process.kill(pid, 0);
		return true;
	} catch (error) {
		return error.code === "EPERM";
	}
}

/** `{ owner: "app" | "pi", holder, pid, port, startedAt }` or `null`. */
export function readLock(path) {
	try {
		const lock = JSON.parse(readFileSync(path, "utf8"));
		return lock && typeof lock === "object" ? lock : null;
	} catch {
		return null;
	}
}

/**
 * Live while the server runs (`pid`); before the server exists (starting), while its holder (app or supervisor) runs.
 * Same rule as PiServerLock.isLive in the app.
 */
export const lockIsLive = (lock) => !!lock && (Number.isInteger(lock.pid) ? isAlive(lock.pid) : isAlive(lock.holder));

/** Create the lock only if there is none (O_EXCL). */
export function createLock(path, data) {
	let fd;
	try {
		fd = openSync(path, "wx", 0o600);
	} catch (error) {
		if (error.code === "EEXIST") return false;
		throw error;
	}
	try {
		writeSync(fd, JSON.stringify(data) + "\n");
	} finally {
		closeSync(fd);
	}
	return true;
}

/** Replace the contents of a lock we hold (temp file + rename). */
export function writeLock(path, data) {
	const temporary = `${path}.${process.pid}.tmp`;
	const fd = openSync(temporary, "w", 0o600);
	try {
		writeSync(fd, JSON.stringify(data) + "\n");
	} finally {
		closeSync(fd);
	}
	renameSync(temporary, path);
}

/** Remove the lock if it still says what `matches` expects (never someone else's newer lock). */
export function removeLockIf(path, matches) {
	const lock = readLock(path);
	if (lock && !matches(lock)) return false;
	try {
		unlinkSync(path);
		return true;
	} catch {
		return false;
	}
}

/** Remove a stale lock, unless it changed since we looked at it. */
export function removeStaleLock(path, seen) {
	return removeLockIf(path, (lock) => JSON.stringify(lock) === JSON.stringify(seen) && !lockIsLive(lock));
}

/** Mark the server as in use (the idle watchdog counts the lock's mtime as activity). */
export function touchLock(path) {
	try {
		const now = new Date();
		utimesSync(path, now, now);
	} catch {}
}

export function lockTouchedAt(path) {
	try {
		return statSync(path).mtimeMs;
	} catch {
		return 0;
	}
}

// MARK: HTTP

async function get(port, key, path, timeoutMs) {
	const headers = key ? { Authorization: `Bearer ${key}` } : {};
	return fetch(`http://127.0.0.1:${port}${path}`, { headers, signal: AbortSignal.timeout(timeoutMs) });
}

/** HTTP status of `/health` (200 ready, 503 loading), 0 if nothing answers. */
export async function health(port, key, timeoutMs = 2000) {
	try {
		const response = await get(port, key, "/health", timeoutMs);
		await response.arrayBuffer().catch(() => {});
		return response.status;
	} catch {
		return 0;
	}
}

/** `/slots` as an array, or `null` if unreadable. */
export async function slots(port, key, timeoutMs = 2000) {
	try {
		const response = await get(port, key, "/slots", timeoutMs);
		if (response.status !== 200) return null;
		const body = await response.json();
		return Array.isArray(body) ? body : null;
	} catch {
		return null;
	}
}

export const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
