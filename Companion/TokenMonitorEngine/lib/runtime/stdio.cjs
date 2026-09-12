'use strict';

// Bounded stdin/stdout framing.
//
// The contract bounds both directions. Reading is bounded so a malformed or
// hostile host cannot make the bridge allocate without limit; writing is
// bounded so an oversized payload fails with a structured error instead of
// being truncated into invalid JSON on the wire.

const { CODES, BridgeError } = require('../errors.cjs');

const DEFAULT_MAX_REQUEST_BYTES = 8 * 1024 * 1024;
const DEFAULT_MAX_RESPONSE_BYTES = 32 * 1024 * 1024;

function readStdinBounded(stream, maxBytes = DEFAULT_MAX_REQUEST_BYTES) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let total = 0;
    let settled = false;
    const finish = (fn, value) => {
      if (settled) return;
      settled = true;
      stream.removeListener('data', onData);
      stream.removeListener('end', onEnd);
      stream.removeListener('error', onError);
      fn(value);
    };
    const onData = (chunk) => {
      total += chunk.length;
      if (total > maxBytes) {
        try { stream.pause(); } catch (_) { /* not pausable */ }
        finish(reject, new BridgeError(CODES.REQUEST_TOO_LARGE));
        return;
      }
      chunks.push(chunk);
    };
    const onEnd = () => finish(resolve, Buffer.concat(chunks, total).toString('utf8'));
    const onError = () => finish(reject, new BridgeError(CODES.INVALID_REQUEST));
    stream.on('data', onData);
    stream.on('end', onEnd);
    stream.on('error', onError);
  });
}

function writeStdoutBounded(stream, text, maxBytes = DEFAULT_MAX_RESPONSE_BYTES) {
  const size = Buffer.byteLength(text, 'utf8');
  if (size > maxBytes) throw new BridgeError(CODES.RESPONSE_TOO_LARGE);
  stream.write(text);
  return size;
}

module.exports = {
  DEFAULT_MAX_REQUEST_BYTES,
  DEFAULT_MAX_RESPONSE_BYTES,
  readStdinBounded,
  writeStdoutBounded
};
