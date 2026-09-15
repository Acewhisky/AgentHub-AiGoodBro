'use strict';

// Credential-minting endpoints, in one place.
//
// The list is deliberately narrow and enumerated rather than "anything with
// token in it": provider *usage* endpoints are the whole point of collectLimits
// and must keep working. Both the providerHelpers overlay (which sees fetchJson)
// and the injected deps.fetch wrapper (which sees providers that fetch directly)
// consult this same list, so the gate cannot drift between the two paths.

const CREDENTIAL_ENDPOINT_PATTERNS = Object.freeze([
  /\/oauth\/token(?:\?|$)/i,
  /\/oauth2\/token(?:\?|$)/i,
  /\/v1\/oauth\/token(?:\?|$)/i,
  /\/login\/oauth\/access_token/i,
  /\/token\/refresh/i,
  /[?&]grant_type=refresh_token/i
]);

function isCredentialEndpoint(url) {
  const text = String(url || '');
  return CREDENTIAL_ENDPOINT_PATTERNS.some((pattern) => pattern.test(text));
}

// CLI spawns that exist to refresh a credential rather than to read usage.
const CREDENTIAL_CLI_COMMANDS = Object.freeze(['claude']);

function commandBasename(command) {
  const text = String(command || '');
  const parts = text.split(/[\\/]/);
  return parts[parts.length - 1].toLowerCase().replace(/\.(?:exe|cmd|bat)$/, '');
}

function isCredentialCli(command) {
  return CREDENTIAL_CLI_COMMANDS.includes(commandBasename(command));
}

module.exports = {
  CREDENTIAL_ENDPOINT_PATTERNS,
  CREDENTIAL_CLI_COMMANDS,
  isCredentialEndpoint,
  commandBasename,
  isCredentialCli
};
