// Loaded BEFORE any tool can execute in the live search evaluation.
import { classifyCommand } from './command-kind.ts';
import { resolve } from 'node:path';
export default function(pi: any) {
 pi.on('tool_call', (event: any, ctx: any) => {
  const home = process.env.CFFIXED_USER_HOME!;
  const path = (p = '.') => resolve(ctx.cwd, p === '~' ? home : p.startsWith('~/') ? home + p.slice(1) : p);
  const inside = (p: string) => path(p).startsWith(home + '/');
  const args = event.input;
  if (event.toolName === 'read' && (inside(args.path) || path(args.path).startsWith(process.env.PIPPA_FIXTURE_SKILLS + '/'))) return;
  if (['find', 'ls', 'grep', 'list_folder'].includes(event.toolName) && inside(args.path)) return;
  // search_files only searches under CFFIXED_USER_HOME (search.mjs).
  if (event.toolName === 'search_files') return;
  if (event.toolName === 'mcp__pippa__read_document' && inside(args.path)) return;
  if (event.toolName === 'bash') {
   const command = String(args.command ?? '');
   const outside = [...command.replaceAll(home, 'FIXTURE').matchAll(/(?:^|[\s"'(])\/[^\s"')|;]*/g)].some(m => m[0].trim().replace(/^["'(]/, '') !== '/dev/null');
   if (classifyCommand(command) === 'look' && !outside && !command.includes('..') && !command.includes('/usr/bin/mdfind') && !command.includes('$') && !command.includes('`')) return;
  }
  return {block: true, reason: 'Fixture isolation: only generated files and the bundled skills may be read.'};
 });
}
