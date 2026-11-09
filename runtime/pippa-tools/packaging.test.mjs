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

const files = JSON.parse(readFileSync(join(repo, "app/Packaging/runtime-files.json"), "utf8"))["pippa-tools"];

test("every relative import of a shipped extension is shipped too, and build-app.sh and verify-app.sh use the same list", () => {
	assert.ok(files.includes("pippa-tools.ts"), "no list of Pi extensions in runtime-files.json");
	for (const name of ["build-app.sh", "verify-app.sh"]) {
		assert.match(script(name), /for f in \$\(runtime_files pippa-tools\); do/, `scripts/${name} does not read the list of Pi extensions`);
	}
	for (const file of files) {
		const source = readFileSync(join(here, file), "utf8");
		for (const [, target] of source.matchAll(/(?:\bfrom|\bimport\s*\()\s*["']\.\/([^"']+\.(?:ts|mjs))["']/g)) {
			assert.ok(files.includes(target), `${file} imports ./${target}, which app/Packaging/runtime-files.json does not ship`);
		}
	}
});
