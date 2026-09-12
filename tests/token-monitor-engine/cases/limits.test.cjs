'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');

const { handleRequest } = require('../lib/handler.cjs');
const { createRequestScope } = require('../lib/runtime/scope.cjs');
const collect = require('../lib/collect.cjs');
const fixtures = require('./helpers/fixtures.cjs');

function scopeFor() {
  return createRequestScope({ timeoutMs: 20000 }).start();
}

async function collectLimits(request, deps = {}) {
  const scope = scopeFor();
  try {
    return await handleRequest(request, { scope, signal: scope.signal, ...deps });
  } finally {
    scope.dispose();
  }
}

function providerFetch(provider, status) {
  return async () => ({
    provider,
    status,
    updatedAt: '2026-09-13T02:00:00.000Z',
    windows: [{ kind: 'weekly', usedPercent: 10, resetsAt: '2026-09-20T00:00:00Z', windowMinutes: 10080 }]
  });
}

function limitsRequest(home, sources, options = {}) {
  const base = fixtures.baseRequest(home, { sources, operation: 'collectLimits' });
  return { ...base, options: { ...base.options, ...options } };
}

test('collectLimits probes only the enabled providers and reports their windows', async () => {
  const home = fixtures.makeHome();
  try {
    const layout = fixtures.twoToolsTwoHomes(home);
    const probed = [];
    const response = await collectLimits(limitsRequest(home, layout.sources), {
      limitsDeps: {
        providerFetchers: {
          claude: async () => { probed.push('claude'); return providerFetch('claude', 'ok')(); },
          codex: async () => { probed.push('codex'); return providerFetch('codex', 'ok')(); }
        }
      }
    });

    assert.equal(response.status, 'partial');
    assert.deepStrictEqual(probed.sort(), ['codex', 'codex']);
    assert.equal(response.payload.limits.providers.length, 2);
    assert.deepStrictEqual(
      response.payload.limits.providers.map((entry) => entry.provider).sort(),
      ['codex', 'codex']
    );
    assert.ok(response.payload.limits.updatedAt);

    // Quota coverage exists for the managed accounts that have a provider row.
    const quotaEntries = response.coverage.entries.filter((entry) => entry.metric === 'quota');
    assert.equal(quotaEntries.length, 2);
    assert.ok(quotaEntries.every((entry) => entry.status === 'known'));
    assert.deepStrictEqual(quotaEntries.map((entry) => entry.sourceId).sort(), ['codex-a', 'codex-b']);
  } finally {
    fixtures.cleanup(home);
  }
});

test('an unavailable provider row keeps quota coverage unknown', async () => {
  const home = fixtures.makeHome();
  try {
    const layout = fixtures.twoToolsTwoHomes(home);
    const response = await collectLimits(limitsRequest(home, layout.sources), {
      limitsDeps: {
        providerFetchers: {
          claude: async () => providerFetch('claude', 'ok')(),
          codex: async () => providerFetch('codex', 'unavailable')()
        }
      }
    });

    const quotaEntries = response.coverage.entries.filter((entry) => entry.metric === 'quota');
    assert.ok(quotaEntries.every((entry) => entry.status === 'unknown'));
    assert.equal(response.coverage.days[0].status, 'unknown');
  } finally {
    fixtures.cleanup(home);
  }
});

test('a provider probe that throws does not fail the whole limits request', async () => {
  const home = fixtures.makeHome();
  try {
    const layout = fixtures.twoToolsTwoHomes(home);
    const response = await collectLimits(limitsRequest(home, layout.sources), {
      limitsDeps: {
        providerFetchers: {
          claude: async () => { throw new Error('probe exploded'); },
          codex: async () => providerFetch('codex', 'ok')()
        }
      }
    });

    assert.equal(response.status, 'partial', 'unbound log source does not authorize a probe');
    assert.equal(response.payload.limits.providers.length, 2);
    const claude = response.payload.limits.providers.find((entry) => entry.provider === 'claude');
    assert.equal(claude, undefined);
  } finally {
    fixtures.cleanup(home);
  }
});

test('the injected provider fetch enforces the provider-network capability', async () => {
  const home = fixtures.makeHome();
  try {
    const base = fixtures.baseRequest(home, { sources: [] });
    const gated = collect.buildProviderFetch(
      { ...base, options: { ...base.options, allowProviderNetwork: false } },
      {}
    );
    await assert.rejects(() => gated('https://api.anthropic.com/api/oauth/usage'), (error) => error.code === 'CAPABILITY_DISABLED');

    const credentialGated = collect.buildProviderFetch(
      { ...base, options: { ...base.options, allowCredentialRefresh: false } },
      {}
    );
    await assert.rejects(
      () => credentialGated('https://console.anthropic.com/v1/oauth/token'),
      (error) => error.code === 'CAPABILITY_DISABLED'
    );

    let reached = 0;
    const open = collect.buildProviderFetch(
      { ...base, options: { ...base.options, allowCredentialRefresh: false } },
      { fetch: async () => { reached += 1; return { ok: true }; } }
    );
    await open('https://api.anthropic.com/api/oauth/usage');
    assert.equal(reached, 1, 'a usage endpoint must still be reachable');
  } finally {
    fixtures.cleanup(home);
  }
});

test('a limits request with no enabled providers returns an empty provider list', async () => {
  const home = fixtures.makeHome();
  try {
    const response = await collectLimits(limitsRequest(home, []), { limitsDeps: {} });
    assert.equal(response.status, 'ok');
    assert.deepStrictEqual(response.payload.limits.providers, []);
    assert.deepStrictEqual(response.sources, []);
  } finally {
    fixtures.cleanup(home);
  }
});

test('limits are not fetched during a usage collect', async () => {
  const home = fixtures.makeHome();
  try {
    const layout = fixtures.twoToolsTwoHomes(home);
    let probed = 0;
    const response = await collectLimits(fixtures.baseRequest(home, { sources: layout.sources }), {
      ...fixtures.runners(),
      limitsDeps: { providerFetchers: { claude: async () => { probed += 1; return providerFetch('claude', 'ok')(); } } }
    });
    assert.equal(probed, 0);
    assert.equal(response.payload.limits, undefined);
    assert.ok(response.payload.usage);
  } finally {
    fixtures.cleanup(home);
  }
});
