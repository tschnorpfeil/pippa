// Shared by the Pi extension (index.ts), ensure.mjs and the detached supervisor (supervisor.mjs). Plain JavaScript, no
// dependencies, so it runs in Pi's Node (Pi 1.0.4 and 1.1.0) and in `node --test` alike.
//
// Files in Pippa's support folder (~/Library/Application Support/Pippa, or $PIPPA_SUPPORT_DIR):
//   pippa-local-server.json   written by Pippa (PiLocalServer.publishLaunchFile): how to start oMLX for `pippa-local`
//   local-server.lock         the one lock/pid file; the app (OMLXServer, PiServerLock) honours the same file
//   local-server-key          0600 key file; Pi sends it, and so does /health here. oMLX itself reads it from its own
//                             settings.json (<--base-path>/settings.json), never from the command line
//   local-server.log          server output, shared with the app
import { closeSync, existsSync, openSync, readFileSync, renameSync, unlinkSync, writeSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, isAbsolute, join } from "node:path";

export const CONFIG_NAME = "pippa-local-server.json";
export const LOCK_NAME = "local-server.lock";

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
 * Read and check Pippa's launch file (schemaVersion 2). Refuses a key on the command line (it would show in `ps`) and,
 * when the arguments set them anyway, a host other than loopback or a port other than its own.
 */
/** No log line for this long (no request, no model load or unload): the supervisor stops the server. */
export const IDLE_STOP_SECONDS = 1800;

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
	if (raw?.schemaVersion !== 2) throw bad("unknown schemaVersion");
	if (typeof raw.provider !== "string" || !raw.provider) throw bad("provider missing");
	if (!Number.isInteger(raw.port) || raw.port < 1 || raw.port > 65535) throw bad("port missing");
	if (typeof raw.binary !== "string" || !isAbsolute(raw.binary)) throw bad("binary must be an absolute path");
	const args = raw.arguments;
	if (!Array.isArray(args) || !args.every((a) => typeof a === "string")) throw bad("arguments must be strings");
	if (args.some((a) => a === "--api-key" || a.startsWith("--api-key="))) throw bad("the key belongs in oMLX's settings.json, not in the arguments");
	const after = (flag) => {
		const i = args.indexOf(flag);
		return i >= 0 ? args[i + 1] : undefined;
	};
	if (args.includes("--host") && after("--host") !== "127.0.0.1") throw bad("--host must be 127.0.0.1");
	if (args.includes("--port") && after("--port") !== String(raw.port)) throw bad("--port must match port");
	const environment = raw.environment ?? {};
	if (typeof environment !== "object" || Array.isArray(environment) || !Object.values(environment).every((v) => typeof v === "string")) {
		throw bad("environment must map names to strings");
	}
	if (raw.keyFile !== undefined && (typeof raw.keyFile !== "string" || !isAbsolute(raw.keyFile))) throw bad("keyFile must be an absolute path");
	return {
		provider: raw.provider,
		port: raw.port,
		binary: raw.binary,
		arguments: args,
		environment,
		keyFile: raw.keyFile,
		modelID: typeof raw.modelID === "string" && raw.modelID ? raw.modelID : undefined,
		app: typeof raw.app === "string" ? raw.app : undefined,
		logFile: typeof raw.logFile === "string" && isAbsolute(raw.logFile) ? raw.logFile : join(dirname(path), "local-server.log"),
		basePath: after("--base-path"),
		idleStopSeconds: Number.isFinite(raw.idleStopSeconds) && raw.idleStopSeconds > 0 ? raw.idleStopSeconds : IDLE_STOP_SECONDS,
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

/**
 * Before starting anything: is the runtime there, is the model in Pippa's folder, and does oMLX's own settings.json
 * (where host and port really come from) keep it on loopback and on the right port?
 */
export function checkStartable(config) {
	if (!existsSync(config.binary)) {
		throw new ServerError(`Cannot start the local model: Pippa's AI runtime is missing (${config.binary}). Open Pippa; setup downloads it again.`);
	}
	if (!config.basePath) return;
	if (config.modelID && !existsSync(join(config.basePath, "models", config.modelID))) {
		throw new ServerError(`Cannot start the local model: the model ${config.modelID} is missing in ${join(config.basePath, "models")}. Open Pippa to set up the model again.`);
	}
	let server;
	try {
		server = JSON.parse(readFileSync(join(config.basePath, "settings.json"), "utf8"))?.server;
	} catch {
		throw new ServerError(`Cannot start the local model: ${join(config.basePath, "settings.json")} is missing. Open Pippa once to repair the setup.`);
	}
	if (server?.host !== "127.0.0.1" || server?.port !== config.port) {
		throw new ServerError(`Cannot start the local model: oMLX's settings.json does not match Pippa's setup (127.0.0.1:${config.port}). Open Pippa once to repair it.`);
	}
}

/** What the server runs with: the launch file's variables plus HOME and TMPDIR (Pippa leaves those to the starter). */
export function serverEnvironment(config, env = process.env) {
	const result = { ...config.environment };
	if (!result.HOME) result.HOME = env.HOME || homedir();
	if (!result.TMPDIR && env.TMPDIR) result.TMPDIR = env.TMPDIR;
	return result;
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
	if (!lock || !matches(lock)) return false;
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

// MARK: HTTP

/** HTTP status of `/health` (200 ready), 0 if nothing answers. */
export async function health(port, key, timeoutMs = 2000) {
	try {
		const headers = key ? { Authorization: `Bearer ${key}` } : {};
		const response = await fetch(`http://127.0.0.1:${port}/health`, { headers, signal: AbortSignal.timeout(timeoutMs) });
		await response.arrayBuffer().catch(() => {});
		return response.status;
	} catch {
		return 0;
	}
}

export const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
