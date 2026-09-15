'use strict';

// Capability overlay for src/shared/providers/antigravity/selfSync.js
//
// Same shape as the Cursor overlay: upstream's maybeSyncAntigravity() runs from
// an ordinary collect tick and the collector offers no switch to suppress it.
// The collector also imports the read-only path helpers from this module
// (antigravityDataPresent / antigravityDataRoots), so the overlay re-exports the
// real module wholesale and replaces only the factory.

const { upstreamModule } = require('../lib/upstream/paths.cjs');
const { loadFresh } = require('../lib/upstream/vendor.cjs');
const capabilities = require('../lib/upstream/capabilities.cjs');

const real = loadFresh(upstreamModule('shared/providers/antigravity/selfSync.js'));

function requested(clientsCsv) {
  return String(clientsCsv || '').split(',').map((entry) => entry.trim().toLowerCase()).includes('antigravity');
}

function createAntigravitySelfSync(deps) {
  const inner = real.createAntigravitySelfSync(deps);
  return {
    async maybeSyncAntigravity(clientsCsv, logger, home, options = {}) {
      if (!capabilities.getCapabilities().allowSelfSync) {
        if (requested(clientsCsv)) capabilities.recordBlocked('self_sync_disabled:antigravity');
        return undefined;
      }
      return inner.maybeSyncAntigravity(clientsCsv, logger, home, options);
    }
  };
}

module.exports = {
  ...real,
  createAntigravitySelfSync
};
