// The app ships only the extension sources listed in app/Packaging/runtime-files.json. A shipped file that imports one left out
// makes Pi fail to start in the app, while every test here still passes.
//
//   node --experimental-strip-types --test runtime/pippa-tools/packaging.test.mjs
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const here = fileURLToPath(new URL(".", import.meta.url));
const repo = join(here, "../..");

function script(name) {
	return readFileSync(join(repo, "scripts", name), "utf8");
}

const lists = JSON.parse(readFileSync(join(repo, "app/Packaging/runtime-files.json"), "utf8"));
const files = lists["pippa-tools"];
const relativeImports = (source) =>
	[...source.matchAll(/(?:\bfrom|\bimport\s*\()\s*["']\.\/([^"']+\.(?:ts|mjs))["']/g)].map(([, target]) => target);

test("every relative import of a shipped extension is shipped too, and build-app.sh and verify-app.sh use the same list", () => {
	assert.ok(files.includes("pippa-tools.ts"), "no list of Pi extensions in runtime-files.json");
	for (const name of ["build-app.sh", "verify-app.sh"]) {
		assert.match(script(name), /for f in \$\(runtime_files pippa-tools\); do/, `scripts/${name} does not read the list of Pi extensions`);
	}
	for (const file of files) {
		for (const target of relativeImports(readFileSync(join(here, file), "utf8"))) {
			assert.ok(files.includes(target), `${file} imports ./${target}, which app/Packaging/runtime-files.json does not ship`);
		}
	}
});

test("the terminal extension ships every file it imports, and bundle-pi-payload.sh and verify-app.sh use the same list", () => {
	const terminal = lists["pippa-local-server"];
	const dir = join(repo, "runtime/pippa-local-server");
	assert.ok(terminal.includes("index.ts"), "no list of the terminal extension in runtime-files.json");
	for (const name of ["bundle-pi-payload.sh", "verify-app.sh"]) {
		assert.match(script(name), /for f in \$\(runtime_files pippa-local-server\); do/, `scripts/${name} does not read the terminal extension's list`);
	}
	for (const file of terminal) {
		for (const target of relativeImports(readFileSync(join(dir, file), "utf8"))) {
			assert.ok(terminal.includes(target), `pippa-local-server/${file} imports ./${target}, which app/Packaging/runtime-files.json does not ship`);
		}
	}
});

test("both copies of context-guard.mjs are the same, ship in both lists and import nothing", () => {
	const app = readFileSync(join(here, "context-guard.mjs"));
	const terminal = readFileSync(join(repo, "runtime/pippa-local-server/context-guard.mjs"));
	assert.ok(app.equals(terminal), "runtime/pippa-tools/context-guard.mjs and runtime/pippa-local-server/context-guard.mjs differ; copy one over the other");
	assert.ok(files.includes("context-guard.mjs") && lists["pippa-local-server"].includes("context-guard.mjs"), "context-guard.mjs is not shipped with both extensions");
	assert.doesNotMatch(app.toString("utf8"), /^\s*import\s|\bimport\s*\(|\brequire\s*\(/m, "context-guard.mjs must stay free of imports");
});
