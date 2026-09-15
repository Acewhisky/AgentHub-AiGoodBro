'use strict';

// The statistics-only integration must never recover or use upstream OAuth clients.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const rootIndex = process.argv.indexOf('--resource-root');
const root = rootIndex < 0
  ? path.resolve(__dirname, '../Companion/TokenMonitorEngine')
  : path.resolve(process.argv[rootIndex + 1]);
const file = path.join(root, 'upstream/src/shared/providers/antigravity/oauth.js');
const source = fs.readFileSync(file, 'utf8');
assert.doesNotMatch(source, /GOCSPX-[A-Za-z0-9_-]{20,}/);
assert.doesNotMatch(source, /[0-9]{10,}-[A-Za-z0-9_-]{20,}\.apps\.googleusercontent\.com/);
const oauth = require(file); // Import must remain safe for the common limits collector.
const calls = { fetch: 0, fs: 0, env: 0, renewed: 0 };
const forbidden = kind => () => { calls[kind]++; throw new Error('forbidden side effect'); };
const deps = {
  fetch: forbidden('fetch'),
  fs: { statSync: forbidden('fs'), readFileSync: forbidden('fs') },
  env: new Proxy({}, { get: forbidden('env') }),
  onCredentialRenewed: forbidden('renewed')
};
const disabled = error => error.code === 'antigravity_oauth_disabled' && error.status === 'unsupported';

(async () => {
  for (const name of ['_officialOAuthClient', 'discoverOAuthClient', 'parseClientFromText', 'authorizationUrl']) {
    assert.throws(() => oauth[name](deps), disabled, name);
  }
  assert.deepEqual(oauth.candidateOAuthArtifacts(deps), []);
  for (const name of ['exchangeAuthorizationCode', 'refreshCredential', 'fetchGoogleIdentity', 'fetchRemoteSnapshot']) {
    // A valid-looking cached access token must not bypass the disabled boundary.
    await assert.rejects(oauth[name]({ accessToken: 'synthetic', expiresAt: Date.now() + 3_600_000 }, deps), disabled, name);
  }
  assert.deepEqual(calls, { fetch: 0, fs: 0, env: 0, renewed: 0 });
  assert.deepEqual(oauth.normalizeManagedAccounts([]), []);
  assert.deepEqual(oauth.modelsFromAvailable({ models: {} }), []);
  assert.deepEqual(oauth.modelsFromBuckets({ buckets: [] }), []);
  console.log('Antigravity OAuth disabled: safe import, 8 blocked entrypoints, zero discovery/network/renewal, pure helpers preserved');
})().catch(error => { console.error(error.message); process.exitCode = 1; });
