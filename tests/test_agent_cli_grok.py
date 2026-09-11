"""Offline Grok-entry tests: fake executables, in-process test seam, no network.

Proves the fixed production pin (~/.grok/bin/grok), explicit fake executable
seam, exact runner model reaching child argv, and the quota gate: minutes-fresh official
subscription evidence bound to same-account identity and executable SHA,
state=available, on-demand cap zero. Plan never launches. Run requires the
double switch. Production quota bridge absence is tested through the CLI;
downstream validation uses an in-process synthetic snapshot seam. Balance
never substitutes. A refused run never leaves a reservation. No real Grok
request is ever made.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"
sys.path.insert(0, str(SCRIPTS))
import next_dispatch_activity as activity  # noqa: E402
import agent_cli_grok as grok             # noqa: E402
import agent_cli_grok_bridge as grok_bridge  # noqa: E402
import agent_cli_support as support       # noqa: E402

AGENT_CLI = SCRIPTS / "agent-cli.py"
BOTH_SWITCHES = {"AGENT_CLI_ALLOW_RUN": "1", "AGENT_CLI_ALLOW_TEST_EXECUTABLE": "1"}
FINGERPRINT = "a" * 64


def run_cli(argv, env_extra=None, cwd=None):
    env = dict(os.environ)
    env.pop("AGENT_CLI_ALLOW_RUN", None)
    env.pop("AGENT_CLI_ALLOW_TEST_EXECUTABLE", None)
    env.pop("AGENT_CLI_GROK_EXECUTABLE", None)
    env.pop("AGENT_CLI_GROK_MIN_RETURN_DIR", None)
    if env_extra:
        env.update(env_extra)
    return subprocess.run([sys.executable, str(AGENT_CLI)] + argv, capture_output=True,
                          text=True, env=env, cwd=cwd, timeout=120)


def make_fake(directory: Path, name: str, body: str) -> Path:
    path = directory / name
    path.write_text(textwrap.dedent(body), encoding="utf-8")
    path.chmod(0o755)
    return path


def evidence_file(directory: Path, *, executable: Path, name="evidence.json", age=60,
                  remaining=42.5, kind=None, source=grok.GROK_EVIDENCE_SOURCE, raw=None,
                  state="available", on_demand_zero=True, sha=None,
                  fingerprint=FINGERPRINT) -> Path:
    path = directory / name
    if raw is not None:
        path.write_text(raw, encoding="utf-8")
        return path
    payload = {"schemaVersion": 1, "product": "grok", "kind": "subscription-usage",
               "source": source, "requestedModel": grok.GROK_DEFAULT_MODEL,
               "actualModel": grok.GROK_DEFAULT_MODEL,
               "environmentKey": "b" * 64, "minimalReturnVerified": True,
               "capturedAt": time.time() - age, "quotaSource": "creditUsagePercent",
               "creditUsagePercent": 100 - remaining,
               "accountFingerprint": fingerprint, "state": state,
               "onDemandCap": 0 if on_demand_zero else 1, "onDemandUsed": 0,
               "executableSHA256": sha if sha is not None else hashlib.sha256(
                   executable.read_bytes()).hexdigest()}
    if kind is not None:
        payload["kind"] = kind
    path.write_text(json.dumps(payload), encoding="utf-8")
    return path


class GrokEntryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="agent-cli-grok-test-")
        self.root = Path(self.temp.name)
        self.state = self.root / "state"
        self.work = self.root / "work"
        self.work.mkdir(parents=True)
        self.registry = activity.Registry(self.state)
        self.brief = self.work / "brief.md"
        self.brief.write_text("审查取消路径，保留空格与 \"引用\"", encoding="utf-8")
        self.fake = make_fake(self.work, "fake-grok.sh", '#!/bin/sh\nprintf \'%s\\n\' "$@"\n')
        self.evidence = evidence_file(self.work, executable=self.fake)

    def tearDown(self):
        self.temp.cleanup()

    def grok_plan(self, output="p.md", extra=None, drop=(), env_extra=None):
        argv = ["--state-dir", str(self.state), "plan", "--product", "grok",
                "--brief-file", str(self.brief), "--output", str(self.work / output),
                "--cwd", str(self.work), "--model", "grok-4.6-build",
                "--executable", str(self.fake)]
        argv = [x for x in argv if x not in drop]
        return run_cli(argv + (extra or []),
                       env_extra={**BOTH_SWITCHES, **(env_extra or {})})

    def grok_run(self, output="r.md", task="t-grok", owner="owner-grok", extra=None,
                 drop=(), executable=None, evidence=None):
        exe = executable or self.fake
        ev = evidence or self.evidence
        argv = ["--state-dir", str(self.state), "run", "--product", "grok",
                "--owner", owner, "--task-id", task,
                "--brief-file", str(self.brief), "--output", str(self.work / output),
                "--cwd", str(self.work), "--model", "grok-4.6-build",
                "--timeout-seconds", "30", "--quota-evidence", str(ev),
                "--executable", str(exe), "--allow-run"]
        argv = [x for x in argv if x not in drop]
        return run_cli(argv + (extra or []), env_extra=BOTH_SWITCHES)

    def assert_no_reservation(self, task):
        self.registry.read()
        leases = [x for x in activity.Registry(self.state).read()["leases"] if x["taskId"] == task]
        self.assertEqual(leases, [], "a refused run must not leave a reservation behind")

    def load_fixture(self, path, *, executable=None, now=None, expected_model=None):
        """Open the closed bridge only in this process for parser tests."""
        with mock.patch.object(grok_bridge, "PRODUCTION_READY", True):
            return grok.load_quota_evidence(
                path, now=time.time() if now is None else now,
                executable=executable or self.fake,
                expected_model=expected_model or grok.GROK_DEFAULT_MODEL)

    def assert_fixture_refusal(self, path, reason, *, executable=None):
        with mock.patch.object(grok_bridge, "PRODUCTION_READY", True):
            with self.assertRaises(support.Refusal) as refused:
                grok.load_quota_evidence(path, now=time.time(),
                                         executable=executable or self.fake)
        self.assertEqual(str(refused.exception), reason)

    # -- plan: the closed gap, still zero launch ------------------------------
    def test_plan_grok_candidate_is_reviewable_and_launches_nothing(self):
        done = self.grok_plan(output="plan out.md")
        self.assertEqual(done.returncode, 0, done.stderr)
        payload = json.loads(done.stdout)
        self.assertTrue(payload["planOnly"] and payload["willNotLaunch"])
        argv = payload["argv"]
        self.assertIsInstance(argv, list)
        self.assertTrue(all(isinstance(x, str) for x in argv))
        self.assertEqual(argv[0], str(self.fake))
        self.assertEqual(argv[argv.index("--model") + 1], "grok-4.6-build")
        for expected in ("--prompt-file", "--output-format", "streaming-json", "--tools",
                         grok.GROK_TOOLS, "--always-approve", "--no-subagents",
                         "--disable-web-search"):
            self.assertIn(expected, argv)
        self.assertFalse(os.path.lexists(self.work / "plan out.md"),
                         "plan must not create output files")
        self.assertFalse(payload["quotaGate"]["checked"],
                         "plan must never claim subscription verification")

    def test_build_grok_argv_passes_requested_model(self):
        for model in grok.GROK_MODELS:
            argv = grok.build_grok_argv(self.fake, self.brief, model)
            self.assertEqual(argv[0], str(self.fake))
            self.assertEqual(argv[argv.index("--model") + 1], model)

    def test_plan_grok_requires_explicit_model_and_cwd(self):
        done = self.grok_plan(drop=("--model", "grok-4.6-build"))
        self.assertEqual(done.returncode, 3, done.stderr)
        self.assertIn("grok_plan_requires_explicit_model", done.stderr)
        done = self.grok_plan(drop=("--cwd", str(self.work)))
        self.assertEqual(done.returncode, 3, done.stderr)
        self.assertIn("grok_plan_requires_cwd", done.stderr)

    def test_plan_grok_refuses_unauthorized_model(self):
        for model in ("grok-4.6", "grok-4.5", "grok-5-preview", "gpt-x", "hy3"):
            done = self.grok_plan(extra=["--model", model])
            self.assertEqual(done.returncode, 3, model)
            self.assertIn("model_not_authorized_for_grok", done.stderr)

    def test_plan_grok_refuses_existing_output(self):
        taken = self.work / "taken.md"
        taken.write_text("existing", encoding="utf-8")
        done = self.grok_plan(output="taken.md")
        self.assertEqual(done.returncode, 1)
        self.assertIn("output_already_exists_inspect_existing_run", done.stderr)

    def test_plan_grok_refuses_output_inside_state_dir(self):
        self.state.mkdir(parents=True, exist_ok=True)
        done = self.grok_plan(output=str(self.state / "out.md"))
        self.assertEqual(done.returncode, 3)
        self.assertIn("output_inside_activity_state_refused", done.stderr)

    # -- run: double switch and explicit parameters ---------------------------
    def test_run_grok_requires_double_switch(self):
        task = "t-doubleswitch"
        base = ["--state-dir", str(self.state), "run", "--product", "grok",
                "--owner", "owner-ds", "--task-id", task,
                "--brief-file", str(self.brief), "--output", str(self.work / "ds.md"),
                "--cwd", str(self.work), "--model", "grok-4.6-build",
                "--timeout-seconds", "30", "--quota-evidence", str(self.evidence),
                "--executable", str(self.fake)]
        done = run_cli(base)
        self.assertEqual(done.returncode, 4)
        self.assertIn("run_requires_explicit_double_switch", done.stderr)
        done = run_cli(base + ["--allow-run"])
        self.assertEqual(done.returncode, 4)
        self.assertIn("run_requires_explicit_double_switch", done.stderr)
        self.assert_no_reservation(task)

    def test_run_grok_requires_explicit_model_deadline_cwd(self):
        task = "t-explicit"
        done = self.grok_run(task=task, drop=("--model", "grok-4.6-build"))
        self.assertEqual(done.returncode, 3, done.stderr)
        self.assertIn("grok_run_requires_explicit_model", done.stderr)
        done = self.grok_run(task=task, drop=("--timeout-seconds", "30"))
        self.assertEqual(done.returncode, 3, done.stderr)
        self.assertIn("grok_run_requires_explicit_deadline", done.stderr)
        done = self.grok_run(task=task, drop=("--cwd", str(self.work)))
        self.assertEqual(done.returncode, 3, done.stderr)
        self.assertIn("grok_run_requires_cwd", done.stderr)
        done = self.grok_run(task=task, extra=["--timeout-seconds", "0"])
        self.assertEqual(done.returncode, 3, done.stderr)
        self.assertIn("grok_run_deadline_invalid", done.stderr)
        self.assert_no_reservation(task)

    def test_run_grok_refuses_executable_override_without_test_switch(self):
        task = "t-f13"
        base = ["--state-dir", str(self.state), "run", "--product", "grok",
                "--owner", "owner-f13", "--task-id", task,
                "--brief-file", str(self.brief), "--output", str(self.work / "f13.md"),
                "--cwd", str(self.work), "--model", "grok-4.6-build",
                "--timeout-seconds", "30", "--quota-evidence", str(self.evidence),
                "--executable", str(self.fake), "--allow-run"]
        done = run_cli(base, env_extra={"AGENT_CLI_ALLOW_RUN": "1"})
        self.assertEqual(done.returncode, 3, done.stderr)
        self.assertIn("executable_override_requires_test_switch", done.stderr)
        self.assert_no_reservation(task)

    # -- run: the quota evidence gate ----------------------------------------
    def test_run_grok_refuses_missing_evidence(self):
        task = "t-ev-missing"
        done = self.grok_run(task=task, drop=("--quota-evidence", str(self.evidence)))
        self.assertEqual(done.returncode, 3, done.stderr)
        self.assertIn("grok_quota_evidence_missing", done.stderr)
        self.assert_no_reservation(task)

    def test_run_grok_refuses_stale_evidence(self):
        stale = evidence_file(self.work, executable=self.fake, name="stale.json", age=3600)
        self.assert_fixture_refusal(stale, "grok_quota_evidence_stale")

    def test_run_grok_refuses_future_evidence(self):
        future = evidence_file(self.work, executable=self.fake, name="future.json", age=-1000)
        self.assert_fixture_refusal(future, "grok_quota_evidence_invalid")

    def test_run_grok_refuses_unbound_identity(self):
        bad = evidence_file(self.work, executable=self.fake, name="bad-id.json",
                            fingerprint="not-a-fingerprint")
        self.assert_fixture_refusal(bad, "grok_quota_evidence_invalid")

    def test_run_grok_refuses_exhausted_evidence(self):
        empty = evidence_file(self.work, executable=self.fake, name="empty.json", remaining=0)
        self.assert_fixture_refusal(empty, "grok_quota_evidence_exhausted")

    def test_run_grok_refuses_balance_as_evidence(self):
        balance = evidence_file(self.work, executable=self.fake, name="balance.json",
                                kind="api-balance")
        self.assert_fixture_refusal(balance, "grok_quota_evidence_balance_not_subscription")

    def test_run_grok_refuses_paid_fallback_and_wrong_model(self):
        paid = evidence_file(self.work, executable=self.fake, name="paid.json",
                             on_demand_zero=False)
        self.assert_fixture_refusal(paid, "grok_quota_evidence_paid_fallback_possible")
        wrong_model = evidence_file(self.work, executable=self.fake, name="wrong-model.json")
        payload = json.loads(wrong_model.read_text(encoding="utf-8"))
        payload["actualModel"] = "grok-4.6"
        wrong_model.write_text(json.dumps(payload), encoding="utf-8")
        self.assert_fixture_refusal(wrong_model, "grok_quota_evidence_model_mismatch")

    def test_run_grok_refuses_non_subscription_source_and_unverified_minimum(self):
        wrong_source = evidence_file(self.work, executable=self.fake, name="wrong-source.json")
        payload = json.loads(wrong_source.read_text(encoding="utf-8"))
        payload["quotaSource"] = "onDemandUsed"
        wrong_source.write_text(json.dumps(payload), encoding="utf-8")
        self.assert_fixture_refusal(wrong_source, "grok_quota_evidence_invalid")
        unverified = evidence_file(self.work, executable=self.fake, name="unverified.json")
        payload = json.loads(unverified.read_text(encoding="utf-8"))
        payload["minimalReturnVerified"] = False
        unverified.write_text(json.dumps(payload), encoding="utf-8")
        self.assert_fixture_refusal(unverified, "grok_min_return_unverified")

    def test_run_grok_refuses_wrong_environment_and_changed_executable(self):
        wrong_environment = evidence_file(self.work, executable=self.fake, name="wrong-env.json")
        payload = json.loads(wrong_environment.read_text(encoding="utf-8"))
        payload["environmentKey"] = "invalid"
        wrong_environment.write_text(json.dumps(payload), encoding="utf-8")
        self.assert_fixture_refusal(
            wrong_environment, "grok_quota_evidence_environment_mismatch")
        changed = evidence_file(
            self.work, executable=self.fake, name="changed-executable.json", sha="0" * 64)
        self.assert_fixture_refusal(changed, "grok_executable_changed_since_evidence")

    def test_run_grok_refuses_invalid_and_symlinked_evidence(self):
        broken = evidence_file(self.work, executable=self.fake, name="broken.json", raw="{not json")
        wrong = evidence_file(self.work, executable=self.fake, name="wrong.json",
                              raw=json.dumps({"schemaVersion": 2}))
        self.assert_fixture_refusal(broken, "grok_quota_evidence_invalid")
        self.assert_fixture_refusal(wrong, "grok_quota_evidence_invalid")
        link = self.work / "link.json"
        try:
            link.symlink_to(self.evidence)
        except (OSError, NotImplementedError):
            self.skipTest("symlink unsupported")
        self.assert_fixture_refusal(link, "grok_quota_evidence_invalid")

    def test_load_quota_evidence_reports_desensitized_view_only(self):
        loaded = self.load_fixture(self.evidence)
        self.assertEqual(loaded["remainingPercent"], 42.5)
        self.assertEqual(loaded["accountKey"], FINGERPRINT)
        self.assertEqual(loaded["requestedModel"], grok.GROK_DEFAULT_MODEL)
        self.assertEqual(loaded["actualModel"], grok.GROK_DEFAULT_MODEL)
        self.assertEqual(loaded["environmentKey"], "b" * 64)
        self.assertTrue(loaded["minimalReturnVerified"])
        self.assertTrue(activity.HASH.fullmatch(loaded["accountKey"]))

    # -- production stays closed; downstream lock logic is tested in-process --
    def test_handwritten_evidence_cannot_open_production_bridge(self):
        task = "t-bridge-missing"
        done = self.grok_run(task=task)
        self.assertEqual(done.returncode, 3, done.stderr)
        self.assertIn("grok_quota_bridge_missing", done.stderr)
        self.assert_no_reservation(task)

    def test_shared_registry_conflicts_on_exact_swift_fingerprint(self):
        other_project = self.work / "native-project"
        other_project.mkdir()
        self.registry.reserve(
            account_key=FINGERPRINT, alias_key=activity.digest("native-grok"),
            code=None, project=activity.project_key(other_project),
            owner="native-owner", task="native-task", route="terminal")
        args = argparse.Namespace(
            product="grok", owner="python-owner", task_id="python-task",
            brief_file=self.brief, output=self.work / "blocked.md", cwd=self.work,
            model=grok.GROK_DEFAULT_MODEL, timeout_seconds="30",
            quota_evidence=self.evidence, executable=self.fake, allow_run=True)
        with mock.patch.dict(os.environ, {"AGENT_CLI_ALLOW_TEST_EXECUTABLE": "1"}, clear=False):
            with self.assertRaises(activity.ActivityError) as refused:
                grok.run(args, self.registry, _quota_loader=self.load_fixture)
        self.assertEqual(str(refused.exception), "account_or_project_reserved")
        self.assert_no_reservation("python-task")

    def test_prelaunch_recheck_rejects_identity_change_without_launch(self):
        first = self.load_fixture(self.evidence)
        second = {**first, "accountKey": "d" * 64}
        loader = mock.Mock(side_effect=[first, second])
        args = argparse.Namespace(
            product="grok", owner="owner-recheck", task_id="t-recheck",
            brief_file=self.brief, output=self.work / "recheck.md", cwd=self.work,
            model=grok.GROK_DEFAULT_MODEL, timeout_seconds="30",
            quota_evidence=self.evidence, executable=self.fake, allow_run=True)
        with mock.patch.dict(os.environ, {"AGENT_CLI_ALLOW_TEST_EXECUTABLE": "1"}, clear=False):
            with self.assertRaises(support.Refusal) as refused:
                grok.run(args, self.registry, _quota_loader=loader)
        self.assertEqual(str(refused.exception), "grok_quota_evidence_identity_mismatch")
        self.assertEqual(loader.call_count, 2)
        lease = next(x for x in self.registry.read()["leases"] if x["taskId"] == "t-recheck")
        self.assertEqual(lease["state"], "failed")
        self.assertIsNone(lease.get("childPID"))

    def test_environment_redirect_never_changes_official_pin(self):
        missing = self.work / "missing-official"
        with mock.patch.object(grok, "official_grok_path", return_value=missing), \
                mock.patch.dict(os.environ, {"AGENT_CLI_GROK_EXECUTABLE": str(self.fake)}, clear=False):
            self.assertIsNone(grok.discover_production_executable())

    def test_catalog_keeps_grok_run_fail_closed(self):
        import agent_cli_capabilities as caps
        entry = caps.CATALOG["grok"]
        self.assertTrue(entry["plan"]["supported"])
        self.assertFalse(entry["run"]["supported"])
        self.assertEqual(entry["run"]["reason"], "grok_quota_bridge_missing")
        self.assertFalse(entry["quotaKnown"]["value"])


class MinimalReturnTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="grok-minret-")
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def record(self, model, **overrides):
        payload = {
            "schemaVersion": 1, "product": "grok",
            "requestedModel": model, "actualModel": model,
            "executableSHA256": "e" * 64, "cliVersion": "1.0.25",
            "accountKey": "f" * 64, "environmentKey": "a" * 64,
            "isolatedEnvironment": True,
            "toolsDisabled": True, "exitCode": 0, "outputMatched": True,
            "capturedAt": time.time() - 60,
        }
        payload.update(overrides)
        path = self.root / (model + ".json")
        path.write_text(json.dumps(payload), encoding="utf-8")
        return path

    def status(self):
        with mock.patch.object(grok_bridge, "PRODUCTION_READY", True), \
                mock.patch.dict(os.environ, {grok.GROK_MIN_RETURN_DIR_ENV: str(self.root)},
                                clear=False):
            return grok.minimal_verified_status(
                expected_account_key="f" * 64,
                expected_executable_sha="e" * 64,
                expected_environment_key="a" * 64)

    def test_missing_dir_is_not_verified(self):
        with mock.patch.object(grok_bridge, "PRODUCTION_READY", True), \
                mock.patch.dict(os.environ, {grok.GROK_MIN_RETURN_DIR_ENV: ""}, clear=False):
            status = grok.minimal_verified_status()
        self.assertFalse(status["value"])
        self.assertIn("receipt presence is not sufficient", status["evidence"])

    def test_all_models_matching_is_verified(self):
        for model in grok.GROK_MODELS:
            self.record(model)
        status = self.status()
        self.assertTrue(status["value"])

    def test_wrong_actual_model_is_not_verified(self):
        self.record(grok.GROK_DEFAULT_MODEL, actualModel="grok-4.6")
        status = self.status()
        self.assertFalse(status["value"])
        self.assertIn("grok_min_return_model_mismatch", status["evidence"])

    def test_wrong_hash_is_not_verified(self):
        self.record(grok.GROK_DEFAULT_MODEL, executableSHA256="nope")
        status = self.status()
        self.assertFalse(status["value"])
        self.assertIn("grok_min_return_hash_mismatch", status["evidence"])

    def test_wrong_identity_is_not_verified(self):
        self.record(grok.GROK_DEFAULT_MODEL, accountKey="short")
        status = self.status()
        self.assertFalse(status["value"])
        self.assertIn("grok_min_return_identity_mismatch", status["evidence"])

    def test_nonzero_exit_is_not_verified(self):
        self.record(grok.GROK_DEFAULT_MODEL, exitCode=2)
        status = self.status()
        self.assertFalse(status["value"])
        self.assertIn("grok_min_return_nonzero_exit", status["evidence"])

    def test_output_mismatch_is_not_verified(self):
        self.record(grok.GROK_DEFAULT_MODEL, outputMatched=False)
        status = self.status()
        self.assertFalse(status["value"])
        self.assertIn("grok_min_return_output_mismatch", status["evidence"])

    def test_stale_and_future_min_return_are_not_verified(self):
        self.record(grok.GROK_DEFAULT_MODEL, capturedAt=time.time() - 2 * 86400)
        status = self.status()
        self.assertFalse(status["value"])
        self.assertIn("grok_min_return_stale", status["evidence"])
        self.record(grok.GROK_DEFAULT_MODEL, capturedAt=time.time() + 1000)
        status = self.status()
        self.assertFalse(status["value"])
        self.assertIn("grok_min_return_invalid", status["evidence"])

    def test_wrong_environment_is_not_verified(self):
        self.record(grok.GROK_DEFAULT_MODEL, environmentKey="b" * 64)
        status = self.status()
        self.assertFalse(status["value"])
        self.assertIn("grok_min_return_environment_mismatch", status["evidence"])

    def test_receipt_file_existence_alone_does_not_verify(self):
        (self.root / "RECEIPT-grok.md").write_text("a receipt exists", encoding="utf-8")
        status = self.status()
        self.assertFalse(status["value"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
