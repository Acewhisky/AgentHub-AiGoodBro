'use strict';

const { isNonEmptyString } = require('./protocol.cjs');

// Coverage is the authoritative statement of what the caller actually knows.
//
// The contract's rules, restated as the reduction implemented here:
//
//   missing entry is unknown    a source/metric/date with no entry is not a
//                               zero; it is simply absent, and any consumer
//                               filtering on coverage treats it as unknown.
//   known zero stays zero       a collected 0 with status known is a real
//                               measurement and is reported as known.
//   one unavailable source      is enough to stop the day from being known, even
//                               when every other source reported a true zero.
//   days summary                known only if every included entry for that day
//                               is known.

const METRICS = Object.freeze(['tokens', 'cost', 'quota']);

const DATE_FORMATTERS = new Map();

function formatterFor(timeZone) {
  let formatter = DATE_FORMATTERS.get(timeZone);
  if (!formatter) {
    formatter = new Intl.DateTimeFormat('en-CA', {
      timeZone,
      year: 'numeric',
      month: '2-digit',
      day: '2-digit'
    });
    DATE_FORMATTERS.set(timeZone, formatter);
  }
  return formatter;
}

// Civil date (YYYY-MM-DD) of an instant in the declared timezone.
function civilDate(date, timeZone) {
  return formatterFor(timeZone).format(date);
}

function monthKeyOf(civilDateString) {
  return String(civilDateString).slice(0, 7);
}

function reduceStatuses(statuses) {
  if (statuses.length === 0) return 'unknown';
  if (statuses.every((status) => status === 'known')) return 'known';
  if (statuses.some((status) => status === 'known' || status === 'partial')) return 'partial';
  return 'unknown';
}

// Per-source status of the token metric. A source that could not be scanned
// reports unknown for every date; a source that scanned reports known, because
// upstream's own client status is the only evidence available per source.
function tokenStatusFor(source, date) {
  const evidence = source.evidence || {};
  const client = source.providerId;
  const state = evidence.clientStatus?.[client];
  const todayKnown = date === evidence.todayKey && evidence.scanSucceeded && !evidence.usageFailed
    && (state === 'active' || state === 'waiting')
    && Number.isFinite(evidence.today?.clients?.[client]);
  const day = evidence.historySucceeded && evidence.history?.daily?.find(day => day.date === date);
  const historyKnown = day && Number.isFinite(day.perClient?.[client]?.tokens);
  return todayKnown || historyKnown ? 'known' : 'unknown';
}
function costStatusFor(source, date) {
  if (tokenStatusFor(source, date) !== 'known') return 'unknown';
  const evidence = source.evidence || {};
  // Only assert a price for models for which the original catalog resolves one.
  const period = date === evidence.todayKey ? evidence.today : null;
  const models = Object.keys(period?.models || {});
  return models.length && models.every(model => evidence.pricedModels?.has(model)) ? 'known' : 'unknown';
}
function quotaStatusFor(source, snapshot) {
  if (source.kind !== 'managedAccount') return null;
  const targets = (snapshot?.targets || []).filter(target => target.sourceId === source.id
    && target.providerId === source.providerId && target.accountId === source.accountId);
  if (targets.length !== 1) return 'unknown';
  const providers = targets[0].snapshot.providers.filter(provider => provider.provider === 'codex');
  return providers.length === 1 && providers[0].status === 'ok'
    && providers[0].windows?.some(window => window.additional !== true && Number.isFinite(window.usedPercent)) ? 'known' : 'unknown';
}

function collectDates({ history, acceptedCustom, todayKey, cap = 400 }) {
  const dates = new Set();
  if (history && Array.isArray(history.daily)) {
    for (const day of history.daily) {
      if (isNonEmptyString(day?.date)) dates.add(day.date.trim());
    }
  }
  for (const record of acceptedCustom) {
    if (isNonEmptyString(record.date)) dates.add(record.date.trim());
  }
  if (isNonEmptyString(todayKey)) dates.add(todayKey);
  return [...dates].sort().slice(-cap);
}

function computeCoverage(input) {
  const {
    sources,
    acceptedCustom,
    excludedCustom,
    history,
    limitsSnapshot,
    timezone,
    todayKey,
    options
  } = input;

  const dates = collectDates({ history, acceptedCustom, todayKey });
  // Only sources that were actually admissible contribute entries. A source
  // rejected as invalid contributes nothing at all — including no echo of the
  // fields that made it invalid.
  const included = sources.filter((source) => source.status === 'ok' || source.status === 'unavailable');
  const entries = [];

  for (const source of included) {
    for (const date of dates) {
      entries.push({
        sourceId: source.id,
        providerId: source.providerId,
        ...(source.toolId ? { toolId: source.toolId } : {}),
        date,
        metric: 'tokens',
        status: tokenStatusFor(source, date)
      });
      entries.push({
        sourceId: source.id,
        providerId: source.providerId,
        ...(source.toolId ? { toolId: source.toolId } : {}),
        date,
        metric: 'cost',
        status: costStatusFor(source, date)
      });
      const quota = quotaStatusFor(source, limitsSnapshot);
      if (quota) {
        entries.push({
          sourceId: source.id,
          providerId: source.providerId,
          ...(source.accountId ? { accountId: source.accountId } : {}),
          date,
          metric: 'quota',
          status: quota
        });
      }
    }
  }

  // Excluded sources are reported as excluded in the sources array and are not
  // counted as known anywhere, but they also do not manufacture unknown entries
  // for dates they were never going to cover.
  for (const record of acceptedCustom) {
    if (!isNonEmptyString(record.date)) continue;
    entries.push({
      sourceId: record.sourceId,
      providerId: record.providerId,
      ...(record.toolId ? { toolId: record.toolId } : {}),
      ...(record.accountId ? { accountId: record.accountId } : {}),
      date: record.date,
      metric: 'tokens',
      status: record.coverage === 'known' ? 'known' : record.coverage === 'partial' ? 'partial' : 'unknown'
    });
    entries.push({
      sourceId: record.sourceId,
      providerId: record.providerId,
      ...(record.toolId ? { toolId: record.toolId } : {}),
      ...(record.accountId ? { accountId: record.accountId } : {}),
      date: record.date,
      metric: 'cost',
      status: record.cost === null ? 'unknown' : record.coverage === 'known' ? 'known' : record.coverage === 'partial' ? 'partial' : 'unknown'
    });
  }

  const byDate = new Map();
  for (const entry of entries) {
    if (entry.metric !== 'tokens') continue;
    if (!byDate.has(entry.date)) byDate.set(entry.date, []);
    byDate.get(entry.date).push(entry.status);
  }
  const days = [...byDate.entries()]
    .map(([date, statuses]) => ({ date, status: reduceStatuses(statuses) }))
    .sort((a, b) => a.date.localeCompare(b.date));

  const costStatuses = entries.filter((entry) => entry.metric === 'cost').map((entry) => entry.status);

  return {
    entries,
    days,
    cost: reduceStatuses(costStatuses),
    excludedCustomCount: excludedCustom.length
  };
}

module.exports = {
  METRICS,
  civilDate,
  monthKeyOf,
  reduceStatuses,
  collectDates,
  computeCoverage
};
