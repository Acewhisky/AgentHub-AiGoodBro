#!/usr/bin/env python3
"""Managed Grok plan/run adapter for the agent-cli unified entry.

Reuses the shared Registry and activity.supervise() (list argv, shell=False).
No second scheduler, no resident process, no network, no credential / cookie /
keychain / auth-file access, and no real model invocation from this module.

Production executable is the fixed official `~/.grok/bin/grok` (resolved to a
regular file). Environment redirects never change that production pin;
`--executable` is an explicit offline test seam and requires the test switch.

Plan never launches. Run stays behind --allow-run AND AGENT_CLI_ALLOW_RUN=1
and refuses unless a native bridge supplies a desensitized official
subscription evidence file that is fresh (minutes, not a day), bound to the
same-account fingerprint and the resolved executable SHA, shows
state=available, remaining quota > 0, and on-demand cap is zero (no paid
fallback). The native bridge is currently unavailable: caller JSON is never a
production probe and this adapter never reads tokens. An API balance never
substitutes. An explicit test seam exists only for offline fixture validation.
"""

from __future__ import annotations

import hashlib
import json
import math
import os
from pathlib import Path
import stat
import time

import next_dispatch_activity as activity      # noqa: E402 (managed module, reused)
import next_dispatch_invocation as invocation  # noqa: E402 (managed module, reused)
import agent_cli_support as support            # noqa: E402
import agent_cli_grok_bridge as quota_bridge  # noqa: E402
from agent_cli_support import Refusal, Unsupported  # noqa: E402

EXIT_OK = 0

# Closed allowlist. No Grok 4.6 -> 4.6-build mapping is accepted without an
# official entry proof in this tree, so only the exact runner model is
# admitted. Requests are never silently remapped; no fallback model.
GROK_MODELS = ("grok-4.6-build",)
GROK_DEFAULT_MODEL = "grok-4.6-build"

# Verified non-interactive file-task argv shape (1.0.25). The prompt travels
# by --prompt-file, not argv, so brief size is bounded by the file reader.
# --permission-mode acceptEdits is intentionally absent: on 1.0.25 it was
# observed to drop edit confirmations with exit 0 and no file written.
# --max-turns/--single stay reserved for one-shot marker checks, not file tasks.
GROK_TOOLS = "read_file,search_replace,grep,list_dir,todo_write"

GROK_OFFICIAL_RELATIVE = Path(".grok/bin/grok")
GROK_MIN_RETURN_DIR_ENV = "AGENT_CLI_GROK_MIN_RETURN_DIR"

# Minutes-not-days: a caller-exported file older than five minutes cannot
# stand in for a live same-account probe. Future timestamps beyond slack
# are invalid rather than "fresh".
GROK_QUOTA_EVIDENCE_MAX_AGE_SECONDS = 300.0
GROK_QUOTA_EVIDENCE_MAX_BYTES = 64 * 1024
GROK_QUOTA_EVIDENCE_FUTURE_SLACK_SECONDS = 5.0
GROK_EVIDENCE_SOURCE = quota_bridge.BRIDGE_SOURCE
GROK_MIN_RETURN_MAX_AGE_SECONDS = 86400.0
GROK_MIN_RETURN_MAX_BYTES = 64 * 1024


def quota_probe_contract() -> dict:
    """Minimal field contract for the parent Swift LocalCLIQuotaReader adapter.

    This Python entry does not probe billing, read auth.json, or touch tokens.
    A future native parent must export a desensitized, authenticated snapshot;
    the current LocalCLIQuotaResult is not sufficient. identityFingerprint is used as-is (already SHA-256 of
    next-local-cli:v1:grok:<identity>); this module does not hash identity
    again. Registry accountKey must be that same 64-hex fingerprint so native
    App and Python reservations collide. The current LocalCLIQuotaReader does
    not expose enough information to derive the paid-fallback gate, so the
    native bridge remains unavailable until it supplies all fields below.
    """
    return {
        "schemaVersion": 1,
        "product": "grok",
        "source": GROK_EVIDENCE_SOURCE,
        "bridge": quota_bridge.contract(),
        "capturedAt": "unix seconds, finite, not future, age <= 300s",
        "accountFingerprint": "64-hex from LocalCLIQuotaReader.identityFingerprint; not re-hashed here",
        "requestedModel": GROK_DEFAULT_MODEL,
        "actualModel": GROK_DEFAULT_MODEL,
        "environmentKey": "64-hex hash of the isolated Grok environment",
        "minimalReturnVerified": True,
        "state": "available",
        "quotaSource": "creditUsagePercent",
        "creditUsagePercent": "official finite 0-100 used value; remaining is derived and must be > 0",
        "onDemandCap": 0,
        "onDemandUsed": 0,
        "executableSHA256": "sha256 of resolved ~/.grok/bin/grok regular-file bytes",
    }


def emit(payload) -> None:
    print(json.dumps(payload, ensure_ascii=False, sort_keys=True, indent=2))


def official_grok_path() -> Path:
    return Path.home() / GROK_OFFICIAL_RELATIVE


def resolve_regular_executable(path: Path) -> Path | None:
    """Follow launcher symlinks to a regular file without canonicalizing /var.

    Path.resolve() on macOS rewrites /var to /private/var, which breaks
    O_NOFOLLOW callers that compare the path they designated. Only the
    leaf symlink is followed; directory symlink components stay as given.
    """
    try:
        candidate = Path(os.path.expanduser(str(path)))
        seen: set[str] = set()
        for _ in range(8):
            if not os.path.lexists(candidate):
                return None
            ident = str(candidate)
            if ident in seen:
                return None
            seen.add(ident)
            info = os.lstat(candidate)
            if stat.S_ISLNK(info.st_mode):
                target = Path(os.readlink(candidate))
                if not target.is_absolute():
                    target = candidate.parent / target
                candidate = target
                continue
            if stat.S_ISREG(info.st_mode):
                return Path(candidate)
            return None
        return None
    except OSError:
        return None


def discover_production_executable() -> Path | None:
    """Resolve only the fixed official pin (never an environment redirect)."""
    return resolve_regular_executable(official_grok_path())


def select_grok_executable(args, *, for_run: bool) -> Path:
    if args.executable:
        if os.environ.get("AGENT_CLI_ALLOW_TEST_EXECUTABLE") != "1":
            raise Refusal("executable_override_requires_test_switch")
        resolved = resolve_regular_executable(Path(args.executable).expanduser())
        if resolved is None:
            raise Refusal("executable_invalid")
        return resolved
    discovered = discover_production_executable()
    if discovered is None:
        raise Unsupported("grok_run_entry_missing" if for_run else "grok_plan_entry_missing")
    return discovered


def executable_digest(path: Path) -> str:
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def build_grok_argv(executable: Path, brief_path: Path, model: str) -> list[str]:
    """Managed argv for a Grok file task; plain array, shell=False."""
    if model not in GROK_MODELS:
        raise Refusal("model_not_authorized_for_grok")
    return [
        str(executable),
        "--model", model,
        "--prompt-file", str(brief_path),
        "--output-format", "streaming-json",
        "--tools", GROK_TOOLS,
        "--always-approve",
        "--no-subagents",
        "--disable-web-search",
    ]


def load_quota_evidence(path, now: float | None = None, executable=None,
                        expected_model: str = GROK_DEFAULT_MODEL) -> dict:
    """Validate official subscription evidence; return a desensitized view.

    Fixed reason codes only; file contents, local paths and account values are
    never echoed. Regular files only — a symlinked reference counts as invalid
    so a redirectable name can never stand in for the exported evidence.
    Caller JSON is accepted only through the explicit offline seam while the
    native bridge is unavailable. It is never treated as a live billing probe.
    """
    if expected_model not in GROK_MODELS:
        raise Refusal("grok_quota_evidence_model_mismatch")
    if not quota_bridge.available():
        raise Refusal("grok_quota_bridge_missing")
    now = time.time() if now is None else now
    target = Path(path)
    try:
        info = target.lstat()
    except OSError:
        raise Refusal("grok_quota_evidence_missing") from None
    if not stat.S_ISREG(info.st_mode) or info.st_size > GROK_QUOTA_EVIDENCE_MAX_BYTES:
        raise Refusal("grok_quota_evidence_invalid")
    try:
        raw = invocation.read_file(target, GROK_QUOTA_EVIDENCE_MAX_BYTES)
        payload = json.loads(raw.decode("utf-8"))
    except (OSError, ValueError, UnicodeError):
        raise Refusal("grok_quota_evidence_invalid") from None
    if not isinstance(payload, dict) or payload.get("schemaVersion") != 1 \
            or payload.get("product") != "grok":
        raise Refusal("grok_quota_evidence_invalid")
    if payload.get("kind") == "api-balance":
        raise Refusal("grok_quota_evidence_balance_not_subscription")
    if payload.get("kind") != "subscription-usage":
        raise Refusal("grok_quota_evidence_invalid")
    if payload.get("source") != GROK_EVIDENCE_SOURCE:
        raise Refusal("grok_quota_evidence_invalid")
    if payload.get("requestedModel") != expected_model \
            or payload.get("actualModel") != expected_model:
        raise Refusal("grok_quota_evidence_model_mismatch")
    environment_key = payload.get("environmentKey")
    if not isinstance(environment_key, str) or not activity.HASH.fullmatch(environment_key):
        raise Refusal("grok_quota_evidence_environment_mismatch")
    if payload.get("minimalReturnVerified") is not True:
        raise Refusal("grok_min_return_unverified")
    if payload.get("state") != "available":
        raise Refusal("grok_quota_evidence_invalid")
    if payload.get("quotaSource") != "creditUsagePercent":
        raise Refusal("grok_quota_evidence_invalid")
    on_demand_values = (payload.get("onDemandCap"), payload.get("onDemandUsed"))
    if any(isinstance(value, bool) or not isinstance(value, (int, float))
           or not math.isfinite(value) or value < 0 for value in on_demand_values):
        raise Refusal("grok_quota_evidence_invalid")
    if on_demand_values != (0, 0):
        raise Refusal("grok_quota_evidence_paid_fallback_possible")
    captured = payload.get("capturedAt")
    if isinstance(captured, bool) or not isinstance(captured, (int, float)) \
            or not math.isfinite(captured):
        raise Refusal("grok_quota_evidence_invalid")
    if captured > now + GROK_QUOTA_EVIDENCE_FUTURE_SLACK_SECONDS:
        raise Refusal("grok_quota_evidence_invalid")
    if now - captured > GROK_QUOTA_EVIDENCE_MAX_AGE_SECONDS:
        raise Refusal("grok_quota_evidence_stale")
    used = payload.get("creditUsagePercent")
    if isinstance(used, bool) or not isinstance(used, (int, float)) \
            or not math.isfinite(used) or not 0 <= used <= 100:
        raise Refusal("grok_quota_evidence_invalid")
    remaining = 100 - used
    if remaining <= 0:
        raise Refusal("grok_quota_evidence_exhausted")
    fingerprint = payload.get("accountFingerprint")
    if not isinstance(fingerprint, str) or not activity.HASH.fullmatch(fingerprint):
        raise Refusal("grok_quota_evidence_invalid")
    sha = payload.get("executableSHA256")
    if not isinstance(sha, str) or not activity.HASH.fullmatch(sha):
        raise Refusal("grok_quota_evidence_invalid")
    if executable is not None:
        try:
            actual = executable_digest(Path(executable))
        except OSError:
            raise Refusal("grok_quota_evidence_invalid") from None
        if actual != sha:
            raise Refusal("grok_executable_changed_since_evidence")
    return {
        # LocalCLIQuotaReader.identityFingerprint is already the shared
        # account hash. Re-hashing it would let native and Python leases for
        # one account coexist, defeating the common Registry lock.
        "accountKey": fingerprint,
        "capturedAgeSeconds": max(0, int(now - captured)),
        "remainingPercent": remaining,
        "source": GROK_EVIDENCE_SOURCE,
        "requestedModel": expected_model,
        "actualModel": expected_model,
        "environmentKey": environment_key,
        "minimalReturnVerified": True,
        "state": "available",
        "quotaSource": "creditUsagePercent",
        "onDemandCapIsZero": True,
        "executableSHA256": sha,
    }


def _read_brief(args) -> tuple[bytes, Path]:
    brief_path = Path(args.brief_file).expanduser()
    brief_bytes = invocation.read_file(brief_path, invocation.MAX_BRIEF_BYTES)
    try:
        text = brief_bytes.decode("utf-8")
    except UnicodeError:
        raise invocation.InvocationError("brief_is_empty_or_invalid") from None
    if not text.strip() or "\0" in text:
        raise invocation.InvocationError("brief_is_empty_or_invalid")
    return brief_bytes, brief_path


def _check_output_exclusive(args, registry) -> Path:
    output = support.secure_output_path(args.output, registry.root)
    for probe in (output, invocation.receipt_path(output),
                  output.with_name(output.name + ".next-resources")):
        if os.path.lexists(probe):
            raise invocation.InvocationError("output_already_exists_inspect_existing_run")
    return output


def _authorized_model(model) -> str:
    if not model:
        raise Refusal("grok_plan_requires_explicit_model")
    if model not in GROK_MODELS:
        raise Refusal("model_not_authorized_for_grok")
    return model


def plan(args, registry) -> int:
    """Reviewable Grok plan: validates inputs, prints the candidate, launches nothing."""
    executable = select_grok_executable(args, for_run=False)
    if not args.model:
        raise Refusal("grok_plan_requires_explicit_model")
    model = _authorized_model(args.model)
    if not args.cwd:
        raise Refusal("grok_plan_requires_cwd")
    if not (args.brief_file and args.output):
        raise Refusal("grok_plan_requires_brief_and_output")
    brief_bytes, brief_path = _read_brief(args)
    output = _check_output_exclusive(args, registry)
    support.validate_executable(executable)
    argv = support.validate_plain_argv(
        build_grok_argv(executable, Path(os.path.abspath(brief_path)), model))
    emit({
        "schemaVersion": 1, "product": "grok", "planOnly": True, "willNotLaunch": True,
        "model": model,
        "modelNote": "exact requested/runner model; no unverified 4.6-to-build remap",
        "executable": str(executable),
        "argv": argv,
        "briefBytes": len(brief_bytes),
        "briefSHA256": hashlib.sha256(brief_bytes).hexdigest(),
        "output": str(output),
        "outputExclusive": True,
        "stateDir": str(registry.root),
        "quotaGate": {"checked": False,
                      "note": "plan never reads or verifies subscription evidence; run refuses "
                              "without fresh positive official evidence bound to identity and "
                              "executableSHA256; balance never substitutes; this adapter is not "
                              "a live quota probe"},
        "runGates": ["--allow-run flag", "AGENT_CLI_ALLOW_RUN=1 environment",
                     "explicit model from the grok allowlist; no automatic fallback",
                     "explicit deadline via --timeout-seconds",
                     "fixed official ~/.grok/bin/grok (environment redirects are ignored)",
                     "native quota bridge: unavailable in this tree; test seam only for offline "
                     "fixtures; when available, evidence must be minutes-fresh, state=available, onDemandCapIsZero, "
                     "same-account fingerprint, executableSHA256 match; pre-launch recheck",
                     "any --executable override requires AGENT_CLI_ALLOW_TEST_EXECUTABLE=1"],
    })
    return EXIT_OK


def run(args, registry, *, _quota_loader=None) -> int:
    """Managed Grok run behind every existing protection and the quota gate.

    ``_quota_loader`` is an in-process unit-test seam for a trusted synthetic
    snapshot. The CLI never supplies it; production therefore always reaches
    ``load_quota_evidence`` and its closed native-bridge gate.
    """
    if not args.model:
        raise Refusal("grok_run_requires_explicit_model")
    model = args.model
    if model not in GROK_MODELS:
        raise Refusal("model_not_authorized_for_grok")
    if not args.cwd:
        raise Refusal("grok_run_requires_cwd")
    if args.timeout_seconds is None:
        raise Refusal("grok_run_requires_explicit_deadline")
    try:
        timeout = float(args.timeout_seconds)
    except (TypeError, ValueError):
        raise Refusal("grok_run_deadline_invalid") from None
    if not math.isfinite(timeout) or timeout <= 0:
        raise Refusal("grok_run_deadline_invalid")
    if not args.quota_evidence:
        raise Refusal("grok_quota_evidence_missing")
    executable = select_grok_executable(args, for_run=True)
    support.validate_executable(executable)
    quota_loader = _quota_loader or load_quota_evidence
    evidence = quota_loader(args.quota_evidence, executable=executable,
                            expected_model=model)
    brief_bytes, brief_path = _read_brief(args)
    output = _check_output_exclusive(args, registry)
    argv = support.validate_plain_argv(
        build_grok_argv(executable, Path(os.path.abspath(brief_path)), model))
    cwd = Path(args.cwd).expanduser().resolve()
    if not cwd.is_dir():
        raise activity.ActivityError("project_directory_missing")
    # Grok locks on its own account identity from the evidence file; never a
    # Codex A-H code or shared alias (code stays None for non-Codex accounts).
    # accountKey is exactly the shared Registry value emitted by Swift's
    # identityFingerprint; the raw identity is never recovered or stored.
    lease = registry.reserve(
        account_key=evidence["accountKey"], alias_key=activity.digest("grok"),
        code=None, project=activity.project_key(cwd), owner=args.owner,
        task=args.task_id, route="direct")
    try:
        rechecked = quota_loader(args.quota_evidence, executable=executable,
                                 expected_model=model)
        if rechecked["accountKey"] != evidence["accountKey"]:
            raise Refusal("grok_quota_evidence_identity_mismatch")
        if rechecked["executableSHA256"] != evidence["executableSHA256"]:
            raise Refusal("grok_executable_changed_since_evidence")
        if (rechecked["requestedModel"], rechecked["actualModel"]) != \
                (evidence["requestedModel"], evidence["actualModel"]):
            raise Refusal("grok_quota_evidence_model_mismatch")
        if rechecked["environmentKey"] != evidence["environmentKey"]:
            raise Refusal("grok_quota_evidence_environment_mismatch")
        output_identity = support.create_exclusive_output(output)
        result = support.run_workbuddy_task(
            registry, lease, argv=argv, cwd=cwd, brief_path=brief_path, output=output,
            timeout=timeout, capture_limit=support.MAX_CHILD_CAPTURE_BYTES,
            output_identity=output_identity)
    except BaseException:
        support.converge_reservation_after_failure(registry, lease, args.owner)
        raise
    lease_after = next((x for x in registry.read()["leases"] if x["leaseId"] == lease["leaseId"]), None)
    emit({"schemaVersion": 1, "run": result,
          "lease": support.lease_view(lease_after) if lease_after else None,
          "requestedModel": model, "observedModel": None, "observedCost": None,
          "quotaGate": {**evidence,
                        "note": "official subscription usage checked before reserve and again "
                                "immediately before launch; no live billing probe in this adapter; "
                                "balance never substitutes; no automatic retry or fallback"},
          "note": "exit 0 means the run was recorded truthfully; it is not acceptance, not a "
                  "verified model call and not a subscription claim"})
    return EXIT_OK


def _load_min_return_record(path: Path, now: float, *, expected_account_key: str | None,
                            expected_executable_sha: str | None,
                            expected_environment_key: str | None,
                            expected_model: str = GROK_DEFAULT_MODEL) -> dict:
    try:
        info = path.lstat()
    except OSError:
        raise Refusal("grok_min_return_missing") from None
    if not stat.S_ISREG(info.st_mode) or info.st_size > GROK_MIN_RETURN_MAX_BYTES:
        raise Refusal("grok_min_return_invalid")
    try:
        payload = json.loads(invocation.read_file(path, GROK_MIN_RETURN_MAX_BYTES).decode("utf-8"))
    except (OSError, ValueError, UnicodeError):
        raise Refusal("grok_min_return_invalid") from None
    if not isinstance(payload, dict) or payload.get("schemaVersion") != 1 \
            or payload.get("product") != "grok":
        raise Refusal("grok_min_return_invalid")
    requested = payload.get("requestedModel")
    actual = payload.get("actualModel")
    if requested != expected_model or actual != expected_model:
        raise Refusal("grok_min_return_model_mismatch")
    sha = payload.get("executableSHA256")
    if not isinstance(sha, str) or not activity.HASH.fullmatch(sha):
        raise Refusal("grok_min_return_hash_mismatch")
    version = payload.get("cliVersion")
    if not isinstance(version, str) or not version.strip():
        raise Refusal("grok_min_return_invalid")
    account_key = payload.get("accountKey")
    if not isinstance(account_key, str) or not activity.HASH.fullmatch(account_key):
        raise Refusal("grok_min_return_identity_mismatch")
    if expected_account_key is None or account_key != expected_account_key:
        raise Refusal("grok_min_return_identity_mismatch")
    if expected_executable_sha is None or sha != expected_executable_sha:
        raise Refusal("grok_min_return_hash_mismatch")
    environment_key = payload.get("environmentKey")
    if not isinstance(environment_key, str) or not activity.HASH.fullmatch(environment_key):
        raise Refusal("grok_min_return_environment_mismatch")
    if expected_environment_key is None or environment_key != expected_environment_key:
        raise Refusal("grok_min_return_environment_mismatch")
    if payload.get("isolatedEnvironment") is not True:
        raise Refusal("grok_min_return_isolation_mismatch")
    if payload.get("toolsDisabled") is not True:
        raise Refusal("grok_min_return_tools_mismatch")
    if payload.get("exitCode") != 0:
        raise Refusal("grok_min_return_nonzero_exit")
    if payload.get("outputMatched") is not True:
        raise Refusal("grok_min_return_output_mismatch")
    captured = payload.get("capturedAt")
    if isinstance(captured, bool) or not isinstance(captured, (int, float)) \
            or not math.isfinite(captured):
        raise Refusal("grok_min_return_invalid")
    if captured > now + GROK_QUOTA_EVIDENCE_FUTURE_SLACK_SECONDS:
        raise Refusal("grok_min_return_invalid")
    if now - captured > GROK_MIN_RETURN_MAX_AGE_SECONDS:
        raise Refusal("grok_min_return_stale")
    return {"requestedModel": requested, "actualModel": actual,
            "cliVersion": version.strip(), "accountKey": account_key,
            "executableSHA256": sha, "environmentKey": environment_key}


def minimal_verified_status(now: float | None = None, *, expected_account_key: str | None = None,
                            expected_executable_sha: str | None = None,
                            expected_environment_key: str | None = None) -> dict:
    """Per-model min-return. Receipt existence never flips this to true.

    Parent supplies a record for the exact runner model together with the
    expected account, executable, and environment keys from the same native
    execution context. Without an authenticated bridge or complete expected
    context this remains false; record existence or self-asserted fields are
    never enough. Test executable env does not feed this function.
    """
    now = time.time() if now is None else now
    if not quota_bridge.available():
        return {"value": False,
                "evidence": "grok quota bridge unavailable; minimal-return evidence is not trusted"}
    if (expected_account_key is None or expected_executable_sha is None
            or expected_environment_key is None):
        return {"value": False,
                "evidence": "minimal-return expected account, executable and environment context is missing; "
                            "receipt presence is not sufficient"}
    raw = os.environ.get(GROK_MIN_RETURN_DIR_ENV, "").strip()
    if not raw:
        return {"value": False,
                "evidence": "no per-model minimal-return evidence; receipt presence is not sufficient"}
    root = Path(raw)
    matched: list[str] = []
    for model in GROK_MODELS:
        record = root / (model + ".json")
        try:
            loaded = _load_min_return_record(
                record, now, expected_account_key=expected_account_key,
                expected_executable_sha=expected_executable_sha,
                expected_environment_key=expected_environment_key,
                expected_model=model)
        except Refusal as error:
            return {"value": False,
                    "evidence": "minimal-return not proven for " + model + " (" + str(error) + "); "
                                "receipt presence is not sufficient"}
        matched.append(model)
    return {"value": True,
            "evidence": "per-model minimal-return matched " + ",".join(matched) +
                        "; not a live subscription claim"}
