'use strict';
// Synthetic production JS: actual pinned original, never live fetch.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const rootOption = process.argv.indexOf('--resource-root');
const packaged = rootOption !== -1;
if (packaged && !process.argv[rootOption + 1]) throw Error('missing resource root');
const base = packaged ? path.resolve(process.argv[rootOption + 1]) : path.resolve(__dirname, '../Companion/TokenMonitorEngine');
const counters = { undici: 0, cookie: 0, db: 0, refresh: 0, spawn: 0, discovery: 0, ambient: 0, provider: 0, api: 0 };
// Source-only fixtures forbid unused transport constructors. Packaged mode
// resolves and loads the actual verified vendor closure without module stubs.
const Module = require('node:module');
const load = Module._load;
if (packaged) {
  require(path.join(base, 'lib/upstream/vendor.cjs')).installVendorResolver();
  const resolved = require.resolve('undici');
  assert(resolved.startsWith(path.join(base, 'vendor/node_modules') + path.sep));
  const transport = require('undici');
  assert.equal(typeof transport.fetch, 'function');
  assert.equal(typeof transport.EnvHttpProxyAgent, 'function');
} else {
  Module._load = function(name, ...args) {
    if (name === 'undici') return { EnvHttpProxyAgent: function() { counters.undici++; throw Error('forbidden'); }, fetch() { counters.undici++; throw Error('forbidden'); } };
    return load.call(this, name, ...args);
  };
}
const original = require(path.join(base, 'upstream/src/shared/providers/opencode/goApi.js'));
const payload = percent => ({ usage: { rolling: { percent }, weekly: { percent: 25 } } });
assert.equal(original.parseGoUsage(payload(null))[0].usedPercent, 0);
assert.equal(original.parseGoUsage(payload(101))[0].usedPercent, 100);
console.log('BASELINE: original null coerces to zero, 101 clamps to 100 (unsafe inputs reproduced)');
if (process.argv.includes('--baseline')) process.exit(0);
const bridge = require(path.join(base, 'lib/opencode-limits.cjs'));
const provider = require(path.join(base, 'upstream/src/shared/providers/opencode/limits.js'));
const sourceModule = require(path.join(base, 'lib/sources.cjs'));
const collect = require(path.join(base, 'lib/collect.cjs'));
const realProvider = provider.fetchOpenCodeLimits;
const realAPI = original.collectGoApi;
original.collectGoApi = input => { counters.api++; assert.deepEqual(input.env, {}); return realAPI(input); };
original.readGoApiKey = () => { counters.ambient++; throw Error('forbidden'); };
provider.fetchOpenCodeLimits = (options, deps) => {
  counters.provider++;
  assert.equal(options.opencodeAmbientEnabled, false);
  assert.equal(options.opencodeLocalLimitsEnabled, false);
  assert.deepEqual(deps.env, {});
  assert.equal(deps.opencodeReadGoApiKey(), '');
  assert.equal(Object.keys(options.opencodeProfiles).length, 1);
  assert.equal(options.opencodeProfiles.selected.cookie, undefined);
  for (const [hook, count] of Object.entries({ opencodeCollectGo: 'db', opencodeFetchGoWeb: 'cookie', opencodeFetchZen: 'cookie', refresh: 'refresh', spawn: 'spawn', discover: 'discovery' })) {
    const fn = deps[hook]; deps[hook] = (...args) => { counters[count]++; return fn(...args); };
  }
  return realProvider(options, deps);
};
async function main() {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'codex-next-opencode-test-')));
  const dirs = ['a', 'b'].map(name => { const dir = path.join(root, name); fs.mkdirSync(dir); return dir; });
  const write = (dir, key = 'synthetic-' + path.basename(dir)) => fs.writeFileSync(path.join(dir, 'auth.json'), JSON.stringify({ 'opencode-go': { type: 'api', key } }));
  dirs.forEach(dir => write(dir));
  const request = { operation: 'collectLimits', now: '2026-09-13T00:00:00Z', options: { timeoutMs: 1000, allowProviderNetwork: true } };
  const scope = () => ({ signal: new AbortController().signal, checkAborted() { if (this.signal.aborted) throw Error('cancelled'); } });
  const target = dir => ({ root: dir, declaredRoot: dir, pathRole: 'configDirectory', managed: true, accountId: path.basename(dir), sourceIds: [path.basename(dir)], providerIds: ['opencode'], evidence: {} });
  const response = (value, status = 200) => new Response(JSON.stringify(value), { status });
  const run = (value, options = {}) => bridge.collectOpenCodeLimits(options.target || target(dirs[0]), { ...request, ...options.request }, { fetch: options.fetch || (async () => response(value, options.status || 200)) }, options.scope || scope());
  const status = result => result.providers[0].status;
  const source = (dir, overrides = {}) => ({ id: path.basename(dir), providerId: 'opencode', kind: 'managedAccount', authority: 'upstream', canonicalPath: dir, pathRole: 'configDirectory', accountId: path.basename(dir), ...overrides });
  const context = { clientIds: new Set(['opencode', 'codex', 'claude']), operation: 'collectLimits', catalog: { collector: { clientSourceRoots() { counters.discovery++; throw Error('forbidden'); } } } };
  const saved = { ...process.env };
  try {
    for (const key of ['HOME', 'XDG_DATA_HOME', 'OPENCODE_AUTH_CONTENT', 'TOKEN_MONITOR_OPENCODE_COOKIE', 'TOKEN_MONITOR_OPENCODE_API_KEY']) process.env[key] = 'poison-synthetic';
    for (const percent of [null, '', '2', false, true, -1, 101, Infinity, NaN]) {
      assert.throws(() => bridge.validateUsage(payload(percent)));
      assert.equal(status(await run(payload(percent))), 'unavailable');
    }
    for (const percent of [0, 12.5, 100]) {
      const result = await run(payload(percent));
      assert.equal(status(result), 'ok');
      assert.deepEqual(result.providers[0].windows.map(w => w.usedPercent), original.parseGoUsage(payload(percent)).map(w => w.usedPercent));
      assert.equal(result.providers[0].balanceUsd, null);
      assert.equal(result.providers[0].windows.length, 2);
    }
    for (const usage of [{}, { rolling: { percent: 2 } }, { rolling: {}, weekly: { percent: 2 } }, { rolling: null, weekly: { percent: 2 } }]) {
      const result = await run({ usage }); assert.equal(status(result), 'unavailable'); assert.equal(result.providers[0].windows.length, 0);
    }
    const limited = payload(0); limited.usage.rolling = { status: 'rate-limited' };
    assert.equal((await run(limited)).providers[0].windows[0].usedPercent, 100);
    for (const reset of [null, '', 12, false, {}, 'bad', '2026-02-31T00:00:00Z']) { const body = payload(1); body.usage.rolling.resetsAt = reset; assert.equal(status(await run(body)), 'unavailable'); }
    const resetBody = payload(0); resetBody.usage.rolling.resetsAt = '2026-09-14T00:00:00Z';
    assert.equal((await run(resetBody)).providers[0].windows[0].resetsAt, '2026-09-14T00:00:00.000Z');
    for (const [code, body, expected] of [[401, {}, 'unauthorized'], [403, {}, 'unavailable'], [403, {error:{type:'EntitlementError'}}, 'notConfigured'], [429, {}, 'sourceRateLimited']]) assert.equal(status(await run(body, { status: code })), expected);
    assert.throws(() => bridge.strictJSON('{"usage":{},"usage":{}}'));
    assert.equal(status(await run(null, {fetch: async () => new Response('{"usage":{},"usage":{}}')})), 'unavailable');
    const results = await Promise.all(dirs.map((dir, i) => run(payload(i * 40), { target: target(dir), fetch: async (url, init) => {
      assert.equal(url, 'https://opencode.ai/zen/go/v1/usage'); assert.equal(init.method, 'GET'); assert.equal(init.redirect, 'error');
      assert.equal(init.headers.Authorization, 'Bearer synthetic-' + path.basename(dir)); assert.equal(init.headers.Cookie, undefined);
      return response(payload(i * 40));
    } })));
    assert.deepEqual(results.map(r => r.providers[0].windows[0].usedPercent), [0, 40]);
    assert.doesNotMatch(JSON.stringify(results), /synthetic-|sha256|go-api|accountKey|accountIdentity|credentialFingerprint/);
    const resolved = sourceModule.resolveSources({ ...request, sources: dirs.map(dir => source(dir)) }, context);
    assert.deepEqual(resolved.sources.map(s => s.status), ['ok', 'ok']);
    assert.deepEqual(sourceModule.buildTargets(resolved.sources).map(t => t.root), dirs);
    for (const operation of ['collectUsage', 'capabilities']) assert.equal(sourceModule.normalizeSource(source(dirs[0]), 0, {...context, operation}).status, 'error');
    for (const override of [{providerId:'codex'}, {providerId:'claude'}, {kind:'agentLogs'}, {authority:'custom'}, {accountId:undefined}]) assert.equal(sourceModule.normalizeSource(source(dirs[0], override), 0, context).status, 'error');
    const alias = path.join(root, 'alias'); fs.symlinkSync(dirs[0], alias);
    assert.equal(sourceModule.resolveSources({...request,sources:[source(dirs[0]),source(alias)]},context).sources[1].status, 'excluded');
    const nested = path.join(dirs[0], 'nested'); fs.mkdirSync(nested);
    assert.equal(sourceModule.resolveSources({...request,sources:[source(dirs[0]),source(nested)]},context).sources[1].status, 'excluded');
    const collected = await collect.collectLimitsOnce({}, request, {fetch: async () => response(payload(0))}, scope(), [target(dirs[0])]);
    assert.equal(collected.targets[0].accountId, 'a'); assert.equal(collected.targets[0].sourceId, 'a'); assert.equal(collected.targets[0].providerId, 'opencode');
    assert.equal(status(await run({}, {status:302})), 'unavailable');
    assert.equal((await run({}, {fetch:async()=>new Response('x'.repeat(1_048_577))})).reasonCode, 'body_limit');
    assert.equal((await run({}, {fetch:async()=>new Response('{}',{headers:{'content-length':'1048577'}})})).reasonCode, 'body_limit');
    assert.equal((await run({}, {fetch:async()=>new Promise(()=>{}),request:{options:{timeoutMs:15}}})).reasonCode, 'timeout');
    assert.equal((await run({}, {fetch:async()=>new Response(new ReadableStream({start(){}})),request:{options:{timeoutMs:15}}})).reasonCode, 'timeout');
    const cancelled = new AbortController(); const promise = run({}, {fetch:async()=>{cancelled.abort();return response(payload(2));},scope:{signal:cancelled.signal}});
    await assert.rejects(promise, error => error.code === 'cancelled');
    let sent = 0; await assert.rejects(bridge.guardedFetch('synthetic',request,{fetch(){sent++;}},new AbortController().signal,()=>{})('https://example.invalid/')); assert.equal(sent,0);
    assert.equal((await run({}, {request:{options:{allowProviderNetwork:false}}})).reasonCode, 'network_disabled');
    const rotating = target(dirs[0]);
    assert.equal((await run(payload(0),{target:rotating,fetch:async()=>{rotating.accountId='b';return response(payload(0));}})).reasonCode,'target_changed');
    assert.equal((await run(payload(0),{fetch:async()=>{write(dirs[0],'rotated-synthetic');return response(payload(0));}})).reasonCode,'auth_changed'); write(dirs[0]);
    assert.equal((await run(payload(0),{fetch:async()=>{fs.unlinkSync(path.join(dirs[0],'auth.json'));return response(payload(0));}})).reasonCode,'auth_changed');
    assert.equal((await run(payload(0))).reasonCode,'auth_missing');
    fs.symlinkSync(path.join(dirs[1],'auth.json'),path.join(dirs[0],'auth.json'));
    assert.equal((await run(payload(0))).reasonCode,'invalid_auth_file'); fs.unlinkSync(path.join(dirs[0],'auth.json'));
    for (const [raw, reason] of [['{}','provider_missing'],['null','malformed_bundle'],['{"opencode-go":{"type":"oauth","key":"synthetic"}}','malformed_bundle'],['{"opencode-go":{},"opencode-go":{}}','ambiguous_json']]) { fs.writeFileSync(path.join(dirs[0],'auth.json'),raw);assert.equal((await run(payload(0))).reasonCode,reason); }
    write(dirs[0]);
    assert.equal((await run(payload(0),{fetch:async()=>{
      const data = fs.readFileSync(path.join(dirs[0],'auth.json'));
      fs.writeFileSync(path.join(dirs[0],'auth.json'),data);
      return response(payload(0));
    }})).reasonCode,'auth_changed');
    fs.writeFileSync(path.join(dirs[0],'auth.json'),'x'.repeat(1_048_577));
    assert.equal((await run(payload(0))).reasonCode,'invalid_auth_file'); write(dirs[0]);
    const switched = target(dirs[0]); switched.declaredRoot = alias;
    assert.equal((await run(payload(0),{target:switched,fetch:async()=>{
      fs.unlinkSync(alias); fs.symlinkSync(dirs[1],alias); return response(payload(0));
    }})).reasonCode,'auth_changed');
    const wrapped = provider.fetchOpenCodeLimits;
    provider.fetchOpenCodeLimits = async (...args) => ({...await wrapped(...args),accountKey:'mismatch'});
    assert.equal((await run(payload(0))).reasonCode,'identity_mismatch');
    provider.fetchOpenCodeLimits = async (...args) => [await wrapped(...args)];
    assert.equal((await run(payload(0))).reasonCode,'identity_mismatch');
    provider.fetchOpenCodeLimits = wrapped;
    for (const name of ['undici','cookie','db','refresh','spawn','discovery','ambient']) assert.equal(counters[name],0,name);
    assert(counters.api > 20); assert.equal(counters.provider,counters.api);
    console.log(`PASS synthetic production JS with ${packaged ? 'actual packaged vendor closure' : 'forbidden undici stub'}; actual original provider/API calls:`, counters.provider, counters.api);
    console.log('PASS strict values/duplicate JSON, statuses, two targets/role/overlap, binding/rotation/deletion/symlink, URL/redirect/body/timeout/cancel; forbidden counters all zero');
  } finally { process.env = saved; fs.rmSync(root,{recursive:true,force:true}); }
}
main().catch(error => { console.error('FAIL synthetic OpenCode regression:', error.code || error.name); process.exitCode = 1; });
