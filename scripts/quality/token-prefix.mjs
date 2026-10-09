// Tokenize the actual K2 chat template, with and without the tool declarations.
// Usage: node token-prefix.mjs <llama URL> <before payload.json> <after payload.json>
import { readFile } from 'node:fs/promises';
const [server, before, after] = process.argv.slice(2);
if (!server || !before || !after) throw Error('llama URL and two captured payloads required');
async function post(route, body) {
 const response = await fetch(`${server}/${route}`, {method:'POST', headers:{'content-type':'application/json'}, body:JSON.stringify(body)});
 if (!response.ok) throw Error(`${route}: ${response.status}`);
 return response.json();
}
const results = {};
for (const [label, path] of [['before', before], ['final', after]]) {
 const payload = JSON.parse(await readFile(path, 'utf8'));
 // Identical question, independent of which test last wrote the capture.
 payload.messages = [payload.messages.find(m => m.role === 'system'), {role:'user', content:'Hallo'}];
 const counts = {};
 for (const include of [false, true]) {
  const request = {...payload};
  if (!include) delete request.tools;
  const {prompt} = await post('apply-template', request);
  counts[include ? 'withTools' : 'withoutTools'] = (await post('tokenize', {content:prompt, add_special:false})).tokens.length;
 }
 results[label] = {tools:payload.tools.length, ...counts, toolDeclarationTokens:counts.withTools-counts.withoutTools};
}
console.log(JSON.stringify(results, null, 2));
