import { build } from 'esbuild';
import { resolve } from 'node:path';
import { mkdir, writeFile, rename } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
const root = fileURLToPath(new URL('.', import.meta.url));

// Bundled from the pinned pi-web-access, only for the own fetch process src/fetcher.mjs (search and read pages).
// Pippa's Pi extensions (runtime/pippa-guard) import nothing from it; test/fetcher.test.mjs checks that.
// The search provider is DuckDuckGo HTML; replaceable via `search` in createFetcher.
const bundles = [
  { source: 'node_modules/pi-web-access/duckduckgo.ts', name: 'duckduckgo' },
  { source: 'node_modules/pi-web-access/extract.ts', name: 'extract' },
];

await mkdir(resolve(root, 'src/generated'), { recursive: true });
for (const { source, name } of bundles) {
  const result = await build({ write: false, entryPoints: [resolve(root, source)],
    outfile: resolve(root, `src/generated/${name}.mjs`), bundle: true, packages: 'external', platform: 'node', format: 'esm',
    banner: { js: '// Generated from locked pi-web-access 0.37.0, MIT; license in node_modules/pi-web-access/LICENSE.' } });
  // Atomic swap: a running test or Pi start must never import a half-written file.
  const temporary = resolve(root, `src/generated/.${name}-${process.pid}.mjs`);
  await writeFile(temporary, result.outputFiles[0].contents);
  await rename(temporary, resolve(root, `src/generated/${name}.mjs`));
}
