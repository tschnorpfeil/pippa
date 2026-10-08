// Pippa's local model for `pi` in the terminal. Pippa installs this folder as ~/.pi/agent/extensions/pippa-local-server
// (PiInstaller, step "models.json"); Pi loads it like any user extension (Pi 1.0.4 and 1.1.0).
//
// Pi itself never starts model servers, so without Pippa running, `pi` with provider `pippa-local` failed with
// "Connection error". Now, right before a request goes to that provider, this extension checks `/health` and, if
// nothing answers, starts llama-server exactly as Pippa would (pippa-local-server.json, written by Pippa) through a
// detached supervisor that unloads it after the same idle time. One lock file in Pippa's support folder keeps the app
// and terminal from ever running two servers; the app adopts a server started here (LlamaServer, `lockFile`).
//
// Hooks: `before_provider_request` (awaited by Pi before the HTTP request, also for each tool turn) and
// `session_before_compact` (compaction calls the model without that hook). Other providers: nothing happens.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { configPath, loadConfig, lockPath, ServerError } from "./common.mjs";
import { ensureServer } from "./ensure.mjs";

const PROVIDER = "pippa-local";
const STATUS_KEY = "pippa-local-server";
const STARTING = "Starting the local model…";

type Ctx = {
	model?: { provider?: string; id?: string; baseUrl?: string };
	hasUI?: boolean;
	ui?: {
		notify?(message: string, type?: "info" | "warning" | "error"): void;
		setStatus?(key: string, text: string | undefined): void;
		setWorkingMessage?(message?: string): void;
	};
};

export default function pippaLocalServer(pi: ExtensionAPI) {
	let pending: Promise<unknown> | undefined;

	async function ensure(ctx: Ctx) {
		const provider = ctx.model?.provider;
		if (!provider) return;
		const file = configPath();
		let config: ReturnType<typeof loadConfig>;
		try {
			config = loadConfig(file);
		} catch (error) {
			// Without Pippa's file only `pippa-local` needs telling; a hand-made provider is not ours.
			if (provider === PROVIDER) fail(ctx, error);
			return;
		}
		if (provider !== config.provider) return;
		const port = portOf(ctx.model?.baseUrl);
		if (port !== undefined && port !== config.port) {
			fail(ctx, new ServerError(`models.json points ${provider} at port ${port}, but Pippa's server uses ${config.port}. Open Pippa once to repair models.json.`));
		}
		// One start per Pi process, however many requests arrive at once.
		if (!pending) {
			let shown = false;
			pending = ensureServer(config, {
				configFile: file,
				lockFile: lockPath(),
				onStarting: () => {
					shown = true;
					status(ctx, STARTING);
				},
			}).finally(() => {
				pending = undefined;
				if (shown) status(ctx, undefined);
			});
		}
		try {
			await pending;
		} catch (error) {
			fail(ctx, error);
		}
	}

	pi.on("before_provider_request", async (_event, ctx) => {
		await ensure(ctx as Ctx);
		return undefined; // payload unchanged
	});
	pi.on("session_before_compact", async (_event, ctx) => {
		await ensure(ctx as Ctx);
		return undefined;
	});
}

function portOf(baseUrl: string | undefined): number | undefined {
	if (!baseUrl) return undefined;
	try {
		const url = new URL(baseUrl);
		return url.port ? Number(url.port) : undefined;
	} catch {
		return undefined;
	}
}

function status(ctx: Ctx, text: string | undefined) {
	if (ctx.hasUI && ctx.ui) {
		ctx.ui.setStatus?.(STATUS_KEY, text);
		ctx.ui.setWorkingMessage?.(text);
	} else if (text) {
		process.stderr.write(`${text}\n`);
	}
}

/** Say it in one sentence, then let Pi report the failed request (it continues and gets a connection error). */
function fail(ctx: Ctx, error: unknown): never {
	const message = error instanceof ServerError ? error.message : `Pippa's local model: ${(error as Error)?.message ?? error}`;
	if (ctx.hasUI && ctx.ui?.notify) ctx.ui.notify(message, "error");
	else process.stderr.write(`${message}\n`);
	throw error instanceof ServerError ? error : new ServerError(message);
}
