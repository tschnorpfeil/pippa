#!/usr/bin/env node
// Spotlight's existing content index; no own crawler, index, OCR or model.
import { execFile } from 'node:child_process';
import { access, stat } from 'node:fs/promises';
import { constants } from 'node:fs';
import { homedir } from 'node:os';
import { join, resolve, basename } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';

export function predicate(query, year) {
 const words = query.match(/[\p{L}\p{N}]+/gu) ?? [];
 if (!words.length || words.length > 8) throw Error('Ein Thema mit 1 bis 8 Wörtern ist nötig.');
 if (year !== undefined && !/^\d{4}$/.test(year)) throw Error('Das Jahr muss vierstellig sein.');
 const terms = words.map(word => `kMDItemTextContent == "${word}*"cd`);
 if (year) terms.push(`kMDItemTextContent == "${year}"cd`);
 return terms.join(' && ');
}

export async function search(query, year, home = process.env.CFFIXED_USER_HOME || homedir()) {
 const folders = ['Documents', 'Desktop', 'Downloads', 'Library/Mobile Documents/com~apple~CloudDocs', 'Library/CloudStorage'].map(p => join(home, p));
 const searched = [], unavailable = [];
 for (const folder of folders) {
  try { if (!(await stat(folder)).isDirectory()) throw Error('kein Ordner'); await access(folder, constants.R_OK); searched.push(folder); }
  catch (e) { unavailable.push({folder, reason: e.code === 'ENOENT' ? 'nicht vorhanden' : 'nicht zugänglich'}); }
 }
 const where = predicate(query, year);
 if (!searched.length) return {status:'unavailable', files:[], searched, unavailable};
 const args = ['-0', ...searched.flatMap(folder => ['-onlyin', folder]), where];
 const { stdout, error } = await new Promise(done => execFile('/usr/bin/mdfind', args, {timeout:30000, maxBuffer:16*1024*1024}, (error, stdout) => done({stdout, error})));
 const paths = [...new Set(stdout.split('\0').filter(Boolean))].filter(p => searched.some(folder => p.startsWith(folder + '/'))).sort();
 const files = [];
 for (const path of paths) {
  try { if ((await stat(path)).isFile()) files.push({name:basename(path), path}); } catch { unavailable.push({folder:path, reason:'Treffer nicht mehr zugänglich'}); }
 }
 return {status:error ? 'failed' : 'ok', query, year, files:files.slice(0,200), total:files.length, truncated:files.length>200, searched, unavailable,
  ...(error ? {error: error.killed ? 'Die Suche wurde nach 30 Sekunden angehalten; vorhandene Funde stehen oben.' : 'Die Dateisuche konnte nicht vollständig ausgeführt werden; vorhandene Funde stehen oben.'} : {}),
  note:'Nur indexierte Inhalte. Nicht geladene Cloud-Dateien, nicht erfasste Dateien und Scans ohne erkannten Text können fehlen.'};
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
 try {
  const {values} = parseArgs({options:{query:{type:'string'},year:{type:'string'}}});
  const result = await search(values.query ?? '', values.year);
  console.log(JSON.stringify(result));
  if (result.status !== 'ok') process.exitCode=1;
 } catch (e) {console.log(JSON.stringify({status:'failed',error:e.message,files:[]}));process.exitCode=1;}
}
