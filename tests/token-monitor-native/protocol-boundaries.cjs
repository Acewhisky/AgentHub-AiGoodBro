'use strict';
// Usage: node tests/token-monitor-native/protocol-boundaries.cjs [engine-root]
const assert = require('node:assert/strict');
const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');
const root = process.argv[2] || (fs.existsSync('Companion/TokenMonitorEngine/lib/protocol.cjs') ? 'Companion/TokenMonitorEngine' : 'engine');
const { validateRequest, MAX_SOURCES } = require(path.resolve(root, 'lib/protocol.cjs'));
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'protocol-boundaries-'));
try {
  assert.equal(MAX_SOURCES, 256);
  for (const count of [64, 65, 256, 257]) {
    const request = {
      schemaVersion: 1, requestId: 'opaque-boundary', operation: 'collectUsage',
      now: '2026-09-13T00:00:00Z', timezone: 'UTC', cacheDirectory: temp,
      sources: Array.from({ length: count }, (_, index) => ({
        id: `opaque-${index}`, providerId: 'codex', kind: 'managedAccount',
        canonicalPath: path.join(temp, `opaque-${index}`), pathRole: 'codexHome', enabled: true
      })),
      options: { allowProviderNetwork: false, allowPriceNetwork: false, allowSelfSync: false, allowCredentialRefresh: false }
    };
    if (count === 257) assert.throws(() => validateRequest(request), { code: 'invalid_request' });
    else assert.equal(validateRequest(request).sources.length, count);
    console.log(`PASS actual JS validateRequest ${count === 257 ? 'rejects' : 'accepts'} exact ${count} sources`);
  }
  for (const count of [256, 257]) {
    const request = {
      schemaVersion: 1, requestId: 'opaque-custom-boundary', operation: 'collectUsage',
      now: '2026-09-13T00:00:00Z', timezone: 'UTC', cacheDirectory: temp,
      sources: [], customSources: Array.from({ length: count }, (_, index) => ({ sourceId: `custom-${index}` }))
    };
    if (count === 257) assert.throws(() => validateRequest(request), { code: 'invalid_request' });
    else assert.equal(validateRequest(request).customSources.length, count);
    console.log(`PASS actual JS validateRequest ${count === 257 ? 'rejects' : 'accepts'} exact ${count} custom sources`);
  }
} finally {
  fs.rmSync(temp, { recursive: true, force: true });
}
