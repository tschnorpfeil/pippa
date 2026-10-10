// Actual Pi RPC + K2: blocked first-choice test, or isolated first-search execution with generated PDFs.
// node scripts/quality/tool-choice.mjs <payload> <llama URL> <label> [case ids...]
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { resolve, join } from 'node:path';
const root = resolve(import.meta.dirname, '../..');
const [payload, upstream, label, ...ids] = process.argv.slice(2);
if (!payload || !upstream || !/^[a-z0-9-]+$/.test(label ?? '')) throw Error('payload, llama URL, label required');
const flow = process.env.PIPPA_SEARCH_FLOW === '1';
const dialogue = flow && process.env.PIPPA_SEARCH_DIALOGUE === '1';
const base = label.startsWith('before') ? join(root,'.build/tool-before') : root;
const home = flow ? resolve(process.env.CFFIXED_USER_HOME) : join(root, '.build/tool-choice-home');
if(flow && !home.endsWith('/pippa/dist/tool-search-home')) throw Error('Use the generated search fixture HOME');
await mkdir(join(home,'work'),{recursive:true});
await mkdir(join(home, '.pi/agent'), {recursive:true});
const fixtureTexts = flow ? JSON.parse(await readFile(join(home,'.search-corpus.json'))) : {};
const schemas = JSON.parse(await readFile(join(root, '.build/mcp-tools.json')));
const mcp = createServer(async(req,res)=> {
 let body=''; for await (const c of req) body+=c;
 let q; try { q=JSON.parse(body); } catch {res.writeHead(400).end();return;}
 if(q.id===undefined) {res.writeHead(202).end();return;}
 const result = q.method==='initialize' ? {protocolVersion:'2025-03-26',capabilities:{tools:{}},serverInfo:{name:'pippa',version:'measurement'}} : q.method==='tools/list' ? {tools:schemas} : q.method==='tools/call' ? (()=>{
 const path=String(q.params?.arguments?.path??'').replace(/^~(?=\/)/,home);
 const text=fixtureTexts[path];
 return text ? {content:[{type:'text',text:JSON.stringify({data:{name:path.split('/').at(-1),text}})}]} : {isError:true,content:[{type:'text',text:'Only generated fixture documents can be read.'}]};
})() : {};
 res.setHeader('content-type','application/json');res.end(JSON.stringify({jsonrpc:'2.0',id:q.id,result}));
});
await new Promise(ok=>mcp.listen(0,'127.0.0.1',ok));
let captured;
let requests=0;
const proxy = createServer(async(req,res)=> {
 let raw='';for await(const c of req)raw+=c;
 requests++;if(requests===1)captured=JSON.parse(raw);
 if(requests>1 && !flow) {res.writeHead(200,{'content-type':'text/event-stream'});res.end(`data: ${JSON.stringify({choices:[{index:0,delta:{content:'Messung beendet.'},finish_reason:'stop'}]})}\n\ndata: [DONE]\n\n`);return;}
 const controller=new AbortController();res.on('close',()=>{if(!res.writableEnded)controller.abort();});
 try {
  const r=await fetch(upstream+req.url,{method:'POST',headers:{'content-type':'application/json'},body:raw,signal:controller.signal});
  res.writeHead(r.status,{'content-type':r.headers.get('content-type')});
  for await(const c of r.body)res.write(c);res.end();
 }catch(e){res.writeHead(500).end(String(e));}
});
await new Promise(ok=>proxy.listen(0,'127.0.0.1',ok));
// PIPPA_MC_VARIANT (A/B/C, model-compare/variants.mjs): models.json, model and thinking level as Pippa writes them.
const mc = process.env.PIPPA_MC_VARIANT ? (await import('./model-compare/variants.mjs')).VARIANTS[process.env.PIPPA_MC_VARIANT] : undefined;
if (process.env.PIPPA_MC_VARIANT && !mc) throw Error('unknown PIPPA_MC_VARIANT');
const modelID = mc?.key ?? 'k2-horizon-7b', thinking = mc?.thinking ?? 'medium';
await writeFile(join(home,'.pi/agent/models.json'),JSON.stringify(mc ? (await import('./model-compare/variants.mjs')).modelsJson(mc,`http://127.0.0.1:${proxy.address().port}/v1`) : {providers:{'pippa-local':{baseUrl:`http://127.0.0.1:${proxy.address().port}/v1`,api:'openai-completions',apiKey:'fake',models:[{id:'k2-horizon-7b',name:'K2',reasoning:true,contextWindow:32768,maxTokens:4096,thinkingLevelMap:{medium:'medium'},compat:{supportsDeveloperRole:false,supportsReasoningEffort:true}}]}}}));
if (mc) await writeFile(join(home,'.pi/agent/settings.json'),JSON.stringify((await import('./model-compare/variants.mjs')).piSettings(mc)));
const extension=join(home,'block.ts');
await writeFile(extension,`export default function(pi:any){pi.on('tool_call',()=>({block:true,reason:'Measurement only. No tool may execute.'}));}`);
if(flow){
 await mkdir(join(home,'bin'),{recursive:true});
 const node = join(payload,'bin/node');
 await writeFile(join(home,'bin/mdfind'), `#!${node}\nimport {execFileSync} from 'node:child_process';let a=process.argv.slice(2);a=a.filter((v,i)=>v!=='-onlyin'&&a[i-1]!=='-onlyin');process.stdout.write(execFileSync('/usr/bin/mdfind',['-onlyin',process.env.HOME,...a]));`);
 const {chmod,symlink} = await import('node:fs/promises');await chmod(join(home,'bin/mdfind'),0o755);
 await symlink(node,join(home,'bin/node')).catch(e=>{if(e.code!=='EEXIST')throw e;});

}
const launch=await readFile(join(base,'app/Sources/PiRPC/PippaPiLaunch.swift'),'utf8');
const prompt=launch.match(/static let german = """\n([\s\S]*?)\n    """/)[1].replace(/^    /gm,'');
const tools=launch.match(/public static let tools = \[([\s\S]*?)\]/)[1].match(/"[^"]+"/g).map(x=>JSON.parse(x)).join(',');
const cases=JSON.parse(await readFile(join(root,'scripts/quality/tool-choice.json'))).filter(x=>!ids.length||ids.includes(x.id));
// As in the app: pi-web-access through Pippa's settings (needs npm ci in runtime/pippa-web). PIPPA_WEB_EXTENSION: another checkout's index.ts for a before run.
const web=process.env.PIPPA_WEB_EXTENSION??join(root,'runtime/pippa-web/index.ts');
const results=[];
try {
 for(const item of cases){
  requests=0;captured=undefined;
  const events=[];let err='';const start=Date.now();
  const env={HOME:home,CFFIXED_USER_HOME:home,PI_CODING_AGENT_DIR:join(home,'.pi/agent'),PI_OFFLINE:'1',PI_TELEMETRY:'0',PI_SKIP_VERSION_CHECK:'1',PATH:flow?join(home,'bin')+':/Applications/Pippa.app/Contents/Helpers:/usr/bin:/bin:/usr/sbin:/sbin':'/usr/bin:/bin:/usr/sbin:/sbin',PIPPA_FIXTURE_SKILLS:join(base,'runtime/pippa-skills'),PIPPA_TRASH_DIR:join(home,'trash'),PIPPA_WEB_DIR:join(home,'web'),PIPPA_MCP_URL:`http://127.0.0.1:${mcp.address().port}/mcp`,PIPPA_MCP_TOKEN:'a'.repeat(64)};
  const child=spawn(join(payload,'bin/node'),[join(payload,'release/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js'),'--mode','rpc','--no-session','--no-context-files','--no-approve','--no-skills','--skill',join(base,'runtime/pippa-skills'),'--extension',join(base,'runtime/pippa-tools/pippa-tools.ts'),'--extension',join(root,'runtime/pippa-tools/pippa-mcp.ts'),'--extension',join(root,'runtime/pippa-tools/pippa-assist.ts'),'--extension',web,'--extension',flow?join(root,'scripts/quality/fixture-isolation.ts'):extension,'--tools',tools,'--system-prompt',prompt,'--provider','pippa-local','--model',modelID,'--thinking',thinking],{cwd:join(home,'work'),env,stdio:['pipe','pipe','pipe']});
  child.stderr.on('data',d=>err+=d);let buffer='';let timedOut=false;
  await new Promise((ok,fail)=>{
   const timer=setTimeout(()=>{child.kill();fail(Error('timeout '+item.id+' '+err.slice(-500)));},dialogue ? 300000 : 180000);
   child.on('error',fail);child.on('exit',code=>{if(code!==null&&code!==0){clearTimeout(timer);fail(Error(err));}});
   child.stdout.on('data',d=>{
    buffer+=d;let n;while((n=buffer.indexOf('\n'))>=0){const line=buffer.slice(0,n);buffer=buffer.slice(n+1);let e;try{e=JSON.parse(line);}catch{continue;}events.push(e);
     if(flow && !dialogue && e.type==='tool_execution_end' && e.toolCallId===events.find(x=>x.type==='tool_execution_start'&&['search_files','bash','find','grep','ls','list_folder'].includes(x.toolName))?.toolCallId){child.stdin.write(JSON.stringify({type:'abort'})+'\n');clearTimeout(timer);ok();}
     if(e.type==='extension_ui_request' && ['select','confirm'].includes(e.method))child.stdin.write(JSON.stringify({type:'extension_ui_response',id:e.id,...(e.method==='confirm'?{confirmed:false}:{value:e.options.at(-1)})})+'\n');
     if(e.type==='extension_error'){clearTimeout(timer);child.kill();fail(Error(JSON.stringify(e)));}
     if(e.type==='agent_settled'){clearTimeout(timer);ok();}
    }
   });
   child.stdin.write(JSON.stringify({type:'prompt',message:item.prompt})+'\n');
  }).catch(e=>{timedOut=true;err+=e.message;});
  // The previous Pi must exit before the shared proxy starts another case.
  await new Promise(done=>{
   if(child.exitCode!==null || child.signalCode!==null){done();return;}
   child.once('exit',done);child.kill();
  });
  const choices=events.filter(x=>x.type==='tool_execution_start').map(x=>({name:x.toolName,args:x.args}));
  const first=choices[0]?.name;
  const ok=item.tools.length ? item.tools.includes(first) : choices.length===0&&events.some(x=>x.type==='message_end'&&x.message?.stopReason==='stop');
  const retrieved = new Set();
  const primary=events.find(x=>x.type==='tool_execution_start'&&['search_files','bash','find','grep','ls','list_folder'].includes(x.toolName))?.toolCallId;
  if(flow)for(const event of events.filter(e=>e.type==='tool_execution_end'&&e.toolCallId===primary))for(const part of event.result?.content??[]){
   if(part.type!=='text')continue;
   try{for(const file of JSON.parse(part.text).files??[])if(typeof file.path==='string')retrieved.add(file.path);}catch{
    for(const path of String(part.text).split(/[\n\0]/))if(path.startsWith(home+'/')&&path.endsWith('.pdf'))retrieved.add(path);
   }
  }
  const found=[...retrieved].sort();const expected=(item.expectedFiles??[]).map(p=>join(home,p)).sort();
  const finalAnswer = events.findLast(x=>x.type==='message_end'&&x.message?.role==='assistant')?.message?.content?.filter(p=>p.type==='text').map(p=>p.text).join('\n')??'';
  const loopStopped = events.some(x=>x.type==='entry_appended'&&x.entry?.customType==='pippa-loop-stop');
  const searchCalls = choices.filter(x=>['search_files','bash','find','grep','ls','list_folder'].includes(x.name)).length;
  const completed = events.some(x=>x.type==='agent_settled');
  const linkedFiles = [...finalAnswer.matchAll(/\[[^\]]+\]\((file:\/\/\/[^)]+)\)/g)].map(m=>decodeURIComponent(new URL(m[1]).pathname));
  const complete = flow ? JSON.stringify(found)===JSON.stringify(expected)&&expected.length>0 && (!dialogue || completed && !loopStopped && searchCalls===1 && expected.every(p=>linkedFiles.includes(p))) : ok;
  const result={...item,choices,choiceCorrect:ok,retrieved:flow?found:undefined,ok:complete&&!timedOut,timedOut,discoveryOnly:flow&&!dialogue,...(dialogue?{completed,loopStopped,searchCalls,finalAnswer,linkedFiles}:{}),primarySearchID:flow?primary:undefined,diagnostics:err.slice(-2000),answers:events.filter(x=>x.type==='message_end'&&x.message?.role==='assistant').map(x=>x.message.content),results:flow?events.filter(x=>x.type==='tool_execution_end'):undefined,entries:flow?events.filter(x=>x.type==='entry_appended'):undefined,seconds:(Date.now()-start)/1000,usage:events.filter(x=>x.type==='message_end'&&x.message?.role==='assistant').map(x=>x.message.usage),errors:events.filter(x=>x.type==='message_end'&&x.message?.stopReason==='error').map(x=>x.message.errorMessage)};
  results.push(result);console.log(`${label} ${item.id}: ${result.ok?'PASS':'FAIL'} ${first??'answer'} ${result.seconds}s`);
  if(captured)await writeFile(join(home,`${label}-payload.json`),JSON.stringify(captured,null,2));
  await writeFile(join(root,`.build/tool-choice-${label}.json`),JSON.stringify(results,null,2));
 }
}finally{mcp.closeAllConnections();mcp.close();proxy.closeAllConnections();proxy.close();}
console.log(`${label}: ${results.filter(x=>x.ok).length}/${results.length}`);
