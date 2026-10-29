// The app ships only the extension sources listed in scripts/build-app.sh. A shipped file that imports one left out
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

function shipped(script) {
	const text = readFileSync(join(repo, "scripts", script), "utf8");
	const list = text.match(/for f in ([^;\n]*pippa-policy\.ts[^;\n]*); do/)?.[1];
	assert.ok(list, `no list of Pi extensions in scripts/${script}`);
	return list.trim().split(/\s+/);
}

test("every relative import of a shipped extension is shipped too, and verify-app.sh checks the same files", () => {
	const files = shipped("build-app.sh");
	assert.deepEqual(shipped("verify-app.sh"), files);
	for (const file of files) {
		const source = readFileSync(join(here, file), "utf8");
		for (const [, target] of source.matchAll(/(?:\bfrom|\bimport\s*\()\s*["']\.\/([^"']+\.(?:ts|mjs))["']/g)) {
			assert.ok(files.includes(target), `${file} imports ./${target}, which scripts/build-app.sh does not ship`);
		}
	}
	assert.ok(files.includes("skill-save.ts"), "pippa-memory.ts installs save_skill from skill-save.ts");
});
