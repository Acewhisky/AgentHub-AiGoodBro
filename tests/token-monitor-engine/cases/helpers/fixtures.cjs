'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

// Shared fixture builders. Everything a test needs is synthetic and lives under
// a fresh temporary directory: no real home, no real credential store, no
// network. The runner shapes mirror the JSON upstream's own tests inject, so a
// fixture exercises the real collector rather than a stand-in for it.

const ARBITRARY_MODEL = 'vendor-x/ultra-long-context-preview-2026-09-13:free';

function makeHome(prefix = 'tm-engine-') {
  return fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), prefix)));
}

function makeLogRoot(home, name = 'logs') {
  const root = path.join(home, name);
  fs.mkdirSync(root, { recursive: true });
  return root;
}

function makeCodexHome(home, name) {
  const root = path.join(home, name);
  fs.mkdirSync(root, { recursive: true });
  return root;
}

function cleanup(target) {
  fs.rmSync(target, { recursive: true, force: true });
}

// A tokscale usage snapshot in the shape extractUsageFromTokscale consumes. The
// model dimension is carried by `model` (the key the extractor reads); `modelId`
// is what the history graph uses.
function usageSnapshot(totalTokens, options = {}) {
  return {
    entries: [{
      client: options.client || 'claude',
      model: options.modelName || ARBITRARY_MODEL,
      input: totalTokens,
      output: 0,
      cacheRead: 0,
      cacheWrite: 0,
      reasoning: 0,
      cost: options.cost === undefined ? 1.5 : options.cost,
      messages: 1
    }]
  };
}

// A tokscale history graph in the shape parseGraphResult consumes.
function historyGraph(date, totalTokens, options = {}) {
  return {
    contributions: [{
      date,
      clients: [{
        client: options.client || 'claude',
        modelId: options.modelId || ARBITRARY_MODEL,
        tokens: { input: totalTokens, output: 0, cacheRead: 0, cacheWrite: 0, reasoning: 0 },
        cost: options.cost === undefined ? 1.5 : options.cost,
        messages: 1
      }]
    }]
  };
}

// The runner pair injected into collectUsageOnce / collectHistoryOnce.
function runners(options = {}) {
  const calls = [];
  return {
    calls,
    runTokscale: async (input) => {
      calls.push({ kind: 'tokscale', clients: input.clients, flags: (input.flags || []).slice() });
      const flag = (input.flags || [])[0];
      const tokens = flag === '--today'
        ? options.today === undefined ? 100 : options.today
        : flag === '--month'
          ? options.month === undefined ? 200 : options.month
          : options.allTime === undefined ? 1000 : options.allTime;
      return usageSnapshot(tokens, { ...options, modelName: options.modelId });
    },
    runGraph: async (input) => {
      calls.push({ kind: 'graph', clients: input.clients });
      if (options.graphError) throw new Error('fixture graph failure');
      return historyGraph(options.date || '2026-09-13', options.graphTokens === undefined ? 30 : options.graphTokens, options);
    }
  };
}

function source(overrides) {
  return {
    kind: 'agentLogs',
    pathRole: 'logRoot',
    authority: 'upstream',
    enabled: true,
    ...overrides
  };
}

function baseRequest(home, overrides = {}) {
  return {
    schemaVersion: 1,
    requestId: 'fixture-request',
    operation: 'collectUsage',
    now: '2026-09-13T02:00:00.000Z',
    timezone: 'Asia/Shanghai',
    cacheDirectory: path.join(home, 'cache'),
    sources: [],
    options: {
      timeoutMs: 20000,
      allowPriceNetwork: false,
      allowSelfSync: false,
      allowCredentialRefresh: false,
      includeLiveCodexAccount: false
    },
    customSources: [],
    ...overrides
  };
}

// Two tools (claude, codex) across two managed Codex homes, plus a plain agent
// logs root: the shape the contract's "2 tools and 2 managed homes" test needs.
function twoToolsTwoHomes(home) {
  const logs = makeLogRoot(home);
  const codexA = makeCodexHome(home, 'codex-home-a');
  const codexB = makeCodexHome(home, 'codex-home-b');
  return {
    logs,
    codexA,
    codexB,
    sources: [
      source({ id: 'claude-logs', providerId: 'claude', canonicalPath: logs }),
      source({ id: 'codex-a', providerId: 'codex', kind: 'managedAccount', pathRole: 'codexHome', canonicalPath: codexA, accountId: 'card-a' }),
      source({ id: 'codex-b', providerId: 'codex', kind: 'managedAccount', pathRole: 'codexHome', canonicalPath: codexB, accountId: 'card-b' })
    ]
  };
}

module.exports = {
  ARBITRARY_MODEL,
  makeHome,
  makeLogRoot,
  makeCodexHome,
  cleanup,
  usageSnapshot,
  historyGraph,
  runners,
  source,
  baseRequest,
  twoToolsTwoHomes
};
