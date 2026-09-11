#!/usr/bin/env python3
"""Read-only Grok quota bridge contract.

The native ``LocalCLIQuotaReader.loadGrok`` currently has no authenticated
Swift-to-Python hand-off.  In particular, its result does not carry the
on-demand cap/used values needed by the run gate.  Keep the production bridge
closed until the native side exports an authenticated, identity-bound
snapshot.  The explicit test seam exists only for offline fixtures and is
never enabled by a production environment.
"""

from __future__ import annotations


PRODUCTION_READY = False

# This is descriptive metadata for the future native writer, not evidence that
# one exists today.  Do not add auth, Keychain, network, or billing parsing to
# this module.
BRIDGE_SCHEMA_VERSION = 1
BRIDGE_PRODUCER = "LocalCLIQuotaReader.loadGrok"
BRIDGE_SOURCE = "native-local-cli-quota-bridge-v1"


def available() -> bool:
    """Whether quota evidence can be trusted in this process.

    Production remains false until a native producer and authenticated
    hand-off are implemented. Tests inject a trusted in-memory snapshot in
    process; no environment variable can open this gate in a CLI child.
    """
    return PRODUCTION_READY


def contract() -> dict:
    """Return a non-sensitive contract for parent/native wiring review."""
    return {
        "schemaVersion": BRIDGE_SCHEMA_VERSION,
        "producer": BRIDGE_PRODUCER,
        "source": BRIDGE_SOURCE,
        "productionReady": PRODUCTION_READY,
        "reason": "LocalCLIQuotaReader.loadGrok has no authenticated Swift-to-Python hand-off "
                  "and does not expose on-demand cap/used values",
        "required": [
            "identityFingerprint from the native reader, used directly as Registry accountKey",
            "fresh subscription remaining quota derived specifically from creditUsagePercent",
            "raw on-demand cap and used values both proving paid fallback is impossible",
            "exact requestedModel and runner-observed actualModel",
            "hashed isolated-environment identity matching the minimal-return receipt",
            "resolved official Grok executable SHA-256",
            "authenticated atomic producer hand-off that a caller-authored file cannot imitate",
        ],
    }
