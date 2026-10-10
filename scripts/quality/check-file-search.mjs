// Real Spotlight against generated PDFs only: content vs filename/year, all five scopes.
import assert from 'node:assert/strict';
import { search, predicate } from '../../runtime/pippa-tools/search.mjs';
import { join } from 'node:path';
const home=process.env.CFFIXED_USER_HOME;
if (!home?.endsWith('/pippa/dist/tool-search-home')) throw Error('Generate the isolated search corpus first.');
const cases=[['Steuer','2025',['Documents/f.pdf','Library/Mobile Documents/com~apple~CloudDocs/d.pdf','Library/CloudStorage/TestDrive/e.pdf']],['Kaution',undefined,['Desktop/b.pdf']],['Hausratversicherung',undefined,['Library/Mobile Documents/com~apple~CloudDocs/d.pdf']],['Zahnarzt','2023',['Documents/a.pdf']],['Nebenkostenabrechnung','2024',['Downloads/c.pdf']],['Mietvertrag',undefined,['Desktop/b.pdf']],['Zahnarzt','2024',['Documents/g.pdf']],['Zahnarzt','2022',[]]];
const results=[];
for(const [query,year,expected] of cases){
 const start=performance.now();const result=await search(query,year);
 assert.equal(result.status,'ok');assert.equal(result.searched.length,5);
 assert.deepEqual(result.files.map(f=>f.path).sort(),expected.map(p=>join(home,p)).sort());
 results.push({query,year,milliseconds:Math.round(performance.now()-start),files:result.files.length});
}
assert.throws(()=>predicate('Steuer','2023; rm x'));
const missing=await search('Steuer','2025',join(home,'missing-home'));
assert.equal(missing.status,'unavailable');assert.equal(missing.unavailable.length,5);
console.log(JSON.stringify({passed:results.length,results},null,2));
