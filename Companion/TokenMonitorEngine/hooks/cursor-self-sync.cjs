'use strict';

// Capability overlay for src/shared/providers/cursor/selfSync.js
//
// Upstream self-syncs Cursor on an ordinary collect tick: createCursorSelfSync()
// returns maybeSyncCursor(), which signs a Cursor session and spawns the sync
// whenever the shared throttle allows it. The collector calls it unconditionally
// whenever the tracked client set contains "cursor"; there is no option that
// turns it off, and the throttle floor (5 min) only delays it.
//
// The bridge's allowSelfSync option defaults to false, so the decision has to
// be made here. The overlay keeps the real implementation (loaded fresh from the
// pinned checkout) and wraps the one entry point the collector uses.

const { upstreamModule } = require('../lib/upstream/paths.cjs');
const { loadFresh } = require('../lib/upstream/vendor.cjs');
const capabilities = require('../lib/upstream/capabilities.cjs');

const real = loadFresh(upstreamModule('shared/providers/cursor/selfSync.js'));

function requested(clientsCsv) {
  return String(clientsCsv || '').split(',').map((entry) => entry.trim().toLowerCase()).includes('cursor');
}

function createCursorSelfSync(deps) {
  const inner = real.createCursorSelfSync(deps);
  return {
    async maybeSyncCursor(clientsCsv, logger, options = {}) {
      if (!capabilities.getCapabilities().allowSelfSync) {
        // Only reported when a sync would actually have been attempted, so the
        // suppression list stays a statement about this request.
        if (requested(clientsCsv)) capabilities.recordBlocked('self_sync_disabled:cursor');
        return undefined;
      }
      return inner.maybeSyncCursor(clientsCsv, logger, options);
    }
  };
}

module.exports = { createCursorSelfSync };
