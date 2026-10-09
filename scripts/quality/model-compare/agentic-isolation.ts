// Loaded after the guard in the agentic comparison (like fixture-isolation.ts): tools may only touch the generated
// fake HOME and the bundled skills. Pippa's MCP tools all go to the harness's mock server, so they may run.
import { isFileSearch } from '../../../runtime/pippa-guard/search-command.ts';
import { classifyCommand } from '../../../runtime/pippa-guard/policy.ts';
import { resolve } from 'node:path';
export default function(pi: any) {
 pi.on('tool_call', (event: any, ctx: any) => {
  const home = process.env.CFFIXED_USER_HOME!;
  const path = (p = '.') => resolve(ctx.cwd, p === '~' ? home : p.startsWith('~/') ? home + p.slice(1) : p);
  const inside = (p: string) => path(p).startsWith(home + '/');
  const args = event.input ?? {};
  if (event.toolName.startsWith('mcp__pippa__')) return;
  if (event.toolName === 'read' && (inside(args.path) || path(args.path).startsWith(process.env.PIPPA_FIXTURE_SKILLS + '/'))) return;
  if (['find', 'ls', 'grep', 'list_folder'].includes(event.toolName) && inside(args.path ?? '.')) return;
  if (['write', 'edit'].includes(event.toolName) && inside(args.path)) return;
  if (event.toolName === 'bash') {
   const command = String(args.command ?? '');
   if (isFileSearch(command)) return;
   const outside = [...command.replaceAll(home, 'FIXTURE').matchAll(/(?:^|[\s"'(])\/[^\s"')|;]*/g)].some(m => m[0].trim().replace(/^["'(]/, '') !== '/dev/null');
   if (classifyCommand(command) === 'look' && !outside && !command.includes('..') && !command.includes('$') && !command.includes('`')) return;
  }
  return { block: true, reason: 'Fixture isolation: only generated files and the bundled skills may be used.' };
 });
}
