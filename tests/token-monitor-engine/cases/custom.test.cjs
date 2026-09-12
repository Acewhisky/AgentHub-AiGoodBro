'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');

const { handleRequest } = require('../lib/handler.cjs');
const { createRequestScope } = require('../lib/runtime/scope.cjs');
const fixtures = require('./helpers/fixtures.cjs');

function scopeFor() {
  return createRequestScope({ timeoutMs: 20000 }).start();
}

async function collect(request, runner = fixtures.runners()) {
  const scope = scopeFor();
  try {
    return await handleRequest(request, { scope, signal: scope.signal, ...runner });
  } finally {
    scope.dispose();
  }
}

function custom(overrides) {
  return {
    sourceId: 'manual-a',
    providerId: 'claude',
    toolId: 'manual-entry',
    period: 'today',
    date: '2026-09-13',
    tokens: 500,
    cost: 0.25,
    currency: 'USD',
    coverage: 'known',
    provenance: 'manual',
    overlapsSourceIds: [],
    ...overrides
  };
}

test('an explicitly nonoverlapping custom record is aggregated exactly once', async () => {
  const home = fixtures.makeHome();
  try {
    const layout = fixtures.twoToolsTwoHomes(home);
    const request = fixtures.baseRequest(home, {
      sources: [layout.sources[0]],
      customSources: [custom({})]
    });

    const response = await collect(request);
    assert.equal(response.payload.usage.today.totalTokens, 100);
    assert.equal(response.payload.usage.month.totalTokens, 200);
    // Scanned today (100) plus the 500 custom record; the custom record widens
    // into the broader windows it belongs to, exactly once each.
    assert.equal(response.payload.aggregate.today.totalTokens, 600);
    assert.equal(response.payload.aggregate.month.totalTokens, 700);
    assert.equal(response.payload.aggregate.allTime.totalTokens, 1500);
    assert.deepStrictEqual(response.payload.aggregate.customSources.accepted, [
      { sourceId: 'manual-a', providerId: 'claude', period: 'today' }
    ]);
    assert.deepStrictEqual(response.payload.aggregate.customSources.excluded, []);
    assert.ok(Object.prototype.hasOwnProperty.call(response.payload.aggregate.today.clients, 'custom-manual-a'));
    assert.equal(response.payload.aggregate.today.clients['custom-manual-a'], 500);
  } finally {
    fixtures.cleanup(home);
  }
});

test('a record naming a known overlap is excluded while the input is preserved', async () => {
  const home = fixtures.makeHome();
  try {
    const layout = fixtures.twoToolsTwoHomes(home);
    const request = fixtures.baseRequest(home, {
      sources: [layout.sources[0]],
      customSources: [custom({ sourceId: 'overlapping', overlapsSourceIds: ['claude-logs'] })]
    });

    const response = await collect(request);
    assert.equal(response.payload.aggregate.today.totalTokens, 100, 'the overlapping record must not be added');
    assert.deepStrictEqual(response.payload.aggregate.customSources.excluded, [
      { sourceId: 'overlapping', reasonCode: 'known_overlap' }
    ]);
    assert.deepStrictEqual(response.payload.aggregate.customSources.accepted, []);
    assert.ok(!response.errors.some((error) => error.code === 'known_overlap'), 'a declared overlap is not an error');
  } finally {
    fixtures.cleanup(home);
  }
});

test('a legacy cumulative record without overlap evidence cannot silently double-add', async () => {
  const home = fixtures.makeHome();
  try {
    const layout = fixtures.twoToolsTwoHomes(home);
    const request = fixtures.baseRequest(home, {
      sources: [layout.sources[0]],
      customSources: [custom({
        sourceId: 'legacy-totals',
        period: 'allTime',
        tokens: 9999,
        cost: null,
        coverage: 'partial',
        provenance: 'legacy',
        overlapsSourceIds: []
      })]
    });

    const response = await collect(request);
    assert.equal(response.payload.aggregate.allTime.totalTokens, 1000, 'the legacy cumulative record must not be added');
    assert.deepStrictEqual(response.payload.aggregate.customSources.excluded, [
      { sourceId: 'legacy-totals', reasonCode: 'overlap_evidence_missing' }
    ]);
    assert.ok(response.errors.some((error) => error.code === 'overlap_evidence_missing' && error.sourceId === 'legacy-totals'));
    assert.equal(response.status, 'partial');
  } finally {
    fixtures.cleanup(home);
  }
});

test('a legacy record is admissible when there are no upstream totals to overlap', async () => {
  const home = fixtures.makeHome();
  try {
    const request = fixtures.baseRequest(home, {
      sources: [],
      customSources: [custom({ sourceId: 'legacy-only', period: 'allTime', tokens: 42, provenance: 'legacy' })]
    });
    const response = await collect(request);
    assert.equal(response.payload.aggregate.allTime.totalTokens, 42);
    assert.deepStrictEqual(response.payload.aggregate.customSources.excluded, []);
  } finally {
    fixtures.cleanup(home);
  }
});

test('duplicate custom ids and collisions with scanned source ids are rejected', async () => {
  const home = fixtures.makeHome();
  try {
    const layout = fixtures.twoToolsTwoHomes(home);
    const request = fixtures.baseRequest(home, {
      sources: [layout.sources[0]],
      customSources: [
        custom({ sourceId: 'dup', tokens: 10 }),
        custom({ sourceId: 'dup', tokens: 10 }),
        custom({ sourceId: 'claude-logs', tokens: 10 })
      ]
    });

    const response = await collect(request);
    assert.equal(response.payload.aggregate.today.totalTokens, 110, 'only the first "dup" is added');
    const codes = response.errors.filter((error) => error.code === 'duplicate_custom_source').map((error) => error.sourceId);
    assert.deepStrictEqual(codes.sort(), ['claude-logs', 'dup']);
  } finally {
    fixtures.cleanup(home);
  }
});

test('custom values must be finite and nonnegative', async () => {
  const home = fixtures.makeHome();
  try {
    const invalid = [
      custom({ sourceId: 'neg', tokens: -1 }),
      custom({ sourceId: 'inf', tokens: Number.POSITIVE_INFINITY }),
      custom({ sourceId: 'nan', tokens: Number.NaN }),
      custom({ sourceId: 'str', tokens: '500' }),
      custom({ sourceId: 'negcost', cost: -0.01 }),
      custom({ sourceId: 'badperiod', period: 'yesterday' }),
      custom({ sourceId: 'badcoverage', coverage: 'guessed' }),
      custom({ sourceId: 'badprovenance', provenance: 'imported' }),
      custom({ sourceId: 'baddate', date: '13/09/2026' }),
      custom({ sourceId: 'badoverlap', overlapsSourceIds: 'claude-logs' })
    ];
    const response = await collect(fixtures.baseRequest(home, { sources: [], customSources: invalid }));

    const rejected = response.errors.filter((error) => error.code === 'invalid_custom_source').map((error) => error.sourceId).sort();
    assert.deepStrictEqual(rejected, [
      'badcoverage', 'baddate', 'badoverlap', 'badperiod', 'badprovenance',
      'inf', 'nan', 'neg', 'negcost', 'str'
    ]);
    assert.deepStrictEqual(response.payload.aggregate.customSources.accepted, []);
    assert.equal(response.payload.aggregate.allTime.totalTokens, 0);
  } finally {
    fixtures.cleanup(home);
  }
});

test('a custom record with unknown cost keeps cost unknown rather than zero', async () => {
  const home = fixtures.makeHome();
  try {
    const request = fixtures.baseRequest(home, {
      sources: [],
      customSources: [custom({ sourceId: 'no-cost', cost: null, coverage: 'partial' })]
    });
    const response = await collect(request);
    const entry = response.coverage.entries.find((item) => item.sourceId === 'no-cost' && item.metric === 'cost');
    assert.equal(entry.status, 'unknown');
    assert.equal(response.payload.aggregate.today.totalTokens, 500);
  } finally {
    fixtures.cleanup(home);
  }
});
