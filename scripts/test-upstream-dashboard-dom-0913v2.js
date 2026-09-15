'use strict';
// Portable, synthetic-only real DOM acceptance. Caller supplies Playwright via NODE_PATH.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {pathToFileURL} = require('node:url');
const {chromium} = require('playwright');
const root = path.resolve(__dirname,'..');
const hostile = '</script><script>window.pwned=1</script>"雪\u2028';
function period(n) { return {totalTokens:n, costUsd:null, outputTokens:0, clients:{Codex:n-10,Claude:10},clientCosts:{Codex:1,Claude:null},clientOutputs:{Codex:0},models:{alpha:1,beta:9,[hostile]:n-10},modelCosts:{alpha:0},sessions:{one:{client:'Codex',sessionId:'safe-session-1',totalTokens:n-3,costUsd:2,messageCount:4,models:{alpha:n-3},projectId:'p1',projectLabel:'Project one',title:'NEVER RENDER TRANSCRIPT TITLE'},two:{client:'Claude',sessionId:'safe-session-2',totalTokens:3}},projects:{p1:{label:'Project one',tokens:n-3,costUsd:2,clients:{Codex:n-3}},p2:{label:'Project two',tokens:3}},accounts:{'safe-account':{tokens:n,costUsd:null}}}; }
const fixture = {schemaVersion:1,collectedAt:'2026-09-13T00:00:00Z',timezone:'UTC',status:'partial',sources:[{coverage:'unknown',reasonCode:'UNKNOWN_COST'}],coverage:{cost:'unknown',days:[{date:'2026-09-10',status:'known'},{date:'2026-09-11',status:'unknown'},{date:'2026-09-12',status:'known'},{date:'2026-09-13',status:'known'}]},payload:{aggregate:{periods:{today:period(30),month:period(300),allTime:period(3000)},history:{daily:[{date:'2026-09-10',tokens:null},{date:'2026-09-11',tokens:90,perClient:{Codex:{tokens:60},Claude:{tokens:30}},perModel:{alpha:{tokens:20},beta:{tokens:30},[hostile]:{tokens:40}}},{date:'2026-09-12',tokens:0,cost:null},{date:'2026-09-13',tokens:20,cost:null}]}},usage:{today:period(999999)},history:{daily:[{date:'2026-09-13',tokens:999999}]}}};
const annotations=[{date:'2026-09-12',kind:'regular',text:'Original regular source text'},{date:'2026-09-11',kind:'banked',text:hostile}];
(async()=>{
 const browser=await chromium.launch();
 try {
 const context=await browser.newContext({viewport:{width:900,height:650}});
 const requests=[];
 await context.route(/^https?:/, route=>{requests.push(route.request().url());return route.abort();});
 const page=await context.newPage(); const errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.goto(pathToFileURL(path.join(root,'Resources/UpstreamCharts/standalone.html')).href);
 const render=async (data=fixture,language) => page.evaluate(({data,language,annotations})=>{const before=JSON.stringify(data); const resetBefore=JSON.stringify(annotations); const result=window.__renderTrend(data,{language,resetAnnotations:annotations}); if(JSON.stringify(data)!==before || JSON.stringify(annotations)!==resetBefore)throw Error('Input mutated'); return result;},{data,language,annotations});
 const text=id=>page.locator('#'+id).innerText();
 const cell=date=>page.locator(`[data-d="${date}"]`);
 await render();assert.equal(await page.locator('html').getAttribute('lang'),'zh');
 assert.equal(await page.getByRole('button',{name:'概览',exact:true}).getAttribute('aria-pressed'),'true');
 assert.match(await cell('2026-09-13').getAttribute('class'),/known/);
 assert.doesNotMatch(await cell('2026-09-13').getAttribute('class'),/partial|unknown/);
 await cell('2026-09-13').hover();assert.match(await text('selection'),/20 Token · 已确认/);assert.match(await text('selection'),/费用（美元）: 未提供/);
 await cell('2026-09-11').focus();assert.match(await text('selection'),/已观察值，完整性未确认/);
 await cell('2026-09-12').click();assert.match(await text('selection'),/0 Token · 已确认/);assert.match(await text('selection'),/常规重置/);
 await cell('2026-09-11').click();assert.match(await text('selection'),/储备重置/);assert.match(await text('month'),/110 已观察 Token.*完整性未确认/);
 await cell('2026-09-10').focus();await page.keyboard.press('Enter');assert.match(await text('selection'),/Token 未提供/);
 await page.getByRole('button',{name:'趋势',exact:true}).click();assert.equal(await page.locator('#overview').isVisible(),false);assert.equal(await page.locator('#legend span').count(),2);
 await page.locator('#group').selectOption('model');assert.equal(await page.locator('#legend span').count(),3);assert.ok((await text('legend')).includes(hostile));assert.ok(await page.locator('#bars svg').count());
 await page.locator('#from').fill('2026-09-12');await page.locator('#from').dispatchEvent('change');assert.match(await text('bars'),/未提供/);
 await page.locator('#to').fill('2026-09-14');await page.locator('#to').dispatchEvent('change');assert.match(await text('bars'),/日期范围无效/);
 await page.getByRole('button',{name:'明细',exact:true}).click();
 for (const [name,n] of [['today',30],['month',300],['allTime',3000]]) {
 await page.locator('#period').selectOption(name);let d=await text('dimensions');assert.ok(d.includes(n.toLocaleString('zh-CN')));assert.ok(d.includes('safe-session-1'));assert.ok(d.includes('Project one'));assert.ok(d.includes('safe-account'));assert.ok(d.includes((n-3).toLocaleString('zh-CN')));assert.doesNotMatch(d,/999999|NEVER RENDER/);assert.ok(await page.locator('#dimensions table tr').count()>=15);
 }
 await page.locator('#period').selectOption('day');await page.locator('#date').fill('2026-09-14');await page.locator('#date').dispatchEvent('change');assert.match(await text('selection'),/日期无效/);
 await page.locator('#date').fill('2026-09-09');await page.locator('#date').dispatchEvent('change');assert.match(await text('selection'),/Token 未提供/);
 await page.locator('#date').evaluate(el=>{el.value='2026-02-30';el.dispatchEvent(new Event('change'));});assert.match(await text('selection'),/日期无效/);
 await render(fixture,'en');assert.equal(await page.locator('html').getAttribute('lang'),'en');assert.ok(await page.getByRole('button',{name:'Details',exact:true}).count());await page.locator('#period').selectOption('today');assert.match(await text('dimensions'),/Not provided/);assert.match(await text('dimensions'),/Cost \(USD\)/);
 await page.getByRole('button',{name:'Overview',exact:true}).click();await cell('2026-09-12').click();assert.match(await text('selection'),/Public regular reset/);await cell('2026-09-11').click();assert.match(await text('selection'),/observed value, completeness unconfirmed/);assert.match(await text('selection'),/Public banked reset/);
 const missing=structuredClone(fixture);missing.payload.aggregate.periods.today={totalTokens:null,clients:{bad:null},models:[],sessions:null};await render(missing,'en');await page.getByRole('button',{name:'Details',exact:true}).click();await page.locator('#period').selectOption('today');assert.match(await text('dimensions'),/Supplied token value: Not provided/);assert.equal(await page.locator('#dimensions table').count(),1);
 for(const value of [null,'4',-1,Infinity,NaN]) {const malformed=structuredClone(fixture);malformed.payload.aggregate.history.daily[2].tokens=value;await render(malformed,'en');assert.match(await cell('2026-09-12').getAttribute('class'),/unknown/);}
 const noCoverage=structuredClone(fixture);delete noCoverage.coverage;await render(noCoverage,'en');assert.match(await cell('2026-09-12').getAttribute('class'),/unknown/);
 const bounded=structuredClone(fixture);bounded.payload.aggregate.periods.today.models=Object.fromEntries(Array.from({length:45},(_,i)=>['m'+i,i]));await render(bounded,'en');assert.match(await text('dimensions'),/5 more entries omitted/);
 const fallback=structuredClone(fixture);delete fallback.payload.aggregate;fallback.payload.usage.history=fixture.payload.aggregate.history;await render(fallback,'en');assert.match(await text('dimensions'),/999,999/);
 // Exercise the supplied original collector shape through actual SVG hover and details.
 // Portable projection of the synthetic original collector response; values/period and day shapes preserved.
const enginePeriod = {"capabilities":{"tokenComponents":true,"throughput":true},"totalTokens":130,"costUsd":0,"cacheReadTokens":20,"cacheWriteTokens":0,"outputTokens":30,"unclassifiedTokens":0,"timedTokens":130,"timedOutputTokens":30,"timedDurationMs":1000,"clients":{"codex":130},"clientCosts":{},"clientCacheReads":{"codex":20},"clientCacheWrites":{},"clientOutputs":{"codex":30},"clientUnclassifiedTokens":{},"models":{"gpt-5.4":130},"modelCosts":{},"modelCacheReads":{"gpt-5.4":20},"modelCacheWrites":{},"modelOutputs":{"gpt-5.4":30},"modelUnclassifiedTokens":{},"clientModels":{"codex":{"gpt-5.4":130}},"clientModelCosts":{},"projects":{"opaque-244210e48437b6556980a702":{"label":"opaque-244210e48437b6556980a702","tokens":130,"costUsd":0,"clients":{"codex":130}}},"sessions":{"opaque-deb796c0ba7af201b9f3edbe":{"client":"codex","sessionId":"opaque-0a9099c0e3a5c4355f05a10c","totalTokens":130,"costUsd":0,"messageCount":1,"inputTokens":80,"outputTokens":30,"cacheReadTokens":20,"cacheWriteTokens":0,"reasoningTokens":0,"startedAt":"2026-09-12T16:00:00.000Z","lastUsedAt":"2026-09-13T00:00:02.000Z","projectId":"opaque-70a7729322b4764bb2d0ac22","projectLabel":"opaque-244210e48437b6556980a702","title":"opaque-e3b0c44298fc1c149afbf4c8","sessionKind":"","models":{"gpt-5.4":130},"modelCosts":{},"providers":{"openai":130}}}};
const engine = {schemaVersion:1,collectedAt:"2026-09-13T00:00:10Z",timezone:"Asia/Shanghai",status:"ok",coverage:{"entries":[{"sourceId":"managed-a","providerId":"codex","date":"2026-09-13","metric":"tokens","status":"known"},{"sourceId":"managed-a","providerId":"codex","date":"2026-09-13","metric":"cost","status":"unknown"},{"sourceId":"managed-a","providerId":"codex","date":"2026-09-13","metric":"quota","status":"unknown"}],"days":[{"date":"2026-09-13","status":"known"}],"cost":"unknown"},payload:{aggregate:Object.fromEntries(['today','month','allTime'].map(name=>[name,JSON.parse(JSON.stringify(enginePeriod))])),history:{daily:[{"date":"2026-09-13","tokens":130,"cost":0,"messages":1,"cacheReadTokens":20,"cacheWriteTokens":0,"outputTokens":30,"unclassifiedTokens":0,"tokenComponentsAvailable":true,"activeTimeMs":1000,"perClient":{"codex":{"tokens":130,"cost":0,"messages":1,"unclassifiedTokens":0,"cacheReadTokens":20,"outputTokens":30}},"perModel":{"gpt-5.4":{"tokens":130,"cost":0,"unclassifiedTokens":0,"cacheReadTokens":20,"outputTokens":30}},"tokenIntensity":4,"costIntensity":0,"intensity":0}]}}};
 for(const language of [undefined,'en']) {
   const en=language==='en', unavailable=en ? /Cost \(USD\): Not provided/ : /费用（美元）: 未提供/;
   for(const [coverage,value] of [['unknown',0],[undefined,0],['unknown',2.5],[undefined,2.5],['known',0],['known',2.5],['partial',2.5],['known',null],['known','4'],['known',-1],['known',Infinity],['known',NaN],['known',undefined]]) {
     const x=structuredClone(engine);x.coverage.cost=coverage;x.payload.history.daily[0].cost=value;
     for(const name of ['today','month','allTime']) x.payload.aggregate[name].costUsd=value;
     await render(x,language);
     await page.getByRole('button',{name:en?'Overview':'概览',exact:true}).click();
     await cell('2026-09-13').hover();
     const valid=typeof value==='number' && Number.isFinite(value) && value>=0;
     const expected=!valid || !['known','partial'].includes(coverage) ? unavailable : coverage==='known' ? (en ? new RegExp('Cost \\(USD\\): '+value+' · known') : new RegExp('费用（美元）: '+value+' · 已确认')) : (en ? /Observed cost \(USD\): 2.5 · completeness unconfirmed/ : /已观察费用（美元）: 2.5 · 完整性未确认/);
     assert.match(await text('selection'),expected);assert.match(await text('selection'),en?/130 Token · known/:/130 Token · 已确认/);
     assert.doesNotMatch(await cell('2026-09-13').getAttribute('class'),/unknown|partial/);
     assert.match(await cell('2026-09-13').getAttribute('aria-label'),expected);
     await cell('2026-09-13').click();
     await page.getByRole('button',{name:en?'Details':'明细',exact:true}).click();
     for(const name of ['day','today','month','allTime']) {
       await page.locator('#period').selectOption(name);assert.match(await text('dimensions'),expected);
       assert.match(await text('dimensions'),/130/);
       if(name!=='day') {assert.equal(await page.locator('#dimensions table').count(),4);assert.match(await text('dimensions'),/codex/);assert.match(await text('dimensions'),/gpt-5.4/);}
       if(!['known','partial'].includes(coverage)) assert.doesNotMatch(await text('dimensions'),en?/Cost \(USD\): [0-9]/:/费用（美元）: [0-9]/);
     }
   }
   const zero=structuredClone(engine);zero.payload.history.daily[0].tokens=0;
   await render(zero,language);assert.match(await cell('2026-09-13').getAttribute('aria-label'),en?/0 Token · known/:/0 Token · 已确认/);
   const scoped=structuredClone(engine);scoped.coverage.days[0].cost='known';scoped.coverage.periods={today:{cost:'partial'}};
   scoped.payload.aggregate.today.costUsd=2.5;
   const session=Object.values(scoped.payload.aggregate.today.sessions)[0];session.coverage={cost:'known'};
   await render(scoped,language);assert.match(await cell('2026-09-13').getAttribute('aria-label'),en?/Cost \(USD\): 0 · known/:/费用（美元）: 0 · 已确认/);
   await page.locator('#period').selectOption('today');assert.match(await text('dimensions'),en?/Observed cost \(USD\): 2.5 · completeness unconfirmed/:/已观察费用（美元）: 2.5 · 完整性未确认/);
   assert.match(await text('dimensions'),en?/Cost \(USD\): 0 · known/:/费用（美元）: 0 · 已确认/);
 }
 // Exercise the native string API with a real dimension payload over the observed 10,085,083-byte response.
 const maximumBytes=16*1024*1024;const large=structuredClone(engine);
 for(let i=0;i<74000;i++)large.payload.aggregate.allTime.models['model-'+String(i).padStart(6,'0')+'-'+'x'.repeat(128)]=0;
 const largeJSON=JSON.stringify(large);assert(Buffer.byteLength(largeJSON)>10085083 && Buffer.byteLength(largeJSON)<maximumBytes);
 await render(largeJSON,'en');await page.getByRole('button',{name:'Overview',exact:true}).click();await cell('2026-09-13').hover();assert.match(await text('selection'),/130 Token · known/);
 await page.getByRole('button',{name:'Details',exact:true}).click();await page.locator('#period').selectOption('allTime');assert.match(await text('dimensions'),/more entries omitted/);
 const countLargeParses=async()=>page.evaluate(()=>{
   const parse=JSON.parse, Encoder=TextEncoder;window.largeParses=0;window.largeEncodes=0;
   JSON.parse=function(value,...args){if(typeof value==='string'&&value.length>1000000)window.largeParses++;return parse.call(this,value,...args);};
   window.TextEncoder=class extends Encoder{encode(value){if(typeof value==='string'&&value.length>1000000)window.largeEncodes++;return super.encode(value);}};
 });
 await countLargeParses();
 await page.evaluate(data=>window.__renderTrend(data,{snapshotID:'realm:1',language:'en'}),largeJSON);
 const reused=await page.evaluate(()=>{
   for(let i=0;i<8;i++)window.__renderTrend(null,{snapshotID:'realm:1',width:500+i*35,height:260+i,language:i%2?'zh':'en',resetAnnotations:[{date:'2026-09-13',kind:'regular',text:'reset '+i}]});
   return [window.largeParses,window.largeEncodes];
 });
 assert.deepEqual(reused,[1,1]);assert.match(await text('selection'),/reset 7/);assert.equal(await page.locator('html').getAttribute('lang'),'zh');
 await page.evaluate(data=>window.__renderTrend(data,{snapshotID:'realm:2',language:'en'}),largeJSON+'\n');
 assert.deepEqual(await page.evaluate(()=>[window.largeParses,window.largeEncodes]),[2,2]);
 assert.equal(await page.evaluate(()=>{try{window.__renderTrend(null,{snapshotID:'realm:1',language:'en'});return null;}catch(e){return e.message;}}),'Dashboard snapshot unavailable');
 await page.reload();
 assert.equal(await page.evaluate(()=>{try{window.__renderTrend(null,{snapshotID:'realm:2',language:'en'});return null;}catch(e){return e.message;}}),'Dashboard snapshot unavailable');
 await countLargeParses();
 await page.evaluate(data=>window.__renderTrend(data,{snapshotID:'next:1',language:'en'}),largeJSON);
 assert.deepEqual(await page.evaluate(()=>[window.largeParses,window.largeEncodes]),[1,1]);
 assert.match(await cell('2026-09-13').getAttribute('aria-label'),/130 Token · known/);
 console.log('PASS real DOM snapshot protocol: same >10MB payload +8 width/height/language/reset updates parse/encode once, next snapshot twice, page reload rejects missing identity and reinstalls/parses once.');
 const baseJSON=JSON.stringify(engine);const exactLimit=baseJSON+' '.repeat(maximumBytes-Buffer.byteLength(baseJSON));
 await render(exactLimit,'en');
 for(const oversized of [exactLimit+' ',JSON.stringify({...engine,encodingProbe:'汉'.repeat(6000000)})]) {
   const rejection=await page.evaluate(data=>{try{window.__renderTrend(data,{language:'en'});return null;}catch(e){return e.message;}},oversized);
   assert.equal(rejection,'Dashboard too large');
 }
 console.log('PASS >10 MB real dimensions, exact 16 MiB accepted, +1 byte and multibyte byte overflow rejected; native string API, not native WKWebView proof.');
 assert.equal(await page.evaluate(()=>window.pwned),undefined);assert.deepEqual(errors,[]);assert.deepEqual(requests,[]);
 assert.ok((await render([{date:'2026-09-12',tokens:0}],'en')).startsWith('<svg'));assert.equal(await page.locator('#calendar svg').count(),1);
 console.log('PASS real Chromium DOM: local HTML/CSS/vendor/adapter; zh/en; SVG hover/focus/click/keyboard; range/group/period; actual dimensions; canonical/fallback; unknown/zero/cost; malformed/missing; bounded rows; escaping; immutable input; legacy; zero HTTP(S).');
 await context.close();
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
