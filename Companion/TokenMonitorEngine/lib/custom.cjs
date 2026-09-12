'use strict';

const { CODES, structuredError } = require('./errors.cjs');
const { isPlainObject, isNonEmptyString } = require('./protocol.cjs');

// Custom (non-scanned) usage records: values a host already knows and wants
// folded into the aggregate exactly once.
//
// The rules the contract fixes, and how they are applied here:
//
//   finite nonnegative    tokens/cost are number|null; anything else, including
//                         NaN/Infinity/negatives, is invalid_custom_source.
//   aggregated once       each accepted record contributes one synthetic client
//                         partition, so a record can never be added twice.
//   known overlaps        a record that names overlapsSourceIds is excluded
//                         while remaining in the caller's saved input; the
//                         engine only declines to add it.
//   missing evidence      a legacy cumulative record with no declared overlap is
//                         excluded rather than silently double-adding totals
//                         that the upstream sources already contain.
//   same-source           a custom sourceId that collides with another custom
//                         record, or with a scanned source id, is
//                         duplicate_custom_source.

const PERIODS = Object.freeze(['today', 'month', 'allTime']);
const COVERAGE_VALUES = Object.freeze(['known', 'partial', 'unknown']);
const PROVENANCE_VALUES = Object.freeze(['manual', 'legacy']);
const DATE_PATTERN = /^\d{4}-\d{2}-\d{2}$/;

function isFiniteNonNegativeOrNull(value) {
  if (value === null || value === undefined) return true;
  return typeof value === 'number' && Number.isFinite(value) && value >= 0;
}

function normalizeRecord(raw, index) {
  const sourceId = isNonEmptyString(raw?.sourceId) ? raw.sourceId.trim() : `custom-${index}`;
  const errors = [];
  const reject = (code) => {
    errors.push(structuredError(code, sourceId));
    return {
      record: null,
      excluded: {
        sourceId,
        providerId: isNonEmptyString(raw?.providerId) ? raw.providerId.trim() : undefined,
        toolId: isNonEmptyString(raw?.toolId) ? raw.toolId.trim() : undefined,
        accountId: isNonEmptyString(raw?.accountId) ? raw.accountId.trim() : undefined,
        period: isNonEmptyString(raw?.period) ? raw.period.trim() : undefined,
        reasonCode: code
      },
      errors
    };
  };

  if (!isPlainObject(raw)) return reject(CODES.INVALID_CUSTOM_SOURCE);
  if (!isNonEmptyString(raw.sourceId)) return reject(CODES.INVALID_CUSTOM_SOURCE);
  if (!isNonEmptyString(raw.providerId)) return reject(CODES.INVALID_CUSTOM_SOURCE);
  if (!isNonEmptyString(raw.toolId)) return reject(CODES.INVALID_CUSTOM_SOURCE);
  if (raw.accountId !== undefined && !isNonEmptyString(raw.accountId)) return reject(CODES.INVALID_CUSTOM_SOURCE);
  if (!isNonEmptyString(raw.period) || !PERIODS.includes(raw.period.trim())) return reject(CODES.INVALID_CUSTOM_SOURCE);
  if (raw.date !== undefined && (!isNonEmptyString(raw.date) || !DATE_PATTERN.test(raw.date.trim()))) {
    return reject(CODES.INVALID_CUSTOM_SOURCE);
  }
  if (!isFiniteNonNegativeOrNull(raw.tokens)) return reject(CODES.INVALID_CUSTOM_SOURCE);
  if (!isFiniteNonNegativeOrNull(raw.cost)) return reject(CODES.INVALID_CUSTOM_SOURCE);
  if (raw.currency !== undefined && !isNonEmptyString(raw.currency)) return reject(CODES.INVALID_CUSTOM_SOURCE);
  if (!isNonEmptyString(raw.coverage) || !COVERAGE_VALUES.includes(raw.coverage.trim())) {
    return reject(CODES.INVALID_CUSTOM_SOURCE);
  }
  if (!isNonEmptyString(raw.provenance) || !PROVENANCE_VALUES.includes(raw.provenance.trim())) {
    return reject(CODES.INVALID_CUSTOM_SOURCE);
  }
  const overlaps = raw.overlapsSourceIds === undefined ? [] : raw.overlapsSourceIds;
  if (!Array.isArray(overlaps) || overlaps.some((entry) => !isNonEmptyString(entry))) {
    return reject(CODES.INVALID_CUSTOM_SOURCE);
  }

  return {
    record: {
      sourceId: sourceId,
      providerId: raw.providerId.trim(),
      toolId: raw.toolId.trim(),
      accountId: isNonEmptyString(raw.accountId) ? raw.accountId.trim() : undefined,
      period: raw.period.trim(),
      date: isNonEmptyString(raw.date) ? raw.date.trim() : undefined,
      tokens: raw.tokens === undefined ? null : raw.tokens,
      cost: raw.cost === undefined ? null : raw.cost,
      currency: isNonEmptyString(raw.currency) ? raw.currency.trim() : undefined,
      coverage: raw.coverage.trim(),
      provenance: raw.provenance.trim(),
      overlapsSourceIds: overlaps.map((entry) => entry.trim())
    },
    excluded: null,
    errors
  };
}

function resolveCustomSources(request, context) {
  const accepted = [];
  const excluded = [];
  const errors = [];
  const seenIds = new Set();

  for (let index = 0; index < request.customSources.length; index += 1) {
    const { record, excluded: rejected, errors: recordErrors } = normalizeRecord(request.customSources[index], index);
    for (const error of recordErrors) errors.push(error);
    if (!record) {
      if (rejected) excluded.push(rejected);
      continue;
    }

    if (seenIds.has(record.sourceId) || context.upstreamSourceIds.has(record.sourceId)) {
      excluded.push({ ...record, reasonCode: CODES.DUPLICATE_CUSTOM_SOURCE });
      errors.push(structuredError(CODES.DUPLICATE_CUSTOM_SOURCE, record.sourceId));
      continue;
    }
    seenIds.add(record.sourceId);

    // A declared overlap is the caller telling us this record is already
    // represented elsewhere. Honouring it means not adding it, not deleting it.
    if (record.overlapsSourceIds.length > 0) {
      excluded.push({ ...record, reasonCode: 'known_overlap' });
      continue;
    }

    // A legacy cumulative record with no overlap evidence is exactly the shape
    // that double-counts: the scanned sources already contain its totals.
    if (record.provenance === 'legacy' && context.hasUpstreamTotals) {
      excluded.push({ ...record, reasonCode: CODES.OVERLAP_EVIDENCE_MISSING });
      errors.push(structuredError(CODES.OVERLAP_EVIDENCE_MISSING, record.sourceId));
      continue;
    }

    accepted.push(record);
  }

  return { accepted, excluded, errors };
}

// The synthetic client key a custom record contributes under. Upstream
// normalizes client names through normalizeClientName, which strips anything
// outside [a-z0-9_-]; sanitizing here means the key in the returned period is
// exactly the key the caller can look for, rather than a surprise after a
// normalization pass.
function clientKeyFor(record) {
  const sanitized = String(record.sourceId).toLowerCase().replace(/[^a-z0-9_-]+/g, '-').replace(/^-+|-+$/g, '');
  return `custom-${sanitized || 'record'}`;
}

// One synthetic client partition per accepted record, in the upstream period
// shape so it merges through the upstream aggregation rather than beside it.
function contributionFor(record) {
  const clientKey = clientKeyFor(record);
  const tokens = record.tokens === null ? 0 : record.tokens;
  const cost = record.cost === null ? 0 : record.cost;
  return {
    totalTokens: tokens,
    costUsd: cost,
    clients: { [clientKey]: tokens },
    clientCosts: { [clientKey]: cost },
    models: { [clientKey]: tokens },
    modelCosts: { [clientKey]: cost },
    capabilities: { tokenComponents: false, throughput: false }
  };
}

// Which period buckets a record lands in. A record names one period; the
// broader windows that contain it are widened, because a "month" record is
// also part of allTime.
function targetPeriods(period) {
  if (period === 'today') return ['today', 'month', 'allTime'];
  if (period === 'month') return ['month', 'allTime'];
  return ['allTime'];
}

function buildContributions(accepted) {
  const buckets = { today: [], month: [], allTime: [] };
  for (const record of accepted) {
    const contribution = contributionFor(record);
    for (const period of targetPeriods(record.period)) buckets[period].push(contribution);
  }
  return buckets;
}

module.exports = {
  PERIODS,
  COVERAGE_VALUES,
  PROVENANCE_VALUES,
  isFiniteNonNegativeOrNull,
  resolveCustomSources,
  clientKeyFor,
  contributionFor,
  targetPeriods,
  buildContributions
};
