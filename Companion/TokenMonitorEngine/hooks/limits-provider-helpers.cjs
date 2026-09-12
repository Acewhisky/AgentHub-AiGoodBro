'use strict';

// Capability overlay for src/shared/limits/providerHelpers.js
//
// This is the single choke point every provider limits module goes through for
// outbound HTTP (fetchJson) and for spawning a provider CLI (runProcessText).
// Gating here is what makes allowCredentialRefresh and allowProviderNetwork
// enforceable without editing a 1800-line provider module:
//
//   fetchJson      src/shared/providers/claude/limits.js destructures it at load
//                  time, and its internal refreshClaudeCredentials ->
//                  refreshClaudeAccessToken path calls it with the OAuth token
//                  endpoint. Blocking that URL is what stops a collect from
//                  minting or persisting a new token.
//   runProcessText claude/limits.js spawns `claude /status` in a PTY specifically
//                  so "Claude Code itself refreshes the token". With
//                  credentialRefresh disabled that spawn is the refresh, so it is
//                  refused. Codex login is not reachable from collect at all
//                  (runCodexLogin is only wired to the Electron login flow), so
//                  no codex gate is needed here.
//
// The endpoint and command lists live in lib/upstream/credential-endpoints.cjs
// so this gate and the injected deps.fetch wrapper cannot drift apart.

const { upstreamModule } = require('../lib/upstream/paths.cjs');
const { loadFresh } = require('../lib/upstream/vendor.cjs');
const capabilities = require('../lib/upstream/capabilities.cjs');
const { isCredentialEndpoint, isCredentialCli } = require('../lib/upstream/credential-endpoints.cjs');

const real = loadFresh(upstreamModule('shared/limits/providerHelpers.js'));

async function fetchJson(url, headers, deps = {}, options = {}) {
  const caps = capabilities.getCapabilities();
  if (caps.allowProviderNetwork === false) {
    capabilities.recordBlocked('provider_network_disabled');
    throw real.errorWithStatus('unavailable', 'provider network disabled by caller');
  }
  if (!caps.allowCredentialRefresh && isCredentialEndpoint(url)) {
    capabilities.recordBlocked('credential_refresh_disabled');
    throw real.errorWithStatus('unauthorized', 'credential refresh disabled by caller');
  }
  return real.fetchJson(url, headers, deps, options);
}

function runProcessText(command, args = [], options = {}) {
  const caps = capabilities.getCapabilities();
  if (!caps.allowCredentialRefresh && isCredentialCli(command)) {
    capabilities.recordBlocked('credential_refresh_disabled:cli');
    const error = new Error('credential refresh disabled by caller');
    error.code = 'CAPABILITY_DISABLED';
    return Promise.reject(error);
  }
  return real.runProcessText(command, args, options);
}

module.exports = {
  ...real,
  fetchJson,
  runProcessText
};
