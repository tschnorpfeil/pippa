// Helps for small models (pippa-assist.ts) without Pi and without a model: a stand-in `pi` takes the handlers, the
// tests call `tool_call` and `tool_result` like Pi itself.
//
//   node --experimental-strip-types --test runtime/pippa-tools/assist.test.mjs
import assert from "node:assert/strict";
import { test } from "node:test";

const { default: assist } = await import("./pippa-assist.ts");
const builtin = (name) => ({ name, sourceInfo: { path: `builtin:${name}`, source: "builtin" } });
const tools = ["read", "write", "edit", "bash"].map(builtin);

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

test("duplicate changes ignore object field order, preserve array order, and wait for pending calls", async () => {
	const { loopBrake } = await import("./pippa-assist.ts");
	const counts = new Map(), keys = new Map();
	const first = { folder: "/fake", groups: [{ into: "Letters", files: ["a.txt", "b.txt"] }] };
	const reordered = { groups: [{ files: ["a.txt", "b.txt"], into: "Letters" }], folder: "/fake" };
	assert.equal(loopBrake(counts, keys, "first", "move_files", first, true), undefined);
	assert.match(loopBrake(counts, keys, "pending", "move_files", reordered, true), /already running/);
	counts.get(keys.get("first")).failures++;
	assert.equal(loopBrake(counts, keys, "retry", "move_files", reordered, true), undefined, "a failed change can be retried");
	counts.get(keys.get("retry")).successes++;
	assert.match(loopBrake(counts, keys, "duplicate", "move_files", first, true), /would make a duplicate/);
	assert.equal(loopBrake(counts, keys, "different", "move_files", {
		folder: "/fake", groups: [{ into: "Letters", files: ["b.txt", "a.txt"] }],
	}, true), undefined, "arrays can carry meaningful order and are not sorted");
});

function loopHarness() {
	const handlers = {}, entries = [];
	let aborted = 0;
	assist({ on: (name, fn) => handlers[name] = fn, appendEntry: (type, data) => entries.push({ type, data }) });
	const ctx = { abort: () => aborted++ };
	return { handlers, entries, get aborted() { return aborted; }, async call(id, tool, input, { validates = true, isError = false, content = [] } = {}) {
		const event = { toolName: tool, toolCallId: id, input };
		await handlers.tool_execution_start({ ...event, args: input }, ctx);
		const blocked = validates ? await handlers.tool_call(event, ctx) : undefined;
		const failed = isError || !validates || Boolean(blocked);
		// Pi does not emit tool_result for unknown tools, invalid arguments or extension-blocked calls.
		if (validates && !blocked) await handlers.tool_result({ ...event, isError: failed, content }, ctx);
		await handlers.tool_execution_end({ ...event, isError: failed, result: { content } }, ctx);
		return blocked;
	} };
}

test("uncertain native writes are terminal for this answer and never reported as successful duplicates", async () => {
	for (const tool of ["mcp__pippa__calendar_add", "mcp__pippa__reminder_add", "mcp__pippa__mail_draft", "mcp__pippa__prepare_files"]) {
		for (const isError of [false, true]) {
			const run = loopHarness();
			const input = { title: "Fixture", date: "2026-10-22" };
			// Actual Pippa MCP payload: an unconfirmed native write is not an MCP error, but was not confirmed done.
			const content = [{ type: "text", text: JSON.stringify({ done: false, state: "unclear", sent: false,
				tell: "Please check the app before trying again.", next: "Do not retry this action automatically." }) }];
			assert.equal(await run.call("first", tool, input, { content, isError }), undefined);
			const blocked = await run.call("retry", tool, { date: input.date, title: input.title });
			assert.match(blocked.reason, /an unclear outcome/);
			assert.match(blocked.reason, /Check the native app before trying again/);
			assert.doesNotMatch(blocked.reason, /It is done|already worked|already running/);
			assert.equal(await run.call("different", tool, { ...input, title: "Another fixture" }), undefined);
			await run.handlers.agent_end({});
			await run.handlers.agent_start({});
			assert.equal(await run.call("new-answer", tool, input), undefined, "uncertainty does not persist across answers");
		}
	}
});

test("explicit native dispatched/unclear status blocks retries even when MCP flags an error", async () => {
	for (const status of [{ status: "unclear" }, { status: "dispatched" }, { state: "dispatched" }, { dispatched: true }]) {
		const run = loopHarness(), tool = "mcp__pippa__reminder_add", input = { title: "Fixture" };
		const content = [{ type: "text", text: JSON.stringify({ done: false, ...status }) }];
		assert.equal(await run.call("first", tool, input, { content, isError: true }), undefined);
		assert.match((await run.call("retry", tool, input)).reason, /an unclear outcome/);
	}
});

test("structured native refusals can retry; result prose and nested data do not override their top-level status", async () => {
	const payloads = [
		{ done: false, status: "failed", dispatched: false },
		{ done: false, status: "invalid_arguments" },
		{ done: false, status: "failed", tell: "unclear dispatched" },
		{ done: false, status: "failed", data: { state: "unclear", dispatched: true } },
	];
	for (const payload of payloads) {
		const run = loopHarness(), tool = "mcp__pippa__reminder_add", input = { title: "Fixture" };
		const content = [{ type: "text", text: typeof payload === "string" ? payload : JSON.stringify(payload) }];
		assert.equal(await run.call("first", tool, input, { content, isError: true }), undefined);
		assert.equal(await run.call("retry", tool, input, { content, isError: true }), undefined);
		assert.match((await run.call("third", tool, input)).reason, /already failed 2 times/);
	}
	for (const tool of ["write", "mcp__other__reminder_add", "mcp__pippa__read_document"]) {
		const run = loopHarness(), input = { path: "/fake/fixture.txt" };
		const content = [{ type: "text", text: JSON.stringify({ done: false, state: "unclear", dispatched: true }) }];
		assert.equal(await run.call("first", tool, input, { content, isError: true }), undefined);
		assert.equal(await run.call("retry", tool, input), undefined, "only native mutation result statuses count");
	}
});

test("lost or malformed native replies block repeats, while validation rejects remain retryable", async () => {
	for (const payload of ["Connection closed", '{"done":false,"state":"unclear"', {}, { done: 1 },
		{ done: false, status: "failed", dispatched: "true" }, { done: false, status: "failed", dispatched: 1 },
		{ done: false, status: "failed", dispatched: null }]) {
		const run = loopHarness(), tool = "mcp__pippa__reminder_add", input = { title: "Fixture" };
		const content = [{ type: "text", text: typeof payload === "string" ? payload : JSON.stringify(payload) }];
		assert.equal(await run.call("first", tool, input, { content, isError: true }), undefined);
		for (let n = 0; n < 3; n++) {
			const blocked = await run.call(`retry${n}`, tool, input);
			assert.match(blocked.reason, /an unclear outcome/);
			assert.equal(JSON.parse(blocked.reason).status, "not_dispatched", "a blocked retry is distinct from the original uncertain effect");
		}
		assert.equal(run.aborted, 1);
	}
	const run = loopHarness(), tool = "mcp__pippa__reminder_add", input = { wrong_title: "Fixture" };
	assert.equal(await run.call("invalid", tool, input, { validates: false }), undefined);
	assert.equal(await run.call("retry", tool, input, { validates: false }), undefined);
	assert.match((await run.call("third", tool, input)).reason, /already failed 2 times/);
});

test("a confirmed native success stays confirmed after multiple blocked duplicate calls", async () => {
	const run = loopHarness(), tool = "mcp__pippa__reminder_add", input = { title: "Fixture" };
	await run.call("first", tool, input, { content: [{ type: "text", text: '{"done":true}' }] });
	for (let n = 0; n < 3; n++) {
		const block = await run.call(`duplicate${n}`, tool, input);
		assert.match(JSON.parse(block.reason).tell, /already worked/);
		assert.doesNotMatch(block.reason, /unclear outcome/);
	}
});

test("file preparation does not duplicate a verified result, while a requested change of page order can run", async () => {
	const run = loopHarness(), tool = "mcp__pippa__prepare_files";
	const input = { paths: ["/fixture/first.pdf", "/fixture/second.jpg"], quality: "balanced", size_limit_mb: 5 };
	const content = [{ type: "text", text: JSON.stringify({ done: true, path: "/fixture/result.pdf", bytes: 3_000_000 }) }];
	assert.equal(await run.call("first", tool, input, { content }), undefined);
	const duplicate = await run.call("duplicate", tool, { size_limit_mb: 5, quality: "balanced", paths: input.paths });
	assert.match(JSON.parse(duplicate.reason).tell, /already worked/);
	assert.equal(await run.call("new-order", tool, { ...input, paths: [...input.paths].reverse() }, { content }), undefined);
});

test("rejected document reads are bounded even though Pi skips tool_result; a corrected tool still works", async () => {
	const run = loopHarness();
	const input = { path: "/fake/invoice.pdf" };
	assert.match((await run.call("first", "read", input)).reason, /mcp__pippa__read_document/);
	assert.equal(await run.call("corrected", "mcp__pippa__read_document", input), undefined);
	assert.match((await run.call("retry", "read", input)).reason, /mcp__pippa__read_document/);
	for (let i = 0; i < 3; i++) {
		assert.match((await run.call(`repeat${i}`, "read", input)).reason, /already failed 2 times/);
	}
	assert.equal(run.aborted, 1);
	assert.equal(run.entries.filter((entry) => entry.type === "pippa-loop-stop").length, 1);
	await run.handlers.agent_start({});
	assert.match((await run.call("new-answer", "read", input)).reason, /mcp__pippa__read_document/);
});

test("unknown tools and invalid arguments cannot bypass the loop brake before tool_call", async () => {
	for (const [tool, input] of [["invented_tool", { query: "invoice" }], ["read", { wrong_path: "/fake/invoice.txt" }]]) {
		const run = loopHarness();
		for (let i = 0; i < 5; i++) await run.call(`bad${i}`, tool, input, { validates: false });
		assert.equal(run.aborted, 1, tool);
		assert.equal(run.entries.find((entry) => entry.type === "pippa-loop-stop")?.data.tool, tool);
	}
});

test("executed results count once, and distinct invalid calls consume the same overall budget", async () => {
	const { MAX_CALLS } = await import("./pippa-assist.ts");
	const run = loopHarness();
	assert.equal(await run.call("fail1", "read", { path: "/fake/missing.txt" }, { isError: true }), undefined);
	assert.equal(await run.call("fail2", "read", { path: "/fake/missing.txt" }, { isError: true }), undefined);
	assert.match((await run.call("fail3", "read", { path: "/fake/missing.txt" })).reason, /already failed 2 times/);
	assert.equal(run.aborted, 0);
	await run.handlers.agent_start({});
	for (let i = 0; i < MAX_CALLS + 3; i++) await run.call(`invalid${i}`, `invented_${i}`, {}, { validates: false });
	assert.equal(run.aborted, 1);
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

test('call budget: different calls still stop after MAX_CALLS per answer, then the answer ends; a new answer starts fresh', async () => {
 const { MAX_CALLS } = await import('./pippa-assist.ts');
 const handlers={},entries=[];let aborted=0;
 assist({on:(name,fn)=>handlers[name]=fn,getAllTools:()=>tools,appendEntry:(type,data)=>entries.push({type,data})});
 const ctx={abort:()=>aborted++};
 await handlers.agent_start({});
 const blocked=[];
 for(let i=0;i<MAX_CALLS+3;i++){
  const event={toolName:'mcp__pippa__read_document',input:{path:`/fake/Downloads/beleg_${i}.pdf`},toolCallId:'r'+i};
  const block=await handlers.tool_call(event,ctx);
  if(block)blocked.push(block.reason);else await handlers.tool_result({...event,isError:false,content:[{type:'text',text:'ok'}]},ctx);
 }
 assert.equal(blocked.length,3);
 assert.match(blocked[0],/Answer the user now/);
 assert.equal(aborted,1);
 assert.equal(entries.filter(x=>x.type==='pippa-loop-stop').length,1);
 await handlers.agent_start({});
 assert.equal(await handlers.tool_call({toolName:'mcp__pippa__read_document',input:{path:'/fake/a.pdf'},toolCallId:'n1'},ctx),undefined);
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

test('verified search results are signalled only for search_files, not model-written JSON', async () => {
 const handlers={},entries=[];
  assist({on:(name,fn)=>handlers[name]=fn,getAllTools:()=>tools,appendEntry:(type,data)=>entries.push({type,data})});
 const ctx={};
 const result={isError:false,content:[{type:'text',text:JSON.stringify({files:[{path:'/fake/Documents/beleg.pdf'}]})}]};
 await handlers.tool_call({toolName:'search_files',toolCallId:'real',input:{query:'Kaution'}},ctx);
 await handlers.tool_result({...result,toolName:'search_files',toolCallId:'real'},ctx);
 await handlers.tool_call({toolName:'bash',toolCallId:'fake',input:{command:'echo result'}},ctx);
 await handlers.tool_result({...result,toolName:'bash',toolCallId:'fake'},ctx);
 const found=entries.filter(e=>e.type==='pippa-search-result');
 assert.equal(found.length,1);assert.deepEqual(found[0].data.files,['/fake/Documents/beleg.pdf']);
});

test('files a folder listing or shell command showed become pippa-listed-files', async () => {
 const { listedFiles } = await import('./pippa-assist.ts');
 const listing='/Users/remi/projects/Kinderbuch:\nBilder/\nKinderbuch_35cm_Gesamt.pdf (3.5 MB, 2026-09-01)\nNotiz (alt) (1 KB, 2026-01-02)\nohne-info\n… and 3 more';
 assert.deepEqual(listedFiles('list_folder',[{type:'text',text:listing}]),
  ['/Users/remi/projects/Kinderbuch/Kinderbuch_35cm_Gesamt.pdf','/Users/remi/projects/Kinderbuch/Notiz (alt)','/Users/remi/projects/Kinderbuch/ohne-info']);
 assert.deepEqual(listedFiles('list_folder',[{type:'text',text:'/x is empty.'}]),[]);
 assert.deepEqual(listedFiles('bash',[{type:'text',text:'/a/b.pdf\n/a/c/\nrelative.txt'}],'find /a -name "*.pdf"'),['/a/b.pdf']);
 assert.deepEqual(listedFiles('bash',[{type:'text',text:'b.pdf\nc.pdf'}],'ls -1 "/a/x y"'),['/a/x y/b.pdf','/a/x y/c.pdf']);
 assert.deepEqual(listedFiles('bash',[{type:'text',text:'-rw-r--r-- 1 b.pdf'}],'ls -la /a'),[]);
 const handlers={},entries=[];
 assist({on:(name,fn)=>handlers[name]=fn,getAllTools:()=>tools,appendEntry:(type,data)=>entries.push({type,data})});
 await handlers.tool_call({toolName:'list_folder',toolCallId:'l',input:{path:'/Users/remi/projects/Kinderbuch'}},{});
 await handlers.tool_result({toolName:'list_folder',toolCallId:'l',isError:false,content:[{type:'text',text:listing}]},{});
 const listed=entries.filter(e=>e.type==='pippa-listed-files');
 assert.equal(listed.length,1);assert.equal(listed[0].data.files[0],'/Users/remi/projects/Kinderbuch/Kinderbuch_35cm_Gesamt.pdf');
 assert.equal(entries.filter(e=>e.type==='pippa-search-result').length,0);
});

test('loop stop preserves the search truncation flag with exactly 200 returned files', async () => {
 const handlers={},entries=[];
  assist({on:(name,fn)=>handlers[name]=fn,getAllTools:()=>tools,appendEntry:(type,data)=>entries.push({type,data})});
 const ctx={abort:()=>{}};
 const input={query:'Steuer'};
 for(const truncated of [true,false]){
  await handlers.agent_start({});
  const files=truncated?Array.from({length:200},(_,i)=>({path:`/fake/Documents/${i}.pdf`})) : [];
  for(let i=0;i<7;i++){
   const event={toolName:'search_files',input,toolCallId:`cap-${truncated}-${i}`};
   if(!await handlers.tool_call(event,ctx))await handlers.tool_result({...event,isError:false,content:[{type:'text',text:JSON.stringify({files,truncated})}]},ctx);
  }
  const stop=entries.filter(x=>x.type==='pippa-loop-stop').at(-1).data;
  assert.equal(stop.files.length,files.length);assert.equal(stop.truncated,truncated);
 }
});

test("today's date goes in front of each new message, a skill command stays first, steering stays as typed", async () => {
	const { todayLine, withToday } = await import("./pippa-assist.ts");
	const day = new Date(2026, 9, 9, 23, 30);
	assert.equal(todayLine(day), "[2026-10-09, Friday]");
	assert.equal(todayLine(new Date(2026, 0, 4)), "[2026-01-04, Sunday]");
	const line = "[2026-10-09, Friday]";
	assert.equal(withToday("Wie wird das Wetter morgen?", line), `${line}\nWie wird das Wetter morgen?`);
	assert.equal(withToday("/skill:fristen-erkennen Welche Fristen?\nmehr", line), `/skill:fristen-erkennen ${line}\nWelche Fristen?\nmehr`);
	assert.equal(withToday("/skill:stichpunkte", line), `/skill:stichpunkte ${line}`);
	assert.equal(withToday("/andere Vorlage", line), "/andere Vorlage");
	const handlers = {};
	assist({ on: (name, handler) => (handlers[name] = handler), registerTool() {}, getAllTools: () => tools, appendEntry() {} });
	const sent = await handlers.input({ type: "input", text: "Hallo", source: "rpc" });
	assert.equal(sent.action, "transform");
	assert.match(sent.text, /^\[\d{4}-\d\d-\d\d, \w+day\]\nHallo$/);
	assert.deepEqual(await handlers.input({ type: "input", text: "Stopp", source: "rpc", streamingBehavior: "steer" }), { action: "continue" });
});

test("edit and write keep the old version first; the result says where; a new file needs no copy", async () => {
	const { mkdtemp, writeFile, readFile, readdir } = await import("node:fs/promises");
	const { tmpdir } = await import("node:os");
	const { join } = await import("node:path");
	const dir = await mkdtemp(join(tmpdir(), "pippa-backup-"));
	process.env.PIPPA_BACKUP_DIR = join(dir, "Backups");
	try {
		const { default: fresh } = await import(`./pippa-assist.ts?backup=${Date.now()}`);
		const handlers = {};
		fresh({ on: (name, fn) => (handlers[name] = fn), getAllTools: () => tools, appendEntry: () => {} });
		await handlers.agent_start({});
		await writeFile(join(dir, "Brief.txt"), "alt");
		const { utimes } = await import("node:fs/promises");
		const lastYear = new Date(Date.now() - 400 * 86_400_000);
		await utimes(join(dir, "Brief.txt"), lastYear, lastYear);   // an old letter: its copy still counts as new
		const ctx = { cwd: dir };
		assert.equal(await handlers.tool_call({ toolName: "write", input: { path: "Brief.txt", content: "neu" }, toolCallId: "w1" }, ctx), undefined);
		await writeFile(join(dir, "Brief.txt"), "neu");
		const result = await handlers.tool_result({ toolName: "write", toolCallId: "w1", isError: false, content: [{ type: "text", text: "ok" }] }, ctx);
		const [copy] = await readdir(join(dir, "Backups"));
		assert.match(copy, /^\d{4}-\d\d-\d\d \d\d\.\d\d\.\d\d Brief\.txt$/);
		assert.equal(await readFile(join(dir, "Backups", copy), "utf8"), "alt");
		assert.match(result.content.at(-1).text, /previous version of Brief\.txt is kept at .*Backups/);
		assert.equal(await handlers.tool_call({ toolName: "write", input: { path: join(dir, "Neu.txt"), content: "x" }, toolCallId: "w2" }, ctx), undefined);
		assert.equal(await handlers.tool_result({ toolName: "write", toolCallId: "w2", isError: false, content: [{ type: "text", text: "ok" }] }, ctx), undefined);
		assert.equal((await readdir(join(dir, "Backups"))).length, 1);
		const { pruneBackups } = await import("./pippa-assist.ts");
		await pruneBackups(join(dir, "Backups"));
		assert.deepEqual(await readdir(join(dir, "Backups")), [copy]);
	} finally {
		delete process.env.PIPPA_BACKUP_DIR;
	}
});

test("old copies go after BACKUP_DAYS", async () => {
	const { pruneBackups, BACKUP_DAYS } = await import("./pippa-assist.ts");
	const { mkdtemp, writeFile, readdir, utimes } = await import("node:fs/promises");
	const { tmpdir } = await import("node:os");
	const { join } = await import("node:path");
	const dir = await mkdtemp(join(tmpdir(), "pippa-prune-"));
	await writeFile(join(dir, "alt.txt"), "a");
	await writeFile(join(dir, "neu.txt"), "b");
	const old = new Date(Date.now() - (BACKUP_DAYS + 1) * 86_400_000);
	await utimes(join(dir, "alt.txt"), old, old);
	await pruneBackups(dir);
	assert.deepEqual(await readdir(dir), ["neu.txt"]);
});

test("what an answer changed is told to the app from the tools' own results, so it can be undone", async () => {
	const { changesOf } = await import("./pippa-assist.ts");
	assert.deepEqual(changesOf("edit", undefined, false, { file: "/u/a.txt", copy: "/b/a.txt" }), [{ kind: "restore", file: "/u/a.txt", copy: "/b/a.txt" }]);
	assert.deepEqual(changesOf("write", undefined, false, { file: "/u/new.txt", created: true }), [{ kind: "create", file: "/u/new.txt" }]);
	assert.deepEqual(changesOf("write", undefined, true, { file: "/u/new.txt", created: true }), [], "failed: no confirmed new file to remove");
	assert.deepEqual(changesOf("move_files", { moved: [{ from: "/d/a.pdf", to: "/d/X/a.pdf" }], failed: [] }, false), [{ kind: "move", from: "/d/a.pdf", to: "/d/X/a.pdf" }]);
	assert.deepEqual(changesOf("move_files", { from: "/d/a.pdf", to: "/e/a.pdf" }, false), [{ kind: "move", from: "/d/a.pdf", to: "/e/a.pdf" }]);
	assert.deepEqual(changesOf("move_to_trash", { path: "/d/a.pdf", trashedTo: "/T/a.pdf" }, false), [{ kind: "trash", from: "/d/a.pdf", to: "/T/a.pdf" }]);
	assert.deepEqual(changesOf("move_to_trash", { path: "/d/a.pdf" }, false), [], "unknown place in the Trash: nothing to take back");
	assert.deepEqual(changesOf("bash", { pippaKept: [{ file: "/u/a.txt", copy: "/b/a.txt" }] }, false), [{ kind: "restore", file: "/u/a.txt", copy: "/b/a.txt" }]);
	assert.deepEqual(changesOf("bash", { pippaKept: [{ file: "/u/a.txt", copy: "/b/a.txt" }] }, true), [{ kind: "restore", file: "/u/a.txt", copy: "/b/a.txt" }]);
	assert.deepEqual(changesOf("write", {}, true, { file: "/u/a.txt", copy: "/b/a.txt" }), [{ kind: "restore", file: "/u/a.txt", copy: "/b/a.txt" }]);
	assert.deepEqual(changesOf("read", {}, false), []);
});
