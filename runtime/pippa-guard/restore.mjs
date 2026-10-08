#!/usr/bin/env node
// Restores a state from the Pippa guard's undo folder (pippa-guard.ts).
//
//   node runtime/pippa-guard/restore.mjs <folder-with-manifest.json>   restore one entry
//   node runtime/pippa-guard/restore.mjs --list [undo-root]            list entries (default: $PIPPA_UNDO_DIR)
//
// Files that existed before get their backed-up copy back; whatever is there now goes to the trash first. Files Pi
// newly created are not deleted but moved to the trash. That keeps even the restore reversible without the undo
// folder growing (the guard prunes it after 7 days).
// Trash: /usr/bin/trash (macOS 15+); for tests PIPPA_TRASH_DIR (flat, "2 Name" ... on name clashes).
// Rename, move and trash (rename_or_move, move_files, move_to_trash) have a `moves` list ({from, to}) instead of copies: restoring
// moves `to` back to `from`, never over something that exists.
// bash entries are only a log (except plain rm/mv): there is nothing to restore.
// A plain mkdir has `folders` (topmost new folders) and `created` (all new ones): a folder goes to the trash only if it
// contains nothing but those new folders (and .DS_Store); otherwise it stays, with a message.
// If all went well, restored.json is written into the entry folder (Pippa then shows no button).
// Entries with `createdItem` (event or reminder from Pippa's MCP server) can only be removed by Pippa itself.
// Pippa has the same rules in Swift (app/Sources/PippaCore/PiUndo.swift); the two change only together.
import { execFileSync } from "node:child_process";
import { copyFile, mkdir, readdir, readFile, rename, stat, writeFile } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import { tmpdir } from "node:os";

const args = process.argv.slice(2);
const present = async (path) => { try { await stat(path); return true; } catch { return false; } };
/** Move to the trash; returns the new location. */
async function toTrash(path) {
  const fake = process.env.PIPPA_TRASH_DIR;
  if (!fake) {
    const out = execFileSync("/usr/bin/trash", ["-v", path], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
    return out.match(/Moved ".*" to "(.*)"\s*$/m)?.[1] ?? "Papierkorb";
  }
  await mkdir(fake, { recursive: true });
  let target = join(fake, basename(path));
  for (let n = 2; await present(target); n++) target = join(fake, `${n} ${basename(path)}`);
  await rename(path, target);
  return target;
}
if (args[0] === "--list") {
  const root = args[1] || process.env.PIPPA_UNDO_DIR || join(tmpdir(), "pippa-undo");
  for (const name of (await readdir(root)).sort()) {
    try {
      const m = JSON.parse(await readFile(join(root, name, "manifest.json"), "utf8"));
      const what = m.tool === "bash" ? `bash: ${m.command}`
        : m.createdItem ? `${m.name} (nur in Pippa rückgängig)`
        : m.moves ? m.moves.map((x) => `${x.from} → ${x.to}`).join(", ")
        : m.entries.map((e) => e.path).join(", ");
      console.log(`${name}  ${m.tool}  ${what}`);
    } catch { /* kein Eintrag */ }
  }
  process.exit(0);
}
const dir = args[0];
if (!dir) { console.error("Aufruf: restore.mjs <eintragsordner> | --list [wurzel]"); process.exit(2); }
const manifest = JSON.parse(await readFile(join(dir, "manifest.json"), "utf8"));
if (manifest.createdItem) {
  // Event or reminder (PippaMCPWrite.swift). Removing it needs EventKit in the Pippa process (PiUndo.restoreCreated).
  console.log(`Nur in Pippa rückgängig zu machen (${manifest.tool}): ${manifest.name ?? ""}`);
  process.exit(1);
}
if (manifest.restorable === false) {
  console.log(`Nicht wiederherstellbar (${manifest.tool}): ${manifest.command ?? ""}`);
  process.exit(1);
}
let failed = false;
for (const move of manifest.moves ?? []) {
  if (!(await present(move.to))) { console.log(`nicht mehr da: ${move.to}`); failed = true; continue; }
  if (await present(move.from)) { console.log(`schon wieder belegt, nichts überschrieben: ${move.from}`); failed = true; continue; }
  await mkdir(dirname(move.from), { recursive: true });
  await rename(move.to, move.from);
  console.log(`zurückgeholt: ${move.to} → ${move.from}`);
}
/** Is there nothing in `dir` except folders from `created` (and .DS_Store)? */
async function stillEmpty(dir, created) {
  for (const name of await readdir(dir)) {
    if (name === ".DS_Store") continue;
    const path = join(dir, name);
    if (!created.includes(path) || !(await stat(path)).isDirectory() || !(await stillEmpty(path, created))) return false;
  }
  return true;
}
for (const folder of manifest.folders ?? []) {
  if (!(await present(folder))) { console.log(`schon weg: ${folder}`); continue; }
  if (!(await stillEmpty(folder, manifest.created ?? [folder]))) { console.log(`nicht leer, bleibt: ${folder}`); failed = true; continue; }
  console.log(`neu angelegter Ordner in den Papierkorb: ${folder} → ${await toTrash(folder)}`);
}
for (const entry of manifest.entries ?? []) {
  if (entry.existed) {
    if (!(await present(entry.snapshot))) { console.log(`Sicherung fehlt: ${entry.path}`); failed = true; continue; }
    if (await present(entry.path)) console.log(`jetziger Stand in den Papierkorb: ${entry.path} → ${await toTrash(entry.path)}`);
    await mkdir(dirname(entry.path), { recursive: true });
    // Clone back (cp -c, see files.ts cloneFile), otherwise copy.
    try { execFileSync("/bin/cp", ["-c", "--", entry.snapshot, entry.path], { stdio: "ignore" }); } catch { await copyFile(entry.snapshot, entry.path); }
    console.log(`zurückgespielt: ${entry.path}`);
  } else {
    if (!(await present(entry.path))) { console.log(`schon weg: ${entry.path}`); continue; }
    console.log(`neu angelegte Datei in den Papierkorb: ${entry.path} → ${await toTrash(entry.path)}`);
  }
}
if (failed) process.exit(1);
await writeFile(join(dir, "restored.json"), `${JSON.stringify({ restoredAt: new Date().toISOString(), by: "restore.mjs" })}\n`);
