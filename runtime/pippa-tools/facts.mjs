// Fact-shaped file entries for `search_files` and `list_folder` (pippa-tools.ts): name, full path, kind, size, full
// modification time, and for Markdown the `updated`/`date` from its front matter. A model judges "newest" from these
// facts, never from a date in a file name (20260820_ETF_PORTFOLIO_UPDATE.md is older than ETF-Portfolio.md with
// `updated: 2026-10-01`). Plain JavaScript so search.mjs can import it too.
import { open, readdir, stat } from 'node:fs/promises';
import { basename, extname } from 'node:path';

/** At most this many entries per result. */
export const MAX_ENTRIES = 20;

/** "2026-10-01T14:03:22+02:00": local time with its offset, to the second. */
export function isoLocal(date) {
 const pad = (n) => String(Math.trunc(Math.abs(n))).padStart(2, '0');
 const offset = -date.getTimezoneOffset();
 const sign = offset >= 0 ? '+' : '-';
 return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`
  + `${sign}${pad(offset / 60)}:${pad(offset % 60)}`;
}

const MARKDOWN = new Set(['.md', '.markdown', '.mdown', '.mkd']);
const FRONT_MATTER_LINES = 15;

/** `updated` (or else `date`) from YAML front matter within the first lines of a Markdown text; `undefined` without. */
export function frontMatterDate(text) {
 const lines = String(text).replace(/^\uFEFF/, '').split(/\r?\n/).slice(0, FRONT_MATTER_LINES);
 if (lines[0]?.trim() !== '---') return undefined;
 const found = {};
 for (const line of lines.slice(1)) {
  if (/^(---|\.\.\.)\s*$/.test(line)) break;
  const match = line.match(/^(updated|date)\s*:\s*(.+?)\s*$/i);
  if (match) found[match[1].toLowerCase()] ??= match[2].replace(/^(["'])(.*)\1$/, '$2').trim();
 }
 return found.updated || found.date || undefined;
}

/** The front-matter date of a Markdown file, reading only its first 2 KB. */
export async function markdownDate(path) {
 if (!MARKDOWN.has(extname(path).toLowerCase())) return undefined;
 let handle;
 try {
  handle = await open(path, 'r');
  const buffer = Buffer.alloc(2048);
  const { bytesRead } = await handle.read(buffer, 0, buffer.length, 0);
  return frontMatterDate(buffer.subarray(0, bytesRead).toString('utf8'));
 } catch { return undefined; } finally { await handle?.close(); }
}

/** One entry from a path and its `stat`: folders carry the number of visible items instead of a size. */
export async function entryFacts(path, info) {
 const folder = info.isDirectory();
 const entry = { name: basename(path), path, kind: folder ? 'folder' : 'file' };
 if (folder) {
  try { entry.items = (await readdir(path)).filter((name) => !name.startsWith('.')).length; } catch { /* unreadable: no count */ }
 } else entry.size = info.size;
 entry.modified = isoLocal(info.mtime);
 const updated = folder ? undefined : await markdownDate(path);
 if (updated) entry.updated = updated;
 return entry;
}

/** `stat` without throwing. */
export async function statOrUndefined(path) {
 try { return await stat(path); } catch { return undefined; }
}

/**
 * The result object from `build(count)` with as many of the first entries as fit `maxChars` as JSON (at most
 * `MAX_ENTRIES`): entries are dropped from the end, never cut, so the JSON stays whole.
 */
export function fitting(build, available, maxChars) {
 for (let count = Math.min(available, MAX_ENTRIES); count >= 0; count--) {
  const result = build(count);
  if (count === 0 || JSON.stringify(result).length <= maxChars) return result;
 }
}
