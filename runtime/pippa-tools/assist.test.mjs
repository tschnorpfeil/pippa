// Helps for small models (pippa-assist.ts) without Pi and without a model: a stand-in `pi` takes the handlers, the
// tests call `tool_call` and `tool_result` like Pi itself.
//
//   node --experimental-strip-types --test runtime/pippa-tools/assist.test.mjs
import assert from "node:assert/strict";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const { default: assist } = await import("./pippa-assist.ts");
const { isFileSearch } = await import("./search-command.ts");
const builtin = (name) => ({ name, sourceInfo: { path: `builtin:${name}`, source: "builtin" } });
const tools = ["read", "write", "edit", "bash"].map(builtin);

test("bundled Spotlight script is recognised exactly; shell injection and other scripts are not", () => {
	const script = fileURLToPath(new URL("../pippa-skills/dateien-finden/scripts/search.mjs", import.meta.url));
	assert.ok(isFileSearch(`node "${script}" --query "Zahnarzt" --year 2023`));
	for (const cmd of [
		`node /tmp/search.mjs --query Steuer`,
		`node "${script}" --query "$(touch x)"`,
		`node "${script}" --query Steuer; touch x`,
		`node "${script}" --query Steuer --year 2023 --eval evil`,
		`node "${script}" --query Steuer > x`,
		`node "${script}" --query Steuer\nrm x`,
	]) assert.ok(!isFileSearch(cmd), cmd);
});

test("loop brake: an identical call stops after two failures or four runs; other arguments still run", async () => {
	const { loopBrake } = await import("./pippa-assist.ts");
	const counts = new Map(), keys = new Map();
	const input = { time: "18:00", title: "Müll" };
	// A change that worked once is not done twice.
	const c0 = new Map(), k0 = new Map();
	assert.equal(loopBrake(c0, k0, "a1", "mcp__pippa__reminder_add", { title: "Müll" }, true), undefined);
	c0.get(k0.get("a1")).successes++;
	assert.match(loopBrake(c0, k0, "a2", "mcp__pippa__reminder_add", { title: "Müll" }, true), /would make a duplicate/);
	const ran = [];
	for (let i = 0; i < 4; i++) {
		const stop = loopBrake(counts, keys, `f${i}`, "mcp__pippa__reminder_add", input);
		ran.push(!stop);
		if (!stop) counts.get(keys.get(`f${i}`)).failures++;
	}
	assert.deepEqual(ran, [true, true, false, false]);
	assert.match(loopBrake(counts, keys, "f9", "mcp__pippa__reminder_add", input), /already failed 2 times/);
	const c2 = new Map(), k2 = new Map();
	const reads = Array.from({ length: 6 }, (_, i) => !loopBrake(c2, k2, `r${i}`, "read", { path: "a.txt" }));
	assert.deepEqual(reads, [true, true, true, true, false, false]);
	assert.equal(loopBrake(c2, k2, "r9", "read", { path: "b.txt" }), undefined);
});

test("read on a document is sent to read_document; text files and other tools pass", async () => {
	const { documentForRead } = await import("./pippa-assist.ts");
	assert.match(documentForRead("read", { path: "/x/Rechnung Elektro.pdf" }), /mcp__pippa__read_document/);
	assert.match(documentForRead("read", { path: "Scan.JPG" }), /read_document/);
	assert.match(documentForRead("read", { path: "a/Brief.docx" }), /read_document/);
	assert.equal(documentForRead("read", { path: "termine.txt" }), undefined);
	assert.equal(documentForRead("read", { path: "notizen.md" }), undefined);
	assert.equal(documentForRead("mcp__pippa__read_document", { path: "a.pdf" }), undefined);
});

test('loop stop is distinct from manual Stop and preserves actual search locations', async () => {
 const handlers={},entries=[];let aborted=0;
  assist({on:(name,fn)=>handlers[name]=fn,getAllTools:()=>tools,appendEntry:(type,data)=>entries.push({type,data})});
 const ctx={abort:()=>aborted++};
 await handlers.agent_start({});
 const input={command:'mdfind -onlyin ~/Documents Kaution'};
 for(let i=0;i<7;i++){
  const event={toolName:'bash',input,toolCallId:'search'+i};
  const block=await handlers.tool_call(event,ctx);
  if(!block)await handlers.tool_result({...event,isError:false,content:[{type:'text',text:'/fake/Documents/beleg.pdf\n'}]},ctx);
 }
 const stops=entries.filter(x=>x.type==='pippa-loop-stop');
 assert.equal(aborted,1);assert.equal(stops.length,1);
 assert.deepEqual(stops[0].data.files,['/fake/Documents/beleg.pdf']);
 assert.equal(stops[0].data.searched,true);
 await handlers.agent_start({});
 for(let i=0;i<7;i++){
  const event={toolName:'bash',input,toolCallId:'empty'+i};
  const block=await handlers.tool_call(event,ctx);
  if(!block)await handlers.tool_result({...event,isError:false,content:[{type:'text',text:''}]},ctx);
 }
 assert.deepEqual(entries.filter(x=>x.type==='pippa-loop-stop').at(-1).data.files,[]);
});

test('verified search results are signalled only for the bundled script, not model-written JSON', async () => {
 const handlers={},entries=[];
  assist({on:(name,fn)=>handlers[name]=fn,getAllTools:()=>tools,appendEntry:(type,data)=>entries.push({type,data})});
 const ctx={};
 const script=fileURLToPath(new URL('../pippa-skills/dateien-finden/scripts/search.mjs',import.meta.url));
 const result={isError:false,content:[{type:'text',text:JSON.stringify({files:[{path:'/fake/Documents/beleg.pdf'}]})}]};
 await handlers.tool_call({toolName:'bash',toolCallId:'real',input:{command:`node "${script}" --query Kaution`}},ctx);
 await handlers.tool_result({...result,toolName:'bash',toolCallId:'real'},ctx);
 await handlers.tool_call({toolName:'bash',toolCallId:'fake',input:{command:'echo result'}},ctx);
 await handlers.tool_result({...result,toolName:'bash',toolCallId:'fake'},ctx);
 const found=entries.filter(e=>e.type==='pippa-search-result');
 assert.equal(found.length,1);assert.deepEqual(found[0].data.files,['/fake/Documents/beleg.pdf']);
});

test('loop stop preserves the search truncation flag with exactly 200 returned files', async () => {
 const handlers={},entries=[];
  assist({on:(name,fn)=>handlers[name]=fn,getAllTools:()=>tools,appendEntry:(type,data)=>entries.push({type,data})});
 const ctx={abort:()=>{}};
 const script=fileURLToPath(new URL('../pippa-skills/dateien-finden/scripts/search.mjs',import.meta.url));
 const input={command:`node "${script}" --query Steuer`};
 for(const truncated of [true,false]){
  await handlers.agent_start({});
  const files=truncated?Array.from({length:200},(_,i)=>({path:`/fake/Documents/${i}.pdf`})) : [];
  for(let i=0;i<7;i++){
   const event={toolName:'bash',input,toolCallId:`cap-${truncated}-${i}`};
   if(!await handlers.tool_call(event,ctx))await handlers.tool_result({...event,isError:false,content:[{type:'text',text:JSON.stringify({files,truncated})}]},ctx);
  }
  const stop=entries.filter(x=>x.type==='pippa-loop-stop').at(-1).data;
  assert.equal(stop.files.length,files.length);assert.equal(stop.truncated,truncated);
 }
});

test("today's date goes in front of each new message, a skill command stays first, steering stays as typed", async () => {
	const { todayLine, withToday } = await import("./pippa-assist.ts");
	const day = new Date(2026, 9, 9, 23, 30);
	assert.equal(todayLine(day, "de"), "Heute ist Freitag, 9. Oktober 2026.");
	assert.equal(todayLine(day, "en"), "Today is Friday, 9 October 2026.");
	assert.equal(todayLine(day), "Heute ist Freitag, 9. Oktober 2026.", "German without a language");
	const line = "Heute ist Freitag, 9. Oktober 2026.";
	assert.equal(withToday("Wie wird das Wetter morgen?", line), `${line}\nWie wird das Wetter morgen?`);
	assert.equal(withToday("/skill:fristen-erkennen Welche Fristen?\nmehr", line), `/skill:fristen-erkennen ${line}\nWelche Fristen?\nmehr`);
	assert.equal(withToday("/skill:stichpunkte", line), `/skill:stichpunkte ${line}`);
	assert.equal(withToday("/andere Vorlage", line), "/andere Vorlage");
	const handlers = {};
	assist({ on: (name, handler) => (handlers[name] = handler), registerTool() {}, getAllTools: () => tools, appendEntry() {} });
	const sent = await handlers.input({ type: "input", text: "Hallo", source: "rpc" });
	assert.equal(sent.action, "transform");
	assert.match(sent.text, /^Heute ist \S+, \d+\. \S+ \d{4}\.\nHallo$/);
	assert.deepEqual(await handlers.input({ type: "input", text: "Stopp", source: "rpc", streamingBehavior: "steer" }), { action: "continue" });
});
