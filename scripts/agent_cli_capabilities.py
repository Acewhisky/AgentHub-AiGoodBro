#!/usr/bin/env python3
"""Static capability catalog for the agent-cli thin entry.

Capabilities are statements about entrypoints and boundaries — never a claim of
live account success. Local installation inventory is separate from unverified
authentication, quota and execution state;
running / result-ready / accepted only ever come from the shared registry and
receipts (see agent-cli.py status/result).

Receipt references point at existing desensitized receipts and are validated
for existence and size only; no receipt is re-executed and no credential file
is ever opened.

Per-execution outcomes — including any past CLI error observed on any machine —
are that run's history, carried by its receipt and registry status only. The
catalog states what this tree's code can do, never what a route returned on
some earlier probe.
"""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import stat

WORKBUDDY_EXECUTABLE = "/Applications/WorkBuddy.app/Contents/Resources/app.asar.unpacked/cli/bin/codebuddy"
WORKBUDDY_MODEL = "deepseek-v4.1-flash"
WORKBUDDY_FREE_MODELS = (WORKBUDDY_MODEL, "hy4-preview-f", "hy3")

# Receipts are referenced by filename only. The local directory that holds
# them is resolved at runtime from AGENT_CLI_RECEIPT_DIR and is never part of
# the catalog, the payload, or this source: a static private absolute path in
# a published capability statement would leak local directory structure. An
# unset root leaves the receipt inventory empty. Presence never proves a run.
RECEIPT_DIR_ENV = "AGENT_CLI_RECEIPT_DIR"
RECEIPT_FILENAMES = {"workbuddy": ("RECEIPT-WB-minimal-0911v1.md", "TASK-WB-CANCEL-TIMEOUT-0911v1.md")}


def receipt_dir() -> Path | None:
    value = os.environ.get(RECEIPT_DIR_ENV, "").strip()
    return Path(value) if value else None


RECEIPT_REFS: dict[str, list[Path]] = {
    product: ([receipt_dir() / name for name in names] if receipt_dir() else [])
    for product, names in RECEIPT_FILENAMES.items()
}

QUOTA_NOTE = ("Subscription quota is unknown; the entry never continues on remaining balance "
              "and never falls back to paid APIs.")

CATALOG: dict[str, dict] = {
    "codex": {
        "product": "codex",
        "quotaKnown": {"value": False, "note": QUOTA_NOTE},
        "plan": {"supported": True, "entry": "scripts/next_dispatch_activity.py plan (managed, reused verbatim)"},
        "run": {"supported": True, "entry": "scripts/next_dispatch_activity.py run (managed, reused verbatim)",
                "note": "dispatch stays inside the managed entry; agent-cli never forks its own runner for codex"},
        "cancel": {"supported": True, "entry": "agent-cli cancel (owner + lease + PID-birth verified)"},
        "constraints": ["plan/status/result reuse the managed entry; no second scheduler"],
    },
    "grok": {
        "product": "grok",
        "quotaKnown": {"value": False, "note": QUOTA_NOTE + " Grok Build shares a weekly usage pool. "
                          "This adapter is not a live billing probe. The existing LocalCLIQuotaReader "
                          "does not expose the paid-fallback fields required by the runner bridge."},
        "plan": {"supported": True,
                 "entry": "agent-cli plan --product grok (official ~/.grok/bin/grok; local dry-run, "
                          "no launch; environment redirects cannot change the production pin; "
                          "refuses grok_plan_entry_missing when the official launcher is absent)"},
        "run": {"supported": False,
                "reason": "grok_quota_bridge_missing",
                "model": "grok-4.6-build",
                "note": "the argv and shared-lock adapter are reviewable, but production launch stays "
                        "fail-closed until the native reader supplies an authenticated snapshot with "
                        "subscription, paid-fallback, identity, model, environment and executable evidence"},
        "cancel": {"supported": True, "entry": "agent-cli cancel works on any cooperating registry lease"},
        "constraints": ["status/result are registry-level and already cover grok leases",
                        "only exact grok-4.6-build is admitted; grok-4.6 alias mapping and grok-4.5 are unverified",
                        "official pin is ~/.grok/bin/grok; environment redirects never change it",
                        "caller-authored JSON never opens run; balance never substitutes for subscription evidence"],
    },
    "workbuddy": {
        "product": "workbuddy",
        "quotaKnown": {"value": False, "note": QUOTA_NOTE},
        "plan": {"supported": True, "entry": "agent-cli plan --product workbuddy (local dry-run, no launch)"},
        "run": {"supported": True,
                "entry": "agent-cli run --product workbuddy (double switch: --allow-run AND AGENT_CLI_ALLOW_RUN=1)",
                "model": WORKBUDDY_MODEL},
        "cancel": {"supported": True, "entry": "agent-cli cancel (owner + lease + PID-birth verified)"},
        "constraints": [
            "only the app-bundled CLI binary is the official WorkBuddy entry; external codebuddy/cbc is a different product",
            "native free-model order: deepseek-v4.1-flash, hy4-preview-f, hy3; no automatic fallback",
            "the receipt above is referenced read-only and never re-executed",
        ],
    },
    "zcode-desktop": {
        "product": "zcode-desktop",
        "quotaKnown": {"value": False, "note": QUOTA_NOTE + " No CLI probe is made here and none of the "
                          "desktop session, membership or a past CLI outcome is evidence about the "
                          "current CLI subscription."},
        "plan": {"supported": False,
                 "reason": "zcode_managed_runner_missing; agent-cli plan/run do not accept this product in this tree"},
        "run": {"supported": False,
                "reason": "zcode_managed_runner_missing; agent-cli plan/run do not accept this product in this tree"},
        "cancel": {"supported": True, "entry": "agent-cli cancel works on any cooperating registry lease"},
        "constraints": [
            "ZCode.app presence is install inventory only; it proves nothing about CLI access, Flash subscription or call success",
            "a past CLI execution failure is that run's receipt/status history, never a fact in this catalog",
        ],
    },
}

RECEIPT_MAX_BYTES = 256 * 1024


def receipt_status() -> dict[str, dict]:
    """Existence/size checks for referenced receipts only; content is never read.

    Rows carry the receipt filename, never an absolute local path. A
    symlinked reference counts as missing: minimal-verified claims must rest
    on the regular file that was written, not on a redirectable name (F-11).
    """
    out: dict[str, dict] = {}
    for product, paths in RECEIPT_REFS.items():
        rows = []
        for path in paths:
            try:
                info = path.lstat()
                regular = stat.S_ISREG(info.st_mode)
                rows.append({"ref": path.name, "exists": regular,
                             "bytes": info.st_size if regular else None,
                             "plausible": regular and 0 < info.st_size <= RECEIPT_MAX_BYTES})
            except OSError:
                rows.append({"ref": path.name, "exists": False, "bytes": None, "plausible": False})
        out[product] = {"receipts": rows}
    return out


def grok_official_installed() -> bool:
    """Inventory of the official pin only. Test redirects never count."""
    import agent_cli_grok as grok_entry
    resolved = grok_entry.resolve_regular_executable(Path.home() / ".grok" / "bin" / "grok")
    return bool(resolved and os.access(resolved, os.X_OK))


def catalog_for(product: str | None) -> dict:
    receipts = receipt_status()
    # Presence is inventory, never successful authentication or execution.
    # Do not export another machine's historical login as a current fact.
    capabilities: dict[str, dict] = {}
    for name, entry in CATALOG.items():
        if name == "workbuddy":
            installed = os.path.isfile(WORKBUDDY_EXECUTABLE) and os.access(WORKBUDDY_EXECUTABLE, os.X_OK)
        elif name == "zcode-desktop":
            installed = any((root / "ZCode.app").is_dir() for root in (Path("/Applications"), Path.home() / "Applications"))
        elif name == "grok":
            installed = grok_official_installed()
        else:
            installed = shutil.which(name) is not None
        min_verified = {"value": False,
                        "evidence": "receipt presence alone does not verify marker, model, cost or freshness"}
        if name == "grok":
            import agent_cli_grok as grok_entry
            min_verified = grok_entry.minimal_verified_status()
        entry = {**entry,
                 "installed": {"value": installed, "evidence": "local executable or app presence; not a launch"},
                 "authenticated": {"value": None, "evidence": "not checked; no credential access"},
                 "minimalVerified": min_verified}
        capabilities[name] = entry
    if product is None:
        payload = {"schemaVersion": 1, "capabilities": capabilities, "receiptStatus": receipts}
    else:
        if product not in capabilities:
            raise KeyError(product)
        payload = {"schemaVersion": 1, "capabilities": {product: capabilities[product]},
                   "receiptStatus": {product: receipts.get(product, {"receipts": []})}}
    payload["stateVocabulary"] = ["installed", "authenticated", "quota-known", "minimal-verified",
                                  "running", "result-ready", "accepted"]
    payload["note"] = "entry capabilities and local installation inventory; authentication and minimal execution are not inferred"
    return payload
