'use strict';

// Child-process registry.
//
// "Kill descendant processes on cancel" cannot be honoured by killing the
// bridge alone: a tokscale scan is a separate process, and a provider CLI
// fallback may be a grandchild. The bridge therefore records every process it
// spawns and terminates them when the request is cancelled or times out.
//
// The patch must be installed before any upstream module is loaded, because
// upstream modules destructure `spawn` at load time (shared/collector.js,
// shared/limits/providerHelpers.js) and would otherwise capture the original.
// loader.prepare() installs it first for exactly that reason.

const childProcess = require('node:child_process');

let originalSpawn = null;
const tracked = new Set();

function install() {
  if (originalSpawn) return false;
  originalSpawn = childProcess.spawn;
  childProcess.spawn = function spawn(...args) {
    const child = originalSpawn.apply(this, args);
    if (child && typeof child.kill === 'function') {
      tracked.add(child);
      const forget = () => tracked.delete(child);
      child.once('exit', forget);
      child.once('error', forget);
    }
    return child;
  };
  return true;
}

function isInstalled() {
  return originalSpawn !== null;
}

function trackCount() {
  return tracked.size;
}

// Sends a signal to every tracked process, then escalates to SIGKILL for any
// that are still alive. Never throws: a process that already exited is normal.
function killAll(escalateMs = 250) {
  const victims = [...tracked];
  for (const child of victims) {
    try { child.kill('SIGTERM'); } catch (_) { /* already gone */ }
  }
  if (victims.length === 0) return 0;
  const escalation = setTimeout(() => {
    for (const child of victims) {
      try {
        if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
      } catch (_) { /* already gone */ }
    }
  }, escalateMs);
  if (typeof escalation.unref === 'function') escalation.unref();
  return victims.length;
}

module.exports = { install, isInstalled, trackCount, killAll };
