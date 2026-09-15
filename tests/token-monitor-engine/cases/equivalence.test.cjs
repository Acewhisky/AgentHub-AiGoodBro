'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const test = require('node:test');

const { handleRequest } = require('../lib/handler.cjs');
const loader = require('../lib/upstream/loader.cjs');
const collect = require('../lib/collect.cjs');
const { createRequestScope } = require('../lib/runtime/scope.cjs');
const fixtures = require('./helpers/fixtures.cjs');

// The point of this file: prove the bridge is a transport, not a transform. The
// same fixture runners are handed to the bridge and to a direct upstream call,
// and the periods must come back byte-for-byte equal.

function scopeFor(timeoutMs = 20000) {
  return createRequestScope({ timeoutMs }).start();
}

test('bridge usage periods are identical to a direct upstream collect', async () => {
  const home = fixtures.makeHome();
  try {
    const layout = fixtures.twoToolsTwoHomes(home);
    const runner = fixtures.runners({ today: 111, month: 222, allTime: 333 });
    const request = fixtures.baseRequest(home, { sources: layout.sources });

    const scope = scopeFor();
    const response = await handleRequest(request, { scope, signal: scope.signal, ...runner });
    scope.dispose();

    assert.equal(response.status, 'ok');
    assert.equal(response.payload.usage.targets.length, 3);

    // Reproduce the bridge's own call for each target and compare periods.
    const upstream = loader.load();
    const todayKey = '2026-09-13';
    for (let index = 0; index < response.payload.usage.targets.length; index += 1) {
      const reported = response.payload.usage.targets[index];
      const target = {
        root: index === 0 ? layout.logs : index === 1 ? layout.codexA : layout.codexB,
        pathRole: index === 0 ? 'logRoot' : 'codexHome',
        providerIds: [index === 0 ? 'claude' : 'codex'],
        sourceIds: [index === 0 ? 'claude-logs' : index === 1 ? 'codex-a' : 'codex-b']
      };
      const direct = await upstream.collector.collectUsageOnce(
        collect.usageOptionsFor(target, request, runner, scope, todayKey)
      );
      assert.deepStrictEqual(reported.today, JSON.parse(JSON.stringify(direct.today)), `today mismatch for target ${index}`);
      assert.deepStrictEqual(reported.month, JSON.parse(JSON.stringify(direct.month)), `month mismatch for target ${index}`);
      assert.deepStrictEqual(reported.allTime, JSON.parse(JSON.stringify(direct.allTime)), `allTime mismatch for target ${index}`);
    }
  } finally {
    fixtures.cleanup(home);
  }
});

test('bridge history is identical to a direct upstream history call', async () => {
  const home = fixtures.makeHome();
  try {
    const layout = fixtures.twoToolsTwoHomes(home);
    const runner = fixtures.runners({ graphTokens: 42 });
    const request = fixtures.baseRequest(home, { sources: [layout.sources[0]] });

    const scope = scopeFor();
    const response = await handleRequest(request, { scope, signal: scope.signal, ...runner });
    scope.dispose();

    const upstream = loader.load();
    const direct = await upstream.collector.collectHistoryOnce({
      clients: 'claude',
      runGraph: runner.runGraph,
      todayKey: '2026-09-13',
      capDays: 370,
      commandTimeoutMs: 20000,
      historyEnabled: true,
      logger: () => {}
    });

    const bridged = response.payload.history;
    assert.ok(bridged, 'history should be present');
    assert.deepStrictEqual(bridged.daily, direct.daily);
    assert.deepStrictEqual(bridged.summary, direct.summary);
  } finally {
    fixtures.cleanup(home);
  }
});

test('two tools and two managed homes are collected as separate targets', async () => {
  const home = fixtures.makeHome();
  try {
    const layout = fixtures.twoToolsTwoHomes(home);
    const runner = fixtures.runners({ today: 10, month: 20, allTime: 30 });
    const request = fixtures.baseRequest(home, { sources: layout.sources });

    const scope = scopeFor();
    const response = await handleRequest(request, { scope, signal: scope.signal, ...runner });
    scope.dispose();

    const targets = response.payload.usage.targets;
    assert.equal(targets.length, 3);
    assert.deepStrictEqual(targets.map((entry) => entry.providerIds), [['claude'], ['codex'], ['codex']]);
    assert.deepStrictEqual(targets.map((entry) => entry.sourceIds), [['claude-logs'], ['codex-a'], ['codex-b']]);

    // Each managed home is scanned on its own, so the aggregate is the sum.
    assert.equal(response.payload.aggregate.today.totalTokens, 30);
    assert.equal(response.payload.aggregate.month.totalTokens, 60);
    assert.equal(response.payload.aggregate.allTime.totalTokens, 90);

    const calls = runner.calls.filter((call) => call.kind === 'tokscale');
    assert.equal(calls.length, 9, 'three scans per target');
    const scanShapes = calls.map((call) => call.flags[0]);
    assert.deepStrictEqual(
      scanShapes,
      ['--today', '--month', '--since', '--today', '--month', '--since', '--today', '--month', '--since']
    );
    // Each target scans only its own clients.
    assert.deepStrictEqual(calls[0].clients, 'claude');
    assert.deepStrictEqual(calls[3].clients, 'codex');
  } finally {
    fixtures.cleanup(home);
  }
});

test('arbitrary model names survive untouched through usage, history and aggregate', async () => {
  const home = fixtures.makeHome();
  try {
    const layout = fixtures.twoToolsTwoHomes(home);
    const modelId = 'vendor-x/ultra-long-context-preview-2026-09-13:free';
    const runner = fixtures.runners({ today: 5, month: 6, allTime: 7, modelId });
    const request = fixtures.baseRequest(home, { sources: layout.sources });

    const scope = scopeFor();
    const response = await handleRequest(request, { scope, signal: scope.signal, ...runner });
    scope.dispose();

    const target = response.payload.usage.targets[0];
    assert.ok(Object.prototype.hasOwnProperty.call(target.today.models, modelId), 'model key must be preserved verbatim');
    assert.equal(target.today.models[modelId], 5);
    assert.ok(Object.prototype.hasOwnProperty.call(response.payload.aggregate.today.models, modelId));
    assert.equal(response.payload.aggregate.today.models[modelId], 15);
    assert.ok(Object.prototype.hasOwnProperty.call(response.payload.history.daily[0], 'tokens'));
  } finally {
    fixtures.cleanup(home);
  }
});

test('a collected true zero stays zero, and is not confused with missing data', async () => {
  const home = fixtures.makeHome();
  try {
    const layout = fixtures.twoToolsTwoHomes(home);
    const runner = fixtures.runners({ today: 0, month: 0, allTime: 0 });
    const request = fixtures.baseRequest(home, {
      sources: [layout.sources[0]],
      options: { ...fixtures.baseRequest(home).options, allowPriceNetwork: true }
    });

    const scope = scopeFor();
    const response = await handleRequest(request, { scope, signal: scope.signal, ...runner });
    scope.dispose();

    assert.equal(response.payload.usage.today.totalTokens, 0);
    assert.equal(response.payload.aggregate.today.totalTokens, 0);
    assert.equal(response.sources[0].status, 'ok');
    assert.equal(response.sources[0].coverage, 'known');
    assert.equal(response.coverage.cost, 'unknown');
    assert.deepStrictEqual(response.coverage.days, [{ date: '2026-09-13', status: 'known' }]);
  } finally {
    fixtures.cleanup(home);
  }
});

test('a true zero in one source plus an unavailable source is never a complete zero', async () => {
  const home = fixtures.makeHome();
  try {
    const layout = fixtures.twoToolsTwoHomes(home);
    const runner = fixtures.runners({ today: 0, month: 0, allTime: 0 });
    const request = fixtures.baseRequest(home, {
      sources: [
        layout.sources[0],
        fixtures.source({
          id: 'missing-logs', accountId: 'card-missing',
          providerId: 'codex',
          canonicalPath: path.join(home, 'does-not-exist'),
          kind: 'managedAccount',
          pathRole: 'codexHome'
        })
      ]
    });

    const scope = scopeFor();
    const response = await handleRequest(request, { scope, signal: scope.signal, ...runner });
    scope.dispose();

    assert.equal(response.status, 'partial');
    const unavailable = response.sources.find((entry) => entry.id === 'missing-logs');
    assert.equal(unavailable.status, 'unavailable');
    assert.equal(unavailable.coverage, 'unknown');
    assert.ok(response.errors.some((error) => error.code === 'source_path_unavailable'));
    assert.equal(response.coverage.days[0].status, 'partial');
    assert.equal(response.coverage.cost, 'unknown');
  } finally {
    fixtures.cleanup(home);
  }
});
