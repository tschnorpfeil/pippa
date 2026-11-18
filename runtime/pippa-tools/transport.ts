/**
 * A request with a body is never sent on to another address (issue #196 review). `fetch` follows a 307 or 308 by
 * sending the same body again to wherever `Location` points, and a 301, 302 or 303 by sending the request's other
 * headers there (an `x-api-key` or `api-key` among them). For a provider request that body is the conversation, with
 * whatever the person shared or allowed the AI to read on this Mac; the recipient Pippa checked and pinned is the one
 * address, not wherever it forwards to.
 *
 * pippa-tools.ts calls `refuseRedirects()` when Pi loads it, before Pi's first provider request. From then on every
 * `fetch` in the Pi process that carries a body (POST, PUT, …) runs with `redirect: "manual"`; a redirect answer comes
 * back as an error the provider code reports (status 400, no retry), and the other address receives nothing. Requests
 * without a body (web pages read with GET) are unchanged, and so are answers that are no redirect, streams included.
 *
 * This covers Pi's providers that use `fetch` (OpenAI, Anthropic, Google and OpenAI- or Anthropic-compatible custom
 * endpoints): their clients take the global `fetch` when they are created, per request. A later replacement of the
 * global (Pi installs its bundled undici `fetch`) is wrapped as well.
 */

const GUARDED = Symbol.for("pippa.refuseRedirects");

export function redirectReason(status: number, location: string | null): string {
	let where = "another address";
	try { if (location) where = new URL(location).origin; } catch { /* relative or malformed: same words */ }
	return `The online AI's server answered with a redirect (HTTP ${status}) to ${where}. Pippa sends a request only to the `
		+ "address she checked, so nothing was sent there. Check the address in Settings or ask the provider.";
}

function carriesBody(input: any, init: any): boolean {
	const method = String(init?.method ?? (typeof input === "object" && input && "method" in input ? input.method : "GET")).toUpperCase();
	if (init?.body != null) return true;
	return method !== "GET" && method !== "HEAD";
}

/** `fetch` that never follows a redirect for a request with a body. */
export function guardFetch<F extends (...args: any[]) => Promise<any>>(fetch: F): F {
	if (typeof fetch !== "function" || (fetch as any)[GUARDED]) return fetch;
	const wrapped = async function (input: any, init?: any) {
		if (!carriesBody(input, init)) return fetch(input, init);
		const response = await fetch(input, { ...(init ?? {}), redirect: "manual" });
		const status = Number(response?.status);
		if (response?.type === "opaqueredirect" || (status >= 300 && status < 400 && status !== 304)) {
			try { await response.body?.cancel(); } catch { /* already closed */ }
			const message = redirectReason(status, response.headers?.get?.("location") ?? null);
			// A client error, so the provider code reports it as it is instead of trying again.
			return new Response(JSON.stringify({ type: "error", error: { type: "redirect_refused", message } }),
				{ status: 400, statusText: "Redirect refused", headers: { "content-type": "application/json" } });
		}
		return response;
	} as unknown as F;
	(wrapped as any)[GUARDED] = true;
	return wrapped;
}

/** Wraps the global `fetch` now and whatever replaces it later. */
export function refuseRedirects(target: any = globalThis): void {
	const descriptor = Object.getOwnPropertyDescriptor(target, "fetch");
	if (descriptor?.get && (descriptor.get as any)[GUARDED]) return;
	let current = guardFetch(target.fetch);
	const get = () => current;
	(get as any)[GUARDED] = true;
	Object.defineProperty(target, "fetch", {
		configurable: true, enumerable: descriptor?.enumerable ?? true,
		get, set: (value: any) => { current = guardFetch(value); },
	});
}
