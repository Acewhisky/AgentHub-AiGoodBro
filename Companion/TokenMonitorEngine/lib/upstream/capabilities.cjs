'use strict';

// Per-request capability state read by the capability overlays.
//
// The upstream collector has no notion of "the caller did not authorise this".
// Self-sync, price lookups and credential refresh are ordinary code paths that
// simply run. The bridge therefore has to make the authorisation decision
// explicit at the boundary, and the overlays in engine/hooks/ read it here.
//
// The defaults are the contract defaults: everything that touches the network,
// mutates credentials, or syncs a provider on the user's behalf is OFF until
// the caller sets the matching request option to true.

const DEFAULTS = Object.freeze({
  allowSelfSync: false,
  allowPriceNetwork: false,
  allowCredentialRefresh: false,
  // Provider quota APIs are the reason collectLimits exists, so this one is on
  // by default; it is still an explicit switch so a host can run a
  // local-reads-only limits pass.
  allowProviderNetwork: true
});

let current = { ...DEFAULTS };
let blocked = [];
let hookErrors = [];

function resetCapabilities() {
  current = { ...DEFAULTS };
  blocked = [];
  hookErrors = [];
}

function setCapabilities(next = {}) {
  for (const key of Object.keys(DEFAULTS)) {
    if (typeof next[key] === 'boolean') current[key] = next[key];
  }
  return current;
}

function getCapabilities() {
  return current;
}

// Every time a hook suppresses an upstream side effect it records a code here.
// The response reports them so a caller can tell "nothing to collect" apart
// from "collection was suppressed on purpose".
function recordBlocked(code) {
  if (!blocked.includes(code)) blocked.push(code);
}

function recordHookError(code) {
  if (!hookErrors.includes(code)) hookErrors.push(code);
}

function takeSuppressions() {
  const result = { blocked: blocked.slice(), hookErrors: hookErrors.slice() };
  blocked = [];
  hookErrors = [];
  return result;
}

module.exports = {
  DEFAULTS,
  resetCapabilities,
  setCapabilities,
  getCapabilities,
  recordBlocked,
  recordHookError,
  takeSuppressions
};
