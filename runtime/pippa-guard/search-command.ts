// Only the bundled, read-only Spotlight script with literal topic/year arguments.
// An arbitrary node command remains a network/unknown command and asks as before.
import { fileURLToPath } from 'node:url';
const script = fileURLToPath(new URL('../pippa-skills/dateien-finden/scripts/search.mjs', import.meta.url));
export function isFileSearch(command: string): boolean {
 if (/[\n\r$`\\]/.test(command)) return false;
 const token = '("[^"\\n]*"|\'[^\'\\n]*\'|[^\\s"\';&|<>]+)';
 const match = command.trim().match(new RegExp('^node\\s+' + token + '\\s+--query\\s+' + token + '(?:\\s+--year\\s+' + token + ')?$'));
 if (!match) return false;
 const unquote = (s: string) => s.startsWith('"') || s.startsWith("'") ? s.slice(1, -1) : s;
 const [, path, query, year] = match;
 return unquote(path) === script && /^[\p{L}\p{N} .,-]+$/u.test(unquote(query)) && (!year || /^\d{4}$/.test(unquote(year)));
}
