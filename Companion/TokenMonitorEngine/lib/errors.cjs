'use strict';

// Structured error taxonomy for the Token Monitor bridge.
//
// The response contract fixes the error shape to { code, sourceId?, retryable }.
// Nothing else is emitted: no paths, no raw session text, no credential
// material, no upstream exception messages. Human-readable detail never leaves
// the process through this object; it is reported (sanitized) on stderr as a
// diagnostic code, and only in the calling host's own log.

const CODES = Object.freeze({
  INVALID_REQUEST: 'invalid_request',
  UNSUPPORTED_SCHEMA_VERSION: 'unsupported_schema_version',
  UNKNOWN_OPERATION: 'unknown_operation',
  REQUEST_TOO_LARGE: 'request_too_large',
  RESPONSE_TOO_LARGE: 'response_too_large',
  TIMEOUT: 'timeout',
  CANCELLED: 'cancelled',
  INVALID_SOURCE: 'invalid_source',
  DUPLICATE_SOURCE_ID: 'duplicate_source_id',
  DUPLICATE_ROOT: 'duplicate_root',
  OVERLAPPING_ROOT: 'overlapping_root',
  SOURCE_PATH_UNAVAILABLE: 'source_path_unavailable',
  INVALID_CUSTOM_SOURCE: 'invalid_custom_source',
  DUPLICATE_CUSTOM_SOURCE: 'duplicate_custom_source',
  OVERLAP_EVIDENCE_MISSING: 'overlap_evidence_missing',
  CAPABILITY_DISABLED: 'capability_disabled',
  COLLECTION_FAILED: 'collection_failed',
  LIMITS_FAILED: 'limits_failed',
  INTERNAL_ERROR: 'internal_error'
});

// Codes that are worth retrying verbatim: the request itself was well formed
// and the same call could succeed later.
const RETRYABLE = new Set([
  CODES.TIMEOUT,
  CODES.COLLECTION_FAILED,
  CODES.LIMITS_FAILED,
  CODES.SOURCE_PATH_UNAVAILABLE,
  CODES.INTERNAL_ERROR
]);

function structuredError(code, sourceId) {
  const error = { code, retryable: RETRYABLE.has(code) };
  if (typeof sourceId === 'string' && sourceId.length > 0) error.sourceId = sourceId;
  return error;
}

// A request-level failure: the whole call is rejected and the process exits
// non-zero. Distinct from a per-source error, which is reported inside a
// successful response envelope.
class BridgeError extends Error {
  constructor(code, options = {}) {
    super(code);
    this.name = 'BridgeError';
    this.code = code;
    this.sourceId = options.sourceId;
    this.exitCode = Number.isInteger(options.exitCode) ? options.exitCode : 2;
  }

  toStructured() {
    return structuredError(this.code, this.sourceId);
  }
}

module.exports = { CODES, RETRYABLE, structuredError, BridgeError };
