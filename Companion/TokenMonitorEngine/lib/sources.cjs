'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { scopedEnvironment, withEnvironmentSync } = require('./runtime/source-scope.cjs');

const { CODES, structuredError } = require('./errors.cjs');
const { isPlainObject, isNonEmptyString } = require('./protocol.cjs');

// Which path roles each source kind may declare. The contract makes the role
// mandatory precisely so a host cannot hand over a bare path and have the
// engine guess what it means:
//   managedAccount + codexHome   the existing CODEX_HOME directory (never auth.json)
//   agentLogs      + logRoot     the exact logs root
//   agentLogs      + userHome    the upstream default-client layout under an approved home
//   custom         + customFile  a single user-configured local input
const ROLES_BY_KIND = Object.freeze({
  agentLogs: Object.freeze(['logRoot', 'userHome']),
  managedAccount: Object.freeze(['codexHome', 'configDirectory']),
  custom: Object.freeze(['customFile'])
});

const AUTHORITY_BY_KIND = Object.freeze({
  agentLogs: 'upstream',
  managedAccount: 'upstream',
  custom: 'custom'
});

const DIRECTORY_ROLES = new Set(['logRoot', 'userHome', 'codexHome', 'configDirectory']);

// Filenames that are a credential, not a home. A managedAccount source pointing
// at one of these is a request to read secrets, which this bridge never does.
const CREDENTIAL_BASENAMES = new Set([
  'auth.json',
  'credentials.json',
  '.credentials.json',
  'tokens.json',
  'token.json',
  'secrets.json',
  'keychain.json'
]);

const EMAIL_PATTERN = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
const SECRET_SHAPE_PATTERN = /(sk-[A-Za-z0-9]{8,}|gh[pousr]_[A-Za-z0-9]{8,}|Bearer\s+\S|-----BEGIN[A-Z ]*PRIVATE KEY|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.)/;
const ID_PATTERN = /^[a-z0-9][a-z0-9._-]{0,63}$/;

function isCredentialBasename(candidate) {
  return CREDENTIAL_BASENAMES.has(path.basename(candidate).toLowerCase());
}

// The accountId the contract accepts is a host-local opaque card id. An email
// or anything shaped like a credential is rejected at the boundary so it can
// never reach a log line or a response.
function isValidAccountId(value) {
  if (!isNonEmptyString(value)) return false;
  const text = value.trim();
  if (!/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/.test(text)) return false;
  if (EMAIL_PATTERN.test(text)) return false;
  if (SECRET_SHAPE_PATTERN.test(text)) return false;
  return true;
}

function isPathInside(child, parent) {
  if (child === parent) return false;
  const withSeparator = parent.endsWith(path.sep) ? parent : `${parent}${path.sep}`;
  return child.startsWith(withSeparator);
}

function normalizeSource(raw, index, context) {
  const errors = [];
  const id = isNonEmptyString(raw?.id) && ID_PATTERN.test(raw.id.trim().toLowerCase()) ? raw.id.trim() : `source-${index}`;

  const fail = (code) => {
    errors.push(structuredError(code, id));
    // Deliberately drops accountId/toolId/canonicalPath: a rejected source is
    // rejected precisely because its fields could not be trusted, so nothing
    // from it may be carried forward into coverage or the response.
    return {
      id,
      providerId: isNonEmptyString(raw?.providerId) && ID_PATTERN.test(raw.providerId.trim().toLowerCase()) ? raw.providerId.trim().toLowerCase() : 'unknown',
      toolId: undefined,
      accountId: undefined,
      kind: isNonEmptyString(raw?.kind) ? raw.kind.trim() : '',
      pathRole: isNonEmptyString(raw?.pathRole) ? raw.pathRole.trim() : '',
      authority: isNonEmptyString(raw?.authority) ? raw.authority.trim() : '',
      declaredPath: '',
      resolvedPath: null,
      enabled: raw?.enabled !== false,
      status: 'error',
      reasonCode: code,
      errors,
      target: null
    };
  };

  if (!isPlainObject(raw)) return fail(CODES.INVALID_SOURCE);
  if (!isNonEmptyString(raw.id) || !ID_PATTERN.test(raw.id.trim().toLowerCase())) return fail(CODES.INVALID_SOURCE);
  if (!isNonEmptyString(raw.providerId)) return fail(CODES.INVALID_SOURCE);

  const providerId = raw.providerId.trim().toLowerCase();
  const kind = isNonEmptyString(raw.kind) ? raw.kind.trim() : '';
  const pathRole = isNonEmptyString(raw.pathRole) ? raw.pathRole.trim() : '';
  const authority = isNonEmptyString(raw.authority) ? raw.authority.trim() : '';

  if (!Object.prototype.hasOwnProperty.call(ROLES_BY_KIND, kind)) return fail(CODES.INVALID_SOURCE);
  if (!ROLES_BY_KIND[kind].includes(pathRole)) return fail(CODES.INVALID_SOURCE);
  if (pathRole === 'configDirectory' && (providerId !== 'opencode' || context.operation !== 'collectLimits' || !isValidAccountId(raw.accountId))) return fail(CODES.INVALID_SOURCE);
  if (kind === 'managedAccount' && pathRole !== 'configDirectory' && providerId !== 'codex') return fail(CODES.INVALID_SOURCE);
  if (kind === 'managedAccount' && context.operation === 'collectLimits' && !isValidAccountId(raw.accountId)) return fail(CODES.INVALID_SOURCE);
  if (pathRole === 'logRoot' && context.catalog && !context.catalog.customPaths.normalizeCustomScanPaths({ [providerId]: [raw.canonicalPath] })[providerId]) return fail(CODES.INVALID_SOURCE);
  if (authority !== AUTHORITY_BY_KIND[kind]) return fail(CODES.INVALID_SOURCE);

  // Upstream kinds must name a client the pinned upstream actually tracks; a
  // custom kind carries its own tool identity and is only shape-checked.
  if (AUTHORITY_BY_KIND[kind] === 'upstream') {
    if (!context.clientIds.has(providerId)) return fail(CODES.INVALID_SOURCE);
  } else if (!ID_PATTERN.test(providerId)) {
    return fail(CODES.INVALID_SOURCE);
  }

  if (!isNonEmptyString(raw.canonicalPath)) return fail(CODES.INVALID_SOURCE);
  const declaredPath = raw.canonicalPath.trim();
  if (!path.isAbsolute(declaredPath)) return fail(CODES.INVALID_SOURCE);
  if (isCredentialBasename(declaredPath)) return fail(CODES.INVALID_SOURCE);

  if (raw.accountId !== undefined && !isValidAccountId(raw.accountId)) return fail(CODES.INVALID_SOURCE);
  if (raw.toolId !== undefined && (!isNonEmptyString(raw.toolId) || !ID_PATTERN.test(raw.toolId.trim().toLowerCase()))) return fail(CODES.INVALID_SOURCE);

  const enabled = raw.enabled !== false;
  const base = {
    id,
    providerId,
    toolId: isNonEmptyString(raw.toolId) ? raw.toolId.trim() : undefined,
    accountId: isNonEmptyString(raw.accountId) ? raw.accountId.trim() : undefined,
    kind,
    pathRole,
    authority,
    declaredPath,
    resolvedPath: null,
    enabled,
    status: 'ok',
    reasonCode: undefined,
    errors,
    target: null
  };

  if (!enabled) {
    base.status = 'excluded';
    base.reasonCode = 'disabled';
    return base;
  }

  let resolvedPath = null;
  try {
    resolvedPath = fs.realpathSync(declaredPath);
  } catch (_) {
    base.status = 'unavailable';
    base.reasonCode = 'path_missing';
    errors.push(structuredError(CODES.SOURCE_PATH_UNAVAILABLE, id));
    return base;
  }

  let stats = null;
  try {
    stats = fs.statSync(resolvedPath);
  } catch (_) {
    stats = null;
  }
  if (!stats) {
    base.status = 'unavailable';
    base.reasonCode = 'path_unreadable';
    errors.push(structuredError(CODES.SOURCE_PATH_UNAVAILABLE, id));
    return base;
  }
  if (DIRECTORY_ROLES.has(pathRole) && !stats.isDirectory()) {
    errors.push(structuredError(CODES.INVALID_SOURCE, id));
    base.status = 'error';
    base.reasonCode = CODES.INVALID_SOURCE;
    return base;
  }
  if (!DIRECTORY_ROLES.has(pathRole) && !stats.isFile()) {
    errors.push(structuredError(CODES.INVALID_SOURCE, id));
    base.status = 'error';
    base.reasonCode = CODES.INVALID_SOURCE;
    return base;
  }

  base.resolvedPath = resolvedPath;
  if (pathRole === 'configDirectory') base.scanRoots = [resolvedPath];
  if (authority === 'upstream' && pathRole !== 'configDirectory' && context.catalog) {
    const temporary = pathRole === 'codexHome'
      ? fs.realpathSync(fs.mkdtempSync(path.join(require('node:os').tmpdir(), 'token-monitor-next-roots-'))) : null;
    const home = temporary || resolvedPath;
    const env = scopedEnvironment(home, pathRole === 'codexHome' ? resolvedPath : null);
    let roots;
    try {
      roots = pathRole === 'logRoot' ? [resolvedPath]
        : withEnvironmentSync(env, home, () =>
          (context.catalog.collector.clientSourceRoots(providerId, { homeDir: home, env })[providerId] || [])
            .map(root => root.sourcePath || root.dir)
            .filter(root => !temporary || root === resolvedPath || isPathInside(root, resolvedPath)));
    } finally { if (temporary) fs.rmSync(temporary, { recursive: true, force: true }); }
    base.scanRoots = roots.map(root => { try { return fs.realpathSync(root); } catch { return path.resolve(root); } });
    if (!roots.length) { base.status = 'unavailable'; base.reasonCode = 'unsupported_scope'; }
  }
  return base;
}

// Canonicalises and overlap-checks every enabled source before anything is
// scanned. First declaration wins: a later source that is the same real
// directory, or nested inside an earlier one, is excluded rather than scanned a
// second time.
function resolveSources(request, context) {
  const errors = [];
  const seenIds = new Set();
  const resolved = [];

  for (let index = 0; index < request.sources.length; index += 1) {
    const source = normalizeSource(request.sources[index], index, { ...context, operation: request.operation });
    if (seenIds.has(source.id)) {
      source.status = 'excluded';
      source.reasonCode = CODES.DUPLICATE_SOURCE_ID;
      source.resolvedPath = null;
      errors.push(structuredError(CODES.DUPLICATE_SOURCE_ID, source.id));
    } else {
      seenIds.add(source.id);
    }
    resolved.push(source);
    for (const error of source.errors) errors.push(error);
  }

  // Overlap pass runs only over sources that resolved to a real path and are
  // still in play; an unavailable source cannot collide with anything.
  const accepted = resolved.filter((source) => source.status === 'ok' && source.resolvedPath);
  for (let i = 0; i < accepted.length; i += 1) {
    for (let j = i + 1; j < accepted.length; j += 1) {
      const earlier = accepted[i];
      const later = accepted[j];
      if (earlier.status !== 'ok' || later.status !== 'ok') continue;
      if (earlier.providerId !== later.providerId) continue;
      const left = earlier.scanRoots || [earlier.resolvedPath];
      const right = later.scanRoots || [later.resolvedPath];
      const same = left.length === right.length && left.every(root => right.includes(root));
      const overlap = left.some(a => right.some(b => a === b || isPathInside(a, b) || isPathInside(b, a)));
      if (same) {
        later.status = 'excluded';
        later.reasonCode = CODES.DUPLICATE_ROOT;
        errors.push(structuredError(CODES.DUPLICATE_ROOT, later.id));
        continue;
      }
      if (overlap) {
        later.status = 'excluded';
        later.reasonCode = CODES.OVERLAPPING_ROOT;
        errors.push(structuredError(CODES.OVERLAPPING_ROOT, later.id));
      }
    }
  }

  return { sources: resolved, errors };
}

// Groups the sources that survived validation into one scan target per distinct
// canonical root. A target is what a single upstream collect call is scoped to.
function buildTargets(sources) {
  return sources.filter(source => source.status === 'ok' && source.resolvedPath && source.authority === 'upstream')
    .map(source => ({ root: source.resolvedPath, ...(source.pathRole === 'configDirectory' ? { declaredRoot: source.declaredPath } : {}), pathRole: source.pathRole, kind: source.kind,
      providerIds: [source.providerId], sourceIds: [source.id], accountId: source.accountId,
      managed: source.kind === 'managedAccount', evidence: {} }));
}

// The contract requires includeLiveCodexAccount to be an explicit opt-in backed
// by a source the host verified. Asking for the live account without supplying
// one is a request to invent a system home, which the engine never does.
function checkLiveCodexAccount(request, sources) {
  if (!request.options.includeLiveCodexAccount) return null;
  const supplied = sources.some((source) => (
    source.status === 'ok'
    && source.kind === 'managedAccount'
    && source.pathRole === 'codexHome'
    && source.providerId === 'codex'
  ));
  if (supplied) return null;
  return structuredError(CODES.INVALID_SOURCE);
}

module.exports = {
  ROLES_BY_KIND,
  AUTHORITY_BY_KIND,
  CREDENTIAL_BASENAMES,
  isValidAccountId,
  isPathInside,
  normalizeSource,
  resolveSources,
  buildTargets,
  checkLiveCodexAccount
};
