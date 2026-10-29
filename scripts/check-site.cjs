// Run with node scripts/check-site.cjs. No packages or browser required.
// Drag geometry model (site/pippaDrag.js; the scripted homepage demo does not load it), then the content gate for the homepage:
// German and English stay in step, promises stay honest, nothing external is loaded.
const assert = require('node:assert/strict');
const { sample } = require('../site/pippaDrag.js');
const target = { left: 300, right: 450, top: 250, bottom: 314 };
const item = (x, y, pointerX = x, pointerY = y, width = 120, height = 100) => ({ centerX: x, centerY: y, pointerX, pointerY, width, height });

// Approaching and leaving use the same continuous force, with no sticky state.
for (let x = 100; x <= 650; x += .5) {
  const a = sample(item(x, 210), target);
  const b = sample(item(x + .01, 210), target);
  assert.ok(Math.hypot(a.pullX, a.pullY) <= 36 + 1e-8);
  assert.ok(Math.hypot(a.pullX - b.pullX, a.pullY - b.pullY) < .01);
  assert.deepEqual(a, sample(item(x, 210), target));
}
assert.equal(sample(item(90, 80), target).strength, 0);
assert.equal(sample(item(90, 80), target).ready, false);
assert.deepEqual([sample(item(375, 282), target).pullX, sample(item(375, 282), target).pullY], [0, 0]);
// The inner snap is noticeable, but leaves most of the distance under control.
const near = sample(item(305, 282), target);
assert.ok(near.pullX > 25 && near.pullX < 35);
assert.ok(305 + near.pullX < 375);
const outside = sample(item(90, 80), target);
assert.deepEqual([outside.pullX, outside.pullY, outside.dock], [0, 0, 0]);
const reduced = sample(item(305, 282), target, { maxPull: 0 });
assert.deepEqual([reduced.pullX, reduced.pullY], [0, 0]);

// Grabbing a sheet at its edge must work as well as grabbing its center.
assert.equal(sample(item(260, 220, 330, 275), target).ready, true);
assert.equal(sample(item(370, 280, 520, 400), target).ready, true);
assert.equal(sample(item(490, 280, 570, 280, 180, 120), target).ready, true);
assert.equal(sample(item(100, 100, 200, 180), target).ready, false);

// An oversized sheet barely brushing the target is not a drop.
assert.equal(sample(item(50, 50, 20, 20, 510, 410), target).ready, false);
const small = sample(item(375, 282, 375, 282, 0, 0), target);
assert.ok(Number.isFinite(small.pullX) && Number.isFinite(small.pullY));
console.log('Drag checks passed: continuous partial snap, 36px cap, release, reduced motion, edge grabs, overlap and misses.');

const fs = require('node:fs');
const path = require('node:path');
const site = path.join(__dirname, '../site');
const pages = { de: fs.readFileSync(path.join(site, 'index.html'), 'utf8'), en: fs.readFileSync(path.join(site, 'en/index.html'), 'utf8') };
const text = html => html.replace(/<script[\s\S]*?<\/script>|<style[\s\S]*?<\/style>/g, ' ').replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ');
const count = (html, re) => (html.match(re) || []).length;

// Same structure in both languages.
for (const re of [/<section\b/g, /<h2\b/g, /<h3\b/g, /<article class="job"/g, /data-play="/g, /data-k="/g, /<tr\b/g, /<details\b/g, /role="img"/g, /class="btn[^"]*dl/g]) {
  assert.equal(count(pages.de, re), count(pages.en, re), `DE and EN differ in ${re}`);
}
const ids = html => [...html.matchAll(/\sid="([^"]+)"/g)].map(m => m[1]).filter(id => id !== 'language').sort();
assert.deepEqual(ids(pages.de), ids(pages.en), 'DE and EN use different ids');

for (const [lang, html] of Object.entries(pages)) {
  const t = text(html);
  // Headings in order: one h1, no level skipped.
  const levels = [...html.matchAll(/<h([1-6])\b/g)].map(m => +m[1]);
  assert.equal(levels.filter(l => l === 1).length, 1, `${lang}: exactly one h1`);
  levels.reduce((prev, l) => { assert.ok(l <= prev + 1, `${lang}: heading level skipped (h${prev} → h${l})`); return l; }, 1);
  // Every illustration has a description.
  for (const m of html.matchAll(/<figure[^>]*>/g)) assert.match(m[0], /role="img" aria-label="[^"]{20,}"/, `${lang}: figure without description`);
  for (const m of html.matchAll(/<[a-z]+\b[^>]*\brole="img"[^>]*>/g)) assert.match(m[0], /aria-label="[^"]{20,}"/, `${lang}: illustration without description`);
  // Nothing is loaded from elsewhere; only links point outward.
  assert.doesNotMatch(html, /\bsrc="(https?:)?\/\//, `${lang}: external script or image`);
  for (const m of html.matchAll(/<link\b[^>]*href="(https?:)?\/\/[^>]*>/g)) {
    assert.match(m[0], /rel="(canonical|alternate)"/, `${lang}: external resource ${m[0]}`);
  }
  // Promises the product cannot keep.
  const banned = [
    /löscht (keine|nie)|never deletes|doesn’t delete files/i, /App-Sandbox\b(?![^.]*könnte)|in the App Sandbox\b(?![^.]*couldn)/i,
    /ganz auf deinem Mac|entirely on your Mac/i, /nichts verlässt|nothing (ever )?leaves/i,
    /Programmierwerkzeuge sind abgeschaltet|coding tools are switched off/i,
    /\bbeta\b|Version 0\.|version 0\.|noch holpern|still be bumpy/i,
    /revolution|nahtlos|seamless|mühelos|effortless/i, /DuckDuckGo/,
  ];
  for (const re of banned) assert.doesNotMatch(t, re, `${lang}: banned phrase ${re}`);
  // Locale URLs remain explicit and directly reachable through the language toggle.
  const head = html.match(/<header[\s\S]*?<\/header>/)[0];
  const other = lang === 'de' ? ['en/', 'en'] : ['../', 'de'];
  assert.ok(head.includes(`<a class="langsw" href="${other[0]}" hreflang="${other[1]}" lang="${other[1]}" data-lang="${other[1]}">`), `${lang}: header language toggle missing`);
  assert.doesNotMatch(html, /location\.(replace|assign)\(/, `${lang}: requested locale is redirected`);
  assert.match(html, /<ol class="steps">(?:<li\b[^>]*>[\s\S]*?<\/li>){3}<\/ol>/, `${lang}: getting-started steps missing`);
  // No emoji in the copy.
  assert.doesNotMatch(t, /\p{Extended_Pictographic}/u, `${lang}: emoji in copy`);
}
console.log('Site checks passed: DE/EN in step, headings, figure descriptions, no external resources, no banned promises or emoji.');

// Legal pages: toggle in the header, and the placeholder sentence is gone.
for (const f of ['datenschutz.html', 'impressum.html']) {
  const html = fs.readFileSync(path.join(site, f), 'utf8');
  assert.match(html.match(/<header[\s\S]*?<\/header>/)[0], /class="langsw" href="en\/" hreflang="en" lang="en" data-lang="en"/, `${f}: header language toggle missing`);
  assert.doesNotMatch(html, /getrennt zu beschreiben|Name oder Firma/, `${f}: working note or form label left`);
}
console.log('Legal pages: language toggle present, no working notes.');

// Exercise the actual inline playback controller with a deterministic browser clock.
// This catches scene mutations during Pause and accidental autoplay under reduced motion.
const vm = require('node:vm');
async function playbackChecks(html, lang) {
  const clockSource = html.split('// One clock drives waits and motion; paused time never advances a scene.')[1]
    .split('// End demo playback clock.')[0];
  const controls = html.slice(html.indexOf('const EST='), html.indexOf('/* Der Punkt in der Überschrift'));
  function harness(reduced) {
    let now = 0, serial = 0;
    const timers = new Map(), events = [], observers = [], marks = [];
    const schedule = (fn, ms) => { const id = ++serial; timers.set(id, { fn, due: now + ms }); return id; };
    const clock = vm.runInNewContext(clockSource + ';createDemoClock', {}) (() => now, schedule, id => timers.delete(id));
    const element = () => ({style:{},classList:{add(){},remove(){},toggle(){}},attributes:{},handlers:{},
      setAttribute(k,v){this.attributes[k]=v},addEventListener(k,v){this.handlers[k]=v},getAnimations(){return []},
      scrollTo(){},scrollWidth:0,clientWidth:600,clientHeight:400,offsetLeft:0,textContent:'Example',innerHTML:''});
    const nodes = new Map(), node = id => {if(!nodes.has(id))nodes.set(id,element());return nodes.get(id)};
    const keys = ['dl','brief','dateien','mail','buero','pdf'];
    const items = keys.map(k=>{const e=element();e.button=element();e.button.dataset={k};e.bar=element();e.description=element();return e});
    const animations=[{playState:'running',pause(){events.push('css paused')},play(){events.push('css resumed')}}];
    const mac=element();mac.getAnimations=()=>animations;
    const mark=()=>({setPaused(v){marks.push(v)},setState(){}});
    const context={RM:reduced,job:0,at:0,paused:false,clock,items,mac,scenOl:element(),scenD:element(),pauseB:element(),
      cur:element(),toast:element(),lnX:element(),xl:element(),mApp:element(),pwSub:element(),
      deskMark:mark(),lnMark:mark(),pwMark:mark(),toastMark:mark(),cx:1,cy:1,canim:0,
      cancelAnimationFrame(){},reset(){},lay(){},openLine(){},openPanel(){},chip(){return ''},
      answer(){events.push('static answer')},ANS:{brief:'letter',dateien:'files',mail:'draft'},
      narrow:{addEventListener(){}},curTo(){},IntersectionObserver:class{constructor(fn){observers.push(fn)}observe(){}}};
    context.$=(selector,parent)=>selector==='button'?parent.button:selector==='.bar i'?parent.bar:
      selector==='.d'?parent.description:selector==='button b'?parent.button:node(selector);
    context.wait=async(ms,my)=>{if(my!==context.job)throw 'stop';await clock.wait(ms);if(my!==context.job)throw 'stop'};
    context.S=Object.fromEntries(keys.map(k=>[k,{ids:[],run:async my=>{events.push('start '+k);await context.wait(100,my);events.push('finish '+k)}}]));
    vm.createContext(context);vm.runInContext(controls+';globalThis.controller={play,setPaused};',context);
    const advance=async ms=>{const end=now+ms;while(true){const next=[...timers].filter(([,v])=>v.due<=end).sort((a,b)=>a[1].due-b[1].due)[0];
      if(!next)break;now=next[1].due;timers.delete(next[0]);next[1].fn();for(let n=0;n<8;n++)await Promise.resolve()}
      now=end;for(let n=0;n<8;n++)await Promise.resolve()};
    return {context,events,marks,clock,advance,timers,observers};
  }
  const h=harness(false),c=h.context;
  const first=c.controller.play(0);await h.advance(40);c.controller.setPaused(true);
  const before=[...h.events],job=c.job;await h.advance(1000);
  assert.deepEqual(h.events,before,`${lang}: paused scene changed`);
  assert.equal(h.clock.time(),40,`${lang}: paused clock advanced`);
  c.controller.setPaused(false);await h.advance(59);
  assert.ok(!h.events.includes('finish dl'),`${lang}: resumed before remaining wait elapsed`);
  await h.advance(1);assert.ok(h.events.includes('finish dl'),`${lang}: did not resume same scene`);
  assert.equal(c.job,job,`${lang}: Resume restarted or skipped scene`);
  assert.deepEqual(h.marks,[true,true,true,true,false,false,false,false]);
  assert.ok(h.events.includes('css paused')&&h.events.includes('css resumed'));
  // Selecting a different scene cancels old work, including a paused wait.
  c.controller.setPaused(true);const old=c.job;c.items[1].button.handlers.click();await h.advance(100);
  assert.equal(c.job,old+1);assert.ok(h.events.includes('finish brief'));
  h.clock.cancel();await first;await Promise.resolve();
  const rm=harness(true);
  assert.equal(rm.observers.length,0,`${lang}: reduced motion installed autoplay observer`);
  assert.equal(rm.context.pauseB.hidden,true);
  for(const item of rm.context.items){item.button.handlers.click();await rm.advance(60000)}
  assert.ok(!rm.events.some(e=>e.startsWith('start ')),`${lang}: reduced motion ran animated scene`);
  assert.equal(rm.timers.size,0,`${lang}: reduced motion scheduled playback`);
  assert.equal(rm.context.at,5,`${lang}: reduced motion changed the selected example`);
}
(async()=>{
  for(const [lang,html] of Object.entries(pages))await playbackChecks(html,lang);
  // The canvas renderer participates in Pause without advancing its saved expression.
  const canvasContext={};vm.createContext(canvasContext);vm.runInContext(fs.readFileSync(path.join(site,'pippaMark.js'),'utf8'),canvasContext);
  const mark=Object.create(canvasContext.PippaMark.prototype);let paints=0,stops=0;
  Object.assign(mark,{reduced:true,canvas:{isConnected:true},_stop(){stops++},_paint(){paints++}});
  mark.setPaused(true);mark._wake();mark._draw(1000);assert.equal(paints,0);assert.equal(stops,2);
  mark.setPaused(false);assert.equal(paints,1);
  console.log('Playback checks passed: Pause freezes waits, motion and canvases; Resume continues; reduced motion is static.');
})().catch(error=>{console.error(error);process.exitCode=1});
