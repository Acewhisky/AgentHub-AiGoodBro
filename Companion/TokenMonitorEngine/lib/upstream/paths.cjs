'use strict';

const path = require('node:path');

// Single source of truth for where the pinned upstream checkout lives. Kept in
// its own module with no upstream requires so the capability overlays can
// resolve sibling upstream modules without creating a load cycle through the
// loader.

const RESOURCE_ROOT = path.resolve(__dirname, '..', '..');

function upstreamRoot() {
  return path.join(RESOURCE_ROOT, 'upstream');
}

function upstreamSrcRoot() {
  return path.join(upstreamRoot(), 'src');
}

function upstreamModule(relativeFromSrc) {
  return path.join(upstreamSrcRoot(), relativeFromSrc);
}

module.exports = { RESOURCE_ROOT, upstreamRoot, upstreamSrcRoot, upstreamModule };
