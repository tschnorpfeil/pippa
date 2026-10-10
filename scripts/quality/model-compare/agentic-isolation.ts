// Loaded after Pippa's extensions in the agentic comparison: tools may only touch the generated fake HOME and the
// bundled skills. Pippa's MCP tools all go to the harness's mock server, so they may run. `search_files` only searches the fake HOME
// (search.mjs reads CFFIXED_USER_HOME). Bash: only plain read-only commands without redirection, inside the fake HOME (no policy.ts dependency, so
// it works before and after the guard removal).
import { resolve } from 'node:path';
const LOOK = new Set(['ls', 'cat', 'head', 'tail', 'find', 'grep', 'wc', 'sort', 'file', 'stat', 'date', 'pwd', 'echo', 'mdfind', 'mdls', 'pdftotext']);
export default function(pi: any) {
 pi.on('tool_call', (event: any, ctx: any) => {
  const home = process.env.CFFIXED_USER_HOME!;
  const skills = process.env.PIPPA_FIXTURE_SKILLS!;
  const path = (p = '.') => resolve(ctx.cwd, p === '~' ? home : p.startsWith('~/') ? home + p.slice(1) : p);
  const inside = (p: string) => path(p).startsWith(home + '/');
  const args = event.input ?? {};
  if (event.toolName.startsWith('mcp__pippa__')) return;
  if (event.toolName === 'read' && (inside(args.path) || path(args.path).startsWith(skills + '/'))) return;
  if (['find', 'ls', 'grep', 'list_folder'].includes(event.toolName) && inside(args.path ?? '.')) return;
  if (event.toolName === 'search_files') return;
  if (['write', 'edit'].includes(event.toolName) && inside(args.path)) return;
  if (event.toolName === 'bash') {
   const command = String(args.command ?? '').trim();
   const plain = !/[>;&`$\\]|\.\./.test(command.replace(/2>\/dev\/null/g, ''));
   const look = command.split('|').every(part => LOOK.has(part.trim().split(/\s+/)[0]));
   const outside = [...command.replaceAll(home, 'FIXTURE').matchAll(/(?:^|[\s"'(])\/[^\s"')|;]*/g)].some(m => m[0].trim().replace(/^["'(]/, '') !== '/dev/null');
   if (plain && look && !outside) return;
  }
  return { block: true, reason: 'Fixture isolation: only generated files and the bundled skills may be used.' };
 });
}
