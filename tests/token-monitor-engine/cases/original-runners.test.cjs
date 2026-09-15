'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { EventEmitter } = require('node:events');
const { PassThrough } = require('node:stream');
const cp = require('node:child_process');
const f = require('./helpers/fixtures.cjs');
const calls = [];
// Inject the process collaborator BEFORE the original collector captures spawn.
// Every parser, option builder and original runTokscale/runGraph body is real.
cp.spawn = (bin, args, options) => {
  assert.ok(bin.endsWith('/bin/tokscale'));
  assert.equal(options.env.PATH, '');
  assert.equal(options.env.TOKEN_MONITOR_UPSTREAM_ROOT, undefined);
  const root = options.env.TOKSCALE_EXTRA_DIRS?.replace(/^codex:/, '') || options.env.CODEX_HOME;
  const fixture = JSON.parse(fs.readFileSync(path.join(root, 'scanner-output.json'), 'utf8'));
  calls.push({ root, args, cwd: process.cwd(), home: options.env.HOME, extra: options.env.TOKSCALE_EXTRA_DIRS });
  const child = new EventEmitter();
  child.stdout = new PassThrough(); child.stderr = new PassThrough(); child.stdin = new PassThrough();
  child.kill = () => true; child.exitCode = null; child.signalCode = null;
  process.nextTick(() => {
    child.stdout.end(JSON.stringify(args[0] === 'graph' ? fixture.graph : fixture.usage));
    child.exitCode = 0; child.emit('exit', 0, null); child.emit('close', 0, null);
  });
  return child;
};
const { handleRequest } = require('../lib/handler.cjs');

test('original private scan and graph runners see two managed roots and exact logRoot without fallback', async () => {
  const home = f.makeHome();
  try {
    const layout = f.twoToolsTwoHomes(home);
    for (const [root, tokens] of [[layout.codexA, 19], [layout.codexB, 37], [layout.logs, 5]]) {
      fs.writeFileSync(path.join(root, 'scanner-output.json'), JSON.stringify({
        usage: f.usageSnapshot(tokens, { client: 'codex' }),
        graph: f.historyGraph(tokens === 19 ? '2026-09-12' : '2026-09-13', tokens, { client: 'codex' })
      }));
    }
    const response = await handleRequest(f.baseRequest(home, { sources: layout.sources.slice(1) }));
    assert.equal(response.payload.aggregate.today.totalTokens, 56);
    assert.deepEqual(response.payload.history.daily.map(day => day.tokens), [19, 37]);
    assert.equal(calls.filter(call => call.args[0] === 'graph').length, 2);
    for (const root of [layout.codexA, layout.codexB]) assert.equal(new Set(calls.filter(call => call.root === root).map(call => call.home)).size, 1); 
    assert.ok(calls.every(call => call.cwd === call.home && call.home !== home));
    const logResponse = await handleRequest(f.baseRequest(home, { sources: [f.source({ id: 'exact', providerId: 'codex', canonicalPath: layout.logs })] }));
    assert.equal(logResponse.payload.aggregate.today.totalTokens, 5);
    assert.ok(calls.slice(-4).every(call => call.extra === `codex:${layout.logs}`));
    assert.ok(calls.slice(-4).every(call => call.home !== layout.logs));
  } finally { f.cleanup(home); }
});
