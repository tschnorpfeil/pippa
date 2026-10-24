// The current web declarations, with deterministic saved pages from tasks.mjs.
// No real network search or browser access is performed by the model.
import { readFileSync } from 'node:fs';
export default function(pi: any) {
 const schemas = JSON.parse(readFileSync(process.env.PIPPA_FIXTURE_WEB_SCHEMA!, 'utf8'));
 for (const [name, definition] of Object.entries(schemas) as any) {
  pi.registerTool({ name, label: name, ...definition, async execute(_id: string, args: any) {
   const names = name === 'fetch_content' ? (args.urls ?? [args.url]) : (args.queries ?? [args.query]);
   const results = [];
   for (const value of names) {
    const response = await fetch(process.env.PIPPA_MCP_URL!.replace(/\/mcp$/, '/fixture-web'), {
     method: 'POST', headers: { 'content-type': 'application/json' },
     body: JSON.stringify({ name: name === 'fetch_content' ? 'read_web_page' : 'web_search',
      args: name === 'fetch_content' ? { url: value } : { query: value } }),
    });
    if (!response.ok) throw new Error(`Fixture web returned ${response.status}`);
    results.push(await response.json());
   }
   return { content: results.flatMap(r => r.content), details: { fixture: true } };
  } });
 }
}
