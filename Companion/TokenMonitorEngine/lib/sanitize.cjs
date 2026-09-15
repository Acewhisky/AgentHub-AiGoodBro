'use strict';
const { createHash } = require('node:crypto');
const opaque = value => 'opaque-' + createHash('sha256').update(String(value)).digest('hex').slice(0, 24);
const secretKey = /^(?:auth|authorization|credentials?|access[_-]?token|refresh[_-]?token|id[_-]?token|api[_-]?key|password|cookie|accountEmail|email|prompt|response|messagesText|content|text|transcript|stderr|stack)$/i;
const privateField = /^(?:path|.*Path|cwd|home|homeDir|directory|title|projectLabel|accountLabel|accountName|hostname|workspace|workspaceId|projectId|sessionId|sessionKey)$/i;
const privateDimension = /^(sessions|projects|workspaces|accounts)$/;
const privateValue = /(?:\/Users\/|\/home\/|\/private\/|\/tmp\/|[A-Za-z]:\\|file:\/\/|[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}\b)/;
const secretValue = /(?:Bearer\s+\S+|sk-[A-Za-z0-9]{8,}|gh[pousr]_[A-Za-z0-9]{8,}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]+\.|-----BEGIN.*PRIVATE KEY)/;
function sanitize(value, field = '', dimension = false, privateRecord = false) {
  if (value === null || typeof value === 'number' || typeof value === 'boolean') return value;
  if (typeof value === 'string') {
    if (secretValue.test(value)) return undefined;
    if ((privateRecord && /^(id|name|label)$/.test(field)) || privateField.test(field) || privateValue.test(value) || value.startsWith('/')) return opaque(value);
    return value;
  }
  if (Array.isArray(value)) return value.map(item => sanitize(item, field, false, privateRecord || privateDimension.test(field))).filter(item => item !== undefined);
  if (!value || typeof value !== 'object') return undefined;
  const result = {};
  for (const [key, item] of Object.entries(value)) {
    if (secretKey.test(key) || secretValue.test(key)) continue;
    const safeKey = dimension || privateValue.test(key) || key.startsWith('/') ? opaque(key) : key;
    const safe = sanitize(item, key, privateDimension.test(key), dimension || privateRecord);
    if (safe !== undefined) Object.defineProperty(result, safeKey, { value: safe, enumerable: true, configurable: true });
  }
  return result;
}
module.exports = { sanitize, opaque };
