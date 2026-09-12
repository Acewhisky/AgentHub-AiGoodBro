'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const { handleRequest } = require('../lib/handler.cjs');
const { createRequestScope } = require('../lib/runtime/scope.cjs');
const { BridgeError } = require('../lib/errors.cjs');
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

test('a symlink alias of the same root is excluded, not scanned twice', async () => {
  const home = fixtures.makeHome();
  try {
    const logs = fixtures.makeLogRoot(home);
    const alias = path.join(home, 'logs-alias');
    fs.symlinkSync(logs, alias);
    const request = fixtures.baseRequest(home, {
      sources: [
        fixtures.source({ id: 'logs-real', providerId: 'claude', canonicalPath: logs }),
        fixtures.source({ id: 'logs-alias', providerId: 'claude', canonicalPath: alias })
      ]
    });

    const response = await collect(request);
    const aliasSource = response.sources.find((entry) => entry.id === 'logs-alias');
    assert.equal(aliasSource.status, 'excluded');
    assert.equal(aliasSource.reasonCode, 'duplicate_root');
    assert.equal(response.payload.usage.targets.length, 1, 'only the first root is scanned');
    assert.ok(response.errors.some((error) => error.code === 'duplicate_root' && error.sourceId === 'logs-alias'));
  } finally {
    fixtures.cleanup(home);
  }
});

test('a nested root is excluded as a parent/child overlap', async () => {
  const home = fixtures.makeHome();
  try {
    const logs = fixtures.makeLogRoot(home);
    const nested = path.join(logs, 'nested');
    fs.mkdirSync(nested, { recursive: true });
    const request = fixtures.baseRequest(home, {
      sources: [
        fixtures.source({ id: 'outer', providerId: 'claude', canonicalPath: logs }),
        fixtures.source({ id: 'inner', providerId: 'claude', canonicalPath: nested })
      ]
    });

    const response = await collect(request);
    assert.equal(response.sources.find((entry) => entry.id === 'inner').reasonCode, 'overlapping_root');
    assert.equal(response.payload.usage.targets.length, 1);
  } finally {
    fixtures.cleanup(home);
  }
});

test('kind and pathRole combinations are enforced', async () => {
  const home = fixtures.makeHome();
  try {
    const logs = fixtures.makeLogRoot(home);
    const cases = [
      { id: 'a', providerId: 'claude', kind: 'agentLogs', pathRole: 'codexHome', canonicalPath: logs },
      { id: 'b', providerId: 'claude', kind: 'managedAccount', pathRole: 'logRoot', canonicalPath: logs },
      { id: 'c', providerId: 'claude', kind: 'custom', pathRole: 'logRoot', canonicalPath: logs },
      { id: 'd', providerId: 'claude', kind: 'agentLogs', pathRole: 'customFile', canonicalPath: logs },
      { id: 'e', providerId: 'claude', kind: 'agentLogs', pathRole: 'logRoot', authority: 'custom', canonicalPath: logs },
      { id: 'f', providerId: 'not-a-real-client', kind: 'agentLogs', pathRole: 'logRoot', canonicalPath: logs }
    ];

    for (const candidate of cases) {
      const request = fixtures.baseRequest(home, { sources: [fixtures.source(candidate)] });
      const response = await collect(request);
      const entry = response.sources[0];
      assert.equal(entry.status, 'error', `${candidate.id} should be rejected`);
      assert.equal(entry.reasonCode, 'invalid_source');
      assert.ok(response.errors.some((error) => error.code === 'invalid_source' && error.sourceId === candidate.id));
      assert.equal(response.payload.usage.targets.length, 0);
    }
  } finally {
    fixtures.cleanup(home);
  }
});

test('a managed account may not point at a credential file', async () => {
  const home = fixtures.makeHome();
  try {
    const authPath = path.join(home, 'auth.json');
    fs.writeFileSync(authPath, '{}');
    const request = fixtures.baseRequest(home, {
      sources: [fixtures.source({
        id: 'auth-as-home',
        providerId: 'codex',
        kind: 'managedAccount',
        pathRole: 'codexHome',
        canonicalPath: authPath
      })]
    });
    const response = await collect(request);
    assert.equal(response.sources[0].reasonCode, 'invalid_source');
    assert.equal(response.payload.usage.targets.length, 0);
  } finally {
    fixtures.cleanup(home);
  }
});

test('accountId must be an opaque card id, never an email or a secret', async () => {
  const home = fixtures.makeHome();
  try {
    const codexHome = fixtures.makeCodexHome(home, 'codex-home');
    const rejected = ['user@example.com', 'sk-abcdefghijklmnop', 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abcdefghij'];
    for (const accountId of rejected) {
      const request = fixtures.baseRequest(home, {
        sources: [fixtures.source({
          id: 'codex-a',
          providerId: 'codex',
          kind: 'managedAccount',
          pathRole: 'codexHome',
          canonicalPath: codexHome,
          accountId
        })]
      });
      const response = await collect(request);
      assert.equal(response.sources[0].reasonCode, 'invalid_source', `${accountId} must be refused`);
      assert.ok(!JSON.stringify(response).includes(accountId), 'a rejected account id must not be echoed');
    }

    const accepted = await collect(fixtures.baseRequest(home, {
      sources: [fixtures.source({
        id: 'codex-a',
        providerId: 'codex',
        kind: 'managedAccount',
        pathRole: 'codexHome',
        canonicalPath: codexHome,
        accountId: 'card-7f21'
      })]
    }));
    assert.equal(accepted.sources[0].status, 'ok');
  } finally {
    fixtures.cleanup(home);
  }
});

test('duplicate source ids are rejected and the first declaration wins', async () => {
  const home = fixtures.makeHome();
  try {
    const logs = fixtures.makeLogRoot(home);
    const other = fixtures.makeLogRoot(home, 'logs-2');
    const request = fixtures.baseRequest(home, {
      sources: [
        fixtures.source({ id: 'same', providerId: 'claude', canonicalPath: logs }),
        fixtures.source({ id: 'same', providerId: 'claude', canonicalPath: other })
      ]
    });
    const response = await collect(request);
    assert.equal(response.sources[0].status, 'ok');
    assert.equal(response.sources[1].status, 'excluded');
    assert.equal(response.sources[1].reasonCode, 'duplicate_source_id');
    assert.ok(response.errors.some((error) => error.code === 'duplicate_source_id'));
  } finally {
    fixtures.cleanup(home);
  }
});

test('a disabled source is excluded and never scanned', async () => {
  const home = fixtures.makeHome();
  try {
    const logs = fixtures.makeLogRoot(home);
    const runner = fixtures.runners();
    const response = await collect(fixtures.baseRequest(home, {
      sources: [fixtures.source({ id: 'off', providerId: 'claude', canonicalPath: logs, enabled: false })]
    }), runner);
    assert.equal(response.sources[0].status, 'excluded');
    assert.equal(response.sources[0].reasonCode, 'disabled');
    assert.equal(runner.calls.length, 0, 'no scan for a disabled source');
    assert.equal(response.payload.usage.targets.length, 0);
  } finally {
    fixtures.cleanup(home);
  }
});

test('a missing path is unavailable rather than a hard failure', async () => {
  const home = fixtures.makeHome();
  try {
    const response = await collect(fixtures.baseRequest(home, {
      sources: [fixtures.source({ id: 'gone', providerId: 'claude', canonicalPath: path.join(home, 'nope') })]
    }));
    assert.equal(response.sources[0].status, 'unavailable');
    assert.equal(response.sources[0].coverage, 'unknown');
    assert.ok(response.errors.some((error) => error.code === 'source_path_unavailable' && error.retryable === true));
  } finally {
    fixtures.cleanup(home);
  }
});

test('includeLiveCodexAccount requires an explicitly supplied managed Codex home', async () => {
  const home = fixtures.makeHome();
  try {
    const logs = fixtures.makeLogRoot(home);
    const withFlagOnly = fixtures.baseRequest(home, {
      sources: [fixtures.source({ id: 'claude-logs', providerId: 'claude', canonicalPath: logs })],
      options: { ...fixtures.baseRequest(home).options, includeLiveCodexAccount: true }
    });

    await assert.rejects(
      () => collect(withFlagOnly),
      (error) => error instanceof BridgeError && error.code === 'invalid_source'
    );

    const codexHome = fixtures.makeCodexHome(home, 'codex-home');
    const withVerifiedSource = fixtures.baseRequest(home, {
      sources: [
        fixtures.source({ id: 'claude-logs', providerId: 'claude', canonicalPath: logs }),
        fixtures.source({
          id: 'codex-live',
          providerId: 'codex',
          kind: 'managedAccount',
          pathRole: 'codexHome',
          canonicalPath: codexHome,
          accountId: 'card-live'
        })
      ],
      options: { ...fixtures.baseRequest(home).options, includeLiveCodexAccount: true }
    });
    const response = await collect(withVerifiedSource);
    assert.equal(response.status, 'ok');
    assert.equal(response.sources.length, 2);
  } finally {
    fixtures.cleanup(home);
  }
});

test('no implicit system home is added when the request lists no sources', async () => {
  const home = fixtures.makeHome();
  try {
    const runner = fixtures.runners();
    const response = await collect(fixtures.baseRequest(home, { sources: [] }), runner);
    assert.deepStrictEqual(response.sources, []);
    assert.equal(response.payload.usage.targets.length, 0);
    assert.equal(runner.calls.length, 0, 'nothing is scanned without an explicit source');
    assert.equal(response.status, 'ok');
  } finally {
    fixtures.cleanup(home);
  }
});
