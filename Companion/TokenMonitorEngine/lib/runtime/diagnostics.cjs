'use strict';

// Sanitized diagnostics.
//
// stderr carries structured codes only: no paths, no request fields, no
// upstream exception text, no credential material, no session content. A host
// can log these safely and still tell what the engine did. Everything a human
// would need beyond that belongs in the caller's own instrumentation of the
// request it sent.

const LEVELS = Object.freeze(['debug', 'info', 'warn', 'error']);

function sanitizeCode(value) {
  const text = String(value ?? '').trim().toLowerCase();
  return /^[a-z0-9_:.-]{1,64}$/.test(text) ? text : 'unspecified';
}

function createDiagnostics(stream = process.stderr) {
  function emit(level, code, extra = {}) {
    const record = { level: LEVELS.includes(level) ? level : 'info', code: sanitizeCode(code) };
    if (extra.phase) record.phase = sanitizeCode(extra.phase);
    if (extra.retryable === true) record.retryable = true;
    try {
      stream.write(`${JSON.stringify(record)}\n`);
    } catch (_) {
      // A broken stderr must never take the request down with it.
    }
  }
  return {
    debug: (code, extra) => emit('debug', code, extra),
    info: (code, extra) => emit('info', code, extra),
    warn: (code, extra) => emit('warn', code, extra),
    error: (code, extra) => emit('error', code, extra)
  };
}

module.exports = { LEVELS, sanitizeCode, createDiagnostics };
