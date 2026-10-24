#!/usr/bin/env node
// Spotlight's existing index; no own crawler, index, OCR or model.
// A word matches a file's content, its name, or the name of a folder it lies in ("die PDF meines Kinderbuchs" finds
// ~/projects/Kinderbuch/Gesamt.pdf). The whole home folder counts, except hidden folders, ~/Library (iCloud Drive and
// cloud drives aside) and app or library packages.
import { execFile } from 'node:child_process';
import { access, stat } from 'node:fs/promises';
import { constants } from 'node:fs';
import { homedir } from 'node:os';
import { join, resolve, basename, extname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';

/** File types a person names ("die PDF", "das Foto"): they rank matching files first and are no search word. */
export const KINDS = {
 pdf: ['pdf'],
 image: ['jpg', 'jpeg', 'png', 'heic', 'heif', 'gif', 'tif', 'tiff', 'webp', 'bmp'],
 word: ['doc', 'docx', 'pages', 'odt', 'rtf'],
 excel: ['xls', 'xlsx', 'xlsm', 'numbers', 'csv', 'ods'],
 presentation: ['ppt', 'pptx', 'key', 'odp'],
 text: ['txt', 'md', 'rtf'],
 video: ['mov', 'mp4', 'm4v'],
 audio: ['mp3', 'm4a', 'wav', 'aiff'],
};
const KIND_WORDS = {
 pdf: 'pdf', pdfs: 'pdf',
 foto: 'image', fotos: 'image', bild: 'image', bilder: 'image', photo: 'image', photos: 'image', image: 'image', images: 'image', picture: 'image', jpg: 'image', jpeg: 'image', png: 'image', heic: 'image',
 docx: 'word', word: 'word', excel: 'excel', xlsx: 'excel', powerpoint: 'presentation', pptx: 'presentation', keynote: 'presentation',
 video: 'video', videos: 'video', film: 'video',
};
/** Words that say "a file" and nothing about which one. */
const GENERIC = new Set(['datei', 'dateien', 'dokument', 'dokumente', 'unterlagen', 'file', 'files', 'document', 'documents', 'ordner', 'folder']);
const CLOUD = ['Library/Mobile Documents/', 'Library/CloudStorage/'];
/** Packages and tool folders: their insides are no documents of the person. */
const SKIP_PARTS = /^(node_modules|__pycache__)$|\.(app|photoslibrary|musiclibrary|tvlibrary|photolibrary|bundle|framework|plugin|xcodeproj|xcworkspace|xcassets|lproj)$/i;
const MAX_FOLDERS = 10;

/** "Kinderbuchs" → "kinderbuch", "Rechnungen" → "rechnung": prefix and part matches then also find other forms. */
export function stem(word) {
 const w = word.toLowerCase();
 if (/\d/.test(w)) return w;
 if (w.length >= 7 && /(en|es)$/.test(w)) return w.slice(0, -2);
 if (w.length >= 6 && w.endsWith('s')) return w.slice(0, -1);
 return w;
}

/** The search words (stemmed) and a named file type, from the model's query. */
export function parseQuery(query, kind) {
 const raw = query.match(/[\p{L}\p{N}]+/gu) ?? [];
 if (!raw.length || raw.length > 8) throw Error('Ein Thema mit 1 bis 8 Wörtern ist nötig.');
 let named = kind ? (KINDS[kind.toLowerCase()] ? kind.toLowerCase() : KIND_WORDS[kind.toLowerCase()]) : undefined;
 const words = [];
 for (const word of raw) {
  const lower = word.toLowerCase();
  if (KIND_WORDS[lower]) named ??= KIND_WORDS[lower];
  else if (!GENERIC.has(lower)) words.push(stem(word));
 }
 // "PDF" alone, or only generic words: then they are the topic after all.
 if (!words.length) words.push(...raw.map(stem));
 return { words: [...new Set(words)], kind: named };
}

// Two unambiguous document categories in Pippa's supported languages. Keep every other query word literal;
// broad translations (for example "bill") could silently change the subject or a person's name.
const CATEGORY_TERMS = [['rechnung', 'invoice', 'invoic'], ['versicherung', 'insurance']];
const terms = word => CATEGORY_TERMS.find(group => group.includes(word)) ?? [word];
const named = (name, word) => terms(word).some(term => name.includes(term));
const clause = word => `(${terms(word).flatMap(term => [`kMDItemTextContent == "${term}*"cd`, `kMDItemFSName == "*${term}*"cd`]).join(' || ')})`;
const yearClause = year => `kMDItemTextContent == "${year}"cd`;

function checkYear(year) {
 if (year !== undefined && !/^\d{4}$/.test(year)) throw Error('Das Jahr muss vierstellig sein.');
}

/** Spotlight query for files: every word in the content or the name; the year in the content. */
export function predicate(query, year, kind) {
 checkYear(year);
 const { words } = parseQuery(query, kind);
 return [...words.map(clause), ...(year ? [yearClause(year)] : [])].join(' && ');
}

/** Spotlight query for folders whose name holds at least one of the words. */
export function folderPredicate(words) {
 return `kMDItemContentType == "public.folder" && (${[...new Set(words.flatMap(terms))].map(w => `kMDItemFSName == "*${w}*"cd`).join(' || ')})`;
}

/** Inside home and meant for the person: no hidden parts, no Library outside the cloud drives, no package insides. */
export function personal(path, home) {
 if (!path.startsWith(home + '/')) return false;
 const rel = path.slice(home.length + 1);
 const parts = rel.split('/');
 if (parts.some(p => !p || p.startsWith('.'))) return false;
 if (parts[0] === 'Library' && !CLOUD.some(c => rel.startsWith(c))) return false;
 return !parts.some(p => SKIP_PARTS.test(p));
}

function mdfind(args) {
 return new Promise(done => execFile('/usr/bin/mdfind', args, { timeout: 30000, maxBuffer: 16 * 1024 * 1024 }, (error, stdout) => done({ stdout: String(stdout ?? ''), error })));
}

export async function search(query, year, home = process.env.CFFIXED_USER_HOME || homedir(), { kind, run = mdfind } = {}) {
 checkYear(year);
 const parsed = parseQuery(query, kind);
 const { words } = parsed;
 const searched = [], unavailable = [];
 try { if (!(await stat(home)).isDirectory()) throw Error('kein Ordner'); await access(home, constants.R_OK); searched.push(home); }
 catch (e) { unavailable.push({ folder: home, reason: e.code === 'ENOENT' ? 'nicht vorhanden' : 'nicht zugänglich' }); }
 if (!searched.length) return { status: 'unavailable', files: [], searched, unavailable };
 // Folders macOS guards separately: say when Pippa may not look inside.
 for (const name of ['Documents', 'Desktop', 'Downloads']) {
  try { await access(join(home, name), constants.R_OK); } catch (e) { if (e.code !== 'ENOENT') unavailable.push({ folder: join(home, name), reason: 'nicht zugänglich' }); }
 }
 const split = stdout => [...new Set(stdout.split('\0').filter(Boolean))].filter(p => personal(p, home));
 const failures = [];
 const find = async (where, query) => {
  const result = await run(['-0', '-onlyin', where, query]);
  if (result.error) failures.push(result.error);
  return split(result.stdout);
 };
 const extra = year ? [yearClause(year)] : [];
 const [direct, folderHits] = await Promise.all([
  find(home, [...words.map(clause), ...extra].join(' && ')),
  find(home, folderPredicate(words)),
 ]);
 // Shallow folders first; a folder inside another hit is covered by it.
 const folders = folderHits.sort((a, b) => a.split('/').length - b.split('/').length || a.localeCompare(b))
  .filter((f, i, all) => !all.slice(0, i).some(o => f.startsWith(o + '/'))).slice(0, MAX_FOLDERS);
 const inside = await Promise.all(folders.map(folder => {
  const name = basename(folder).toLowerCase();
  const rest = words.filter(w => !named(name, w));
  return find(folder, [...rest.map(clause), ...extra].join(' && ') || 'kMDItemFSName == "*"');
 }));
 const paths = [...new Set([...direct, ...inside.flat()])];
 const kindExt = parsed.kind ? KINDS[parsed.kind] : [];
 const files = [];
 for (const path of paths) {
  try {
   const info = await stat(path);
   if (!info.isFile()) continue;
   const name = basename(path).toLowerCase();
   files.push({ name: basename(path), path, kind: kindExt.includes(extname(name).slice(1)) ? 1 : 0, named: words.filter(w => named(name, w)).length, time: info.mtimeMs });
  } catch { unavailable.push({ folder: path, reason: 'Treffer nicht mehr zugänglich' }); }
 }
 // Named type first, then the more words in the name, then the newest.
 files.sort((a, b) => b.kind - a.kind || b.named - a.named || b.time - a.time || a.path.localeCompare(b.path));
 const error = failures[0];
 return { status: error ? 'failed' : 'ok', query, year, ...(parsed.kind ? { kind: parsed.kind } : {}),
  files: files.slice(0, 200).map(({ name, path }) => ({ name, path })), total: files.length, truncated: files.length > 200, searched, unavailable,
  ...(error ? { error: error.killed ? 'Die Suche wurde nach 30 Sekunden angehalten; vorhandene Funde stehen oben.' : 'Die Dateisuche konnte nicht vollständig ausgeführt werden; vorhandene Funde stehen oben.' } : {}),
  note: 'Sucht Inhalt, Dateinamen und Ordnernamen im Benutzerordner und in iCloud Drive. Nicht geladene Cloud-Dateien, nicht erfasste Dateien und Scans ohne erkannten Text können fehlen.' };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
 try {
  const { values } = parseArgs({ options: { query: { type: 'string' }, year: { type: 'string' }, kind: { type: 'string' } } });
  const result = await search(values.query ?? '', values.year, undefined, { kind: values.kind });
  console.log(JSON.stringify(result));
  if (result.status !== 'ok') process.exitCode = 1;
 } catch (e) { console.log(JSON.stringify({ status: 'failed', error: e.message, files: [] })); process.exitCode = 1; }
}
