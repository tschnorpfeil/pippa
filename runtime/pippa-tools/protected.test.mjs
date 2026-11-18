// protected.ts and transport.ts without Pi: which paths count as Pippa's own or Pi's sign-in folders, how a tool call
// names them, the shell's sandbox rules, and a fetch that never follows a redirect for a request with a body.
//
//   node --experimental-strip-types --test runtime/pippa-tools/protected.test.mjs
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, realpathSync } from "node:fs";
import { link, mkdir, mkdtemp, rename, rm, symlink, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { isProtected, namedPaths, protection, PROTECTED_REASON, sandboxRules, toolCallReason } from "./protected.ts";
import { guardFetch, refuseRedirects } from "./transport.ts";
import { places, sandboxProfile } from "./shell.ts";

const here = fileURLToPath(new URL(".", import.meta.url));
const build = join(here, "../../.build");
const onMac = process.platform === "darwin" && existsSync("/usr/bin/sandbox-exec");

async function fixture() {
	await mkdir(build, { recursive: true });
	const home = realpathSync(await mkdtemp(join(build, "pippa-protected-")));
	const support = join(home, "Library/Application Support/Pippa");
	for (const path of [join(support, "pi-work"), join(support, "pi-sessions"), join(home, ".pi/agent"), join(home, "Documents")]) await mkdir(path, { recursive: true });
	await writeFile(join(support, "inference-settings.json"), "{}");
	await writeFile(join(home, ".pi/agent/auth.json"), "{}");
	await writeFile(join(support, "pi-work/note.txt"), "ok");
	await writeFile(join(home, "Documents/a.txt"), "ok");
	await symlink(join(home, ".pi/agent/auth.json"), join(support, "pi-work/alias.json"));
	await symlink(join(support, "pi-sessions"), join(home, "Documents/sessions"));
	const env = { HOME: home, PIPPA_WORK_DIR: join(support, "pi-work") };
	return { home, support, env, where: protection(env, home) };
}

test("Pippa's folder and ~/.pi are protected by real location; the working folder and the person's files are not", async () => {
	const { home, support, where } = await fixture();
	try {
		const yes = [join(support, "inference-settings.json"), join(support, "new-file"), join(support, "pi-sessions/x.jsonl"),
			join(home, ".pi/agent/auth.json"), join(home, ".PI/Agent/auth.json"), join(support.toUpperCase().replace(home.toUpperCase(), home), "memory.md"),
			join(support, "pi-work/../memory.md"), join(support, "pi-work/alias.json"), join(home, "Documents/sessions/x.jsonl"),
			`/System/Volumes/Data${join(home, ".pi/agent/auth.json")}`, support, join(home, ".pi")];
		for (const path of yes) assert.equal(isProtected(path, where), true, path);
		const no = [join(support, "pi-work/note.txt"), join(support, "pi-work/new.txt"), join(support, "pi-work"), join(home, "Documents/a.txt"),
			join(home, "Library/Application Support/Other/x"), join(home, ".pippa-elsewhere")];
		for (const path of no) assert.equal(isProtected(path, where), false, path);
	} finally { await rm(home, { recursive: true, force: true }); }
});

test("hard-linked files cannot alias a credential through an open folder", async () => {
	const { home, support, where } = await fixture();
	try {
		const alias = join(support, "pi-work", "letter.txt");
		await link(join(home, ".pi/agent/auth.json"), alias);
		assert.equal(isProtected(alias, where), true);
		assert.equal(toolCallReason("read", { path: alias }, join(support, "pi-work"), where), PROTECTED_REASON);
	} finally { await rm(home, { recursive: true, force: true }); }
});

test("the app's list adds places; the defaults stay without it; a working folder that holds a protected one is not open", () => {
	const home = "/Users/fixture";
	const given = protection({ HOME: home, PIPPA_PROTECTED_PATHS: JSON.stringify(["/Volumes/Other/agent"]), PI_CODING_AGENT_DIR: "/tmp/pinned",
		PIPPA_MEMORY_FILE: "/Users/fixture/elsewhere/memory.md" }, home);
	for (const root of ["/Users/fixture/.pi", "/Users/fixture/Library/Application Support/Pippa", "/Volumes/Other/agent", "/tmp/pinned", "/Users/fixture/elsewhere/memory.md"]) {
		assert.ok(given.roots.includes(root), root);
	}
	assert.deepEqual(protection({ HOME: home, PIPPA_PROTECTED_PATHS: "not json" }, home).roots, ["/Users/fixture/.pi", "/Users/fixture/Library/Application Support/Pippa"]);
	assert.deepEqual(protection({ HOME: home, PIPPA_WORK_DIR: home }, home).open, [], "the home folder holds ~/.pi: never open");
});

test("tool calls: every path argument counts, resolved the ways the tool could; the shell is left to its sandbox", async () => {
	const { home, support, where } = await fixture();
	const cwd = join(support, "pi-work");
	try {
		assert.equal(toolCallReason("read", { path: "../inference-settings.json" }, cwd, where), PROTECTED_REASON);
		assert.equal(toolCallReason("read", { path: "alias.json" }, cwd, where), PROTECTED_REASON);
		assert.equal(toolCallReason("write", { file_path: join(home, ".pi/agent/models.json"), content: "x" }, cwd, where), PROTECTED_REASON);
		assert.equal(toolCallReason("move_files", { from: join(support, "pi-sessions/x.jsonl"), to: "trash" }, cwd, where), PROTECTED_REASON);
		assert.equal(toolCallReason("move_files", { folder: support, groups: [{ into: "pi-work", files: ["memory.md"] }] }, cwd, where), PROTECTED_REASON);
		assert.equal(toolCallReason("move_files", { from: "note.txt", to: join(home, ".pi") }, cwd, where), PROTECTED_REASON);
		assert.equal(toolCallReason("list_folder", { path: join(home, "Documents/sessions") }, cwd, where), PROTECTED_REASON);
		assert.equal(toolCallReason("mcp__pippa__read_document", { path: `file://${join(home, ".pi/agent/auth.json")}` }, cwd, where), PROTECTED_REASON);
		assert.equal(toolCallReason("mcp__pippa__prepare_files", { paths: [join(home, "Documents/a.txt"), join(support, "memory.md")] }, cwd, where), PROTECTED_REASON);
		assert.equal(toolCallReason("bash", { command: `cat ${join(home, ".pi/agent/auth.json")}` }, cwd, where), undefined);
		assert.equal(toolCallReason("read", { path: "note.txt" }, cwd, where), undefined);
		assert.equal(toolCallReason("write", { path: "~/Documents/b.txt", content: join(support, "memory.md") }, cwd, where), undefined, "content is no path");
		assert.equal(toolCallReason("mcp__pippa__mail_search", { from: "../memory.md", query: "x" }, cwd, where), undefined, "a mail sender is no path");
		assert.deepEqual(namedPaths({ path: "a", to: "trash" }, cwd), [join(cwd, "a")]);
	} finally { await rm(home, { recursive: true, force: true }); }
});

test("sandbox: no reading or writing in protected places with any grant; the working folder and the person's files work", { skip: !onMac && "macOS only" }, async () => {
	const { home, support, env, where } = await fixture();
	const work = join(support, "pi-work");
	try {
		const profile = sandboxProfile(new Set(["net", "write"]), places(work, env, home, where));
		assert.deepEqual(profile.trim().split("\n").slice(-2), sandboxRules(where), "the protected rules come last");
		const run = (command) => { try { return execFileSync("/usr/bin/sandbox-exec", ["-p", profile, "/bin/bash", "-c", command], { cwd: work, encoding: "utf8", stdio: "pipe" }); } catch (error) { return `FAILED ${error.stderr}`; } };
		for (const command of [`cat "$HOME/.pi/agent/auth.json"`, "cat alias.json", `cat ../inference-settings.json`, `ls "${support}"`,
			`cat "/System/Volumes/Data${home}/.PI/agent/auth.json"`, `ln "${home}/.pi/agent/auth.json" hard`, `printf x > ../inference-settings.json`,
			`cat "${home}/Documents/sessions/x" 2>&1 >/dev/null; ls "${home}/Documents/sessions/"`]) {
			assert.match(run(`HOME="${home}"; ${command}`), /FAILED .*Operation not permitted/, command);
		}
		assert.equal(run(`printf ok > new.txt && cat new.txt note.txt "${home}/Documents/a.txt"`), "okokok");
	} finally { await rm(home, { recursive: true, force: true }); }
});

test("fetch with a body: a redirect comes back as an error and the other address gets nothing; GET and plain answers unchanged", async () => {
	let other = 0;
	const b = createServer((req, res) => { other++; res.end("B"); });
	b.on("connection", () => { other++; });
	const a = createServer((req, res) => {
		if (req.url === "/ok") { res.writeHead(200, { "Content-Type": "text/plain" }); res.write("str"); res.end("eam"); return; }
		res.writeHead(Number(req.url.slice(1)), { Location: `${baseB}/x` }); res.end();
	});
	const listen = (server) => new Promise((resolve) => server.listen(0, "127.0.0.1", () => resolve(`http://127.0.0.1:${server.address().port}`)));
	const baseA = await listen(a), baseB = await listen(b);
	try {
		const fetch = guardFetch(globalThis.fetch);
		for (const status of [301, 302, 303, 307, 308]) {
			const response = await fetch(`${baseA}/${status}`, { method: "POST", body: "conversation", headers: { "x-api-key": "fixture" } });
			assert.equal(response.status, 400, String(status));
			assert.match((await response.json()).error.message, new RegExp(`HTTP ${status}`));
			const request = await fetch(new Request(`${baseA}/${status}`, { method: "POST", body: "conversation" }));
			assert.equal(request.status, 400, `Request object, ${status}`);
		}
		assert.equal(other, 0, "B received nothing");
		assert.equal(await (await fetch(`${baseA}/ok`, { method: "POST", body: "x" })).text(), "stream");
		assert.equal(await (await fetch(`${baseA}/307`)).text(), "B", "a GET still follows");
		const target = { fetch: globalThis.fetch };
		refuseRedirects(target);
		const replaced = async () => new Response("later");
		target.fetch = replaced;
		assert.notEqual(target.fetch, replaced, "a later replacement is wrapped too");
		refuseRedirects(target);
		assert.equal(await (await target.fetch("http://x.invalid/", { method: "POST", body: "x" })).text(), "later");
	} finally {
		for (const server of [a, b]) { server.closeAllConnections(); await new Promise((resolve) => server.close(resolve)); }
	}
});

test("the designated work exception requires the original directory entry", async () => {
	const { home, support, env, where } = await fixture();
	const work = env.PIPPA_WORK_DIR, sessions = join(support, "pi-sessions");
	try {
		assert.equal(isProtected(join(work, "note.txt"), where), false);
		await rename(work, work + "-old");
		await symlink(sessions, work);
		assert.equal(isProtected(join(sessions, "private.txt"), where), true, "live rules reject a substituted symlink");
		assert.equal(isProtected(join(work, "private.txt"), protection(env, home)), true, "startup also rejects a substituted symlink");
		assert.ok(!sandboxProfile(new Set(), places(work, env, home, where)).split("\n")
			.some((line) => line.startsWith("(allow file-") && line.includes(sessions)));
		await rm(work);
		await mkdir(work);
		assert.equal(isProtected(join(work, "note.txt"), where), true, "a new directory at the same name is closed");
		const pinned = protection({ ...env, PIPPA_WORK_ID: where.open[0].id }, home);
		assert.equal(isProtected(join(work, "note.txt"), pinned), true, "the app's launch identity cannot be recaptured after a swap");
	} finally { await rm(home, { recursive: true, force: true }); }
});
