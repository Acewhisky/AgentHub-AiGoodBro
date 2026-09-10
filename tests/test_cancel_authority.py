"""Cancel-authority regressions: the recorded cancel intent is never overwritten.

Offline only: temp state dirs, short pseudo-processes (sleep/exit), no network,
no real accounts, no real task cancellation, no files written by children.
Determinism comes from supervise hooks (before_start / on_started) and a
process_birth hook that lands the cancel inside the Popen-to-metadata window;
no wall-clock racing is required. A launched child is always provable from the
registry itself (childPID plus terminal state), so no marker files are needed.

Against the pre-fix implementation these tests fail because any later
starting/running/awaiting_acceptance write silently replaced cancel_requested,
and a supervise claim failure left no journal and inconsistent state.
"""
import json
import os
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import next_dispatch_activity as activity  # noqa: E402

SLEEP_CHILD = [sys.executable, "-c", "import time; time.sleep(0.3)"]
FAIL_CHILD = [sys.executable, "-c", "import sys; sys.exit(3)"]


class CancelAuthorityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cancel-authority-test-")
        self.root = Path(self.temp.name)
        self.registry = activity.Registry(self.root / "state")
        self.work = self.root / "work"
        self.work.mkdir()
        self.addCleanup(self.temp.cleanup)

    def reserve(self, owner="owner-one", task="task-one"):
        return self.registry.reserve(account_key=activity.digest("account-a"),
                                     alias_key=activity.digest("fixture-a"), code="A",
                                     project=activity.project_key(self.work), owner=owner,
                                     task=task, route="direct")

    def lease(self, lease_id):
        return next(x for x in self.registry.read()["leases"] if x["leaseId"] == lease_id)

    def journal_issue_ids(self):
        path = self.registry.root / activity.ISSUE_NAME
        if not path.exists():
            return []
        return [json.loads(line)["issueId"] for line in path.read_text().splitlines()]

    # -- registry level: the state machine itself ----------------------------

    def test_cancel_requested_rejects_active_phase_overwrites(self):
        lease = self.reserve()
        self.registry.update(lease["leaseId"], "owner-one", "cancel_requested")
        for phase in ("preparing", "starting", "running", "awaiting_acceptance", "uncertain"):
            with self.subTest(phase=phase):
                with self.assertRaisesRegex(activity.ActivityError, "cancel_intent_is_authoritative"):
                    self.registry.update(lease["leaseId"], "owner-one", phase)
        self.assertEqual(self.lease(lease["leaseId"])["state"], "cancel_requested")

    def test_double_cancel_is_idempotent_and_finishes_cancelled(self):
        lease = self.reserve()
        self.registry.update(lease["leaseId"], "owner-one", "cancel_requested")
        again = self.registry.update(lease["leaseId"], "owner-one", "cancel_requested")
        self.assertEqual(again["state"], "cancel_requested")
        finished = self.registry.update(lease["leaseId"], "owner-one", "cancelled")
        self.assertEqual(finished["state"], "cancelled")

    def test_cancelled_is_final_against_acceptance_decisions(self):
        lease = self.reserve()
        self.registry.update(lease["leaseId"], "owner-one", "cancel_requested")
        self.registry.update(lease["leaseId"], "owner-one", "cancelled")
        for phase in ("accepted", "rejected", "running", "cancel_requested"):
            with self.subTest(phase=phase):
                with self.assertRaisesRegex(activity.ActivityError, "reservation_already_finished"):
                    self.registry.update(lease["leaseId"], "owner-one", phase)

    def test_wrong_owner_cannot_cancel_or_resolve(self):
        lease = self.reserve()
        with self.assertRaisesRegex(activity.ActivityError, "reservation_owner_mismatch"):
            self.registry.update(lease["leaseId"], "owner-two", "cancel_requested")
        self.registry.update(lease["leaseId"], "owner-one", "cancel_requested")
        with self.assertRaisesRegex(activity.ActivityError, "reservation_owner_mismatch"):
            self.registry.update(lease["leaseId"], "owner-two", "cancelled")
        self.assertEqual(self.lease(lease["leaseId"])["state"], "cancel_requested")

    def test_heartbeat_refreshes_cancel_requested_without_overwrite(self):
        lease = self.reserve()
        self.registry.update(lease["leaseId"], "owner-one", "cancel_requested")
        before = self.lease(lease["leaseId"])
        time.sleep(0.01)
        self.registry.update(lease["leaseId"], "owner-one")
        after = self.lease(lease["leaseId"])
        self.assertEqual(after["state"], "cancel_requested")
        self.assertGreater(after["heartbeatDueAt"], before["heartbeatDueAt"])

    def test_cancelled_release_requires_dead_process_evidence(self):
        lease = self.reserve()
        self.registry.update(lease["leaseId"], "owner-one", None, processGroupID=424242)
        self.registry.update(lease["leaseId"], "owner-one", "cancel_requested")
        with patch.object(activity, "group_has_live_process", return_value=True):
            with self.assertRaisesRegex(activity.ActivityError, "process_group_still_running"):
                self.registry.update(lease["leaseId"], "owner-one", "cancelled")
        self.assertEqual(self.lease(lease["leaseId"])["state"], "cancel_requested")
        with patch.object(activity, "group_has_live_process", return_value=False):
            self.registry.update(lease["leaseId"], "owner-one", "cancelled", exitCode=143)
        saved = self.lease(lease["leaseId"])
        self.assertEqual(saved["state"], "cancelled")
        self.assertEqual(saved["exitCode"], 143)

    def test_concurrent_running_writes_never_overwrite_cancel_intent(self):
        lease = self.reserve()
        self.registry.update(lease["leaseId"], "owner-one", "starting")
        start = threading.Barrier(2)
        errors = []

        def canceller():
            start.wait()
            self.registry.update(lease["leaseId"], "owner-one", "cancel_requested")

        def runner():
            start.wait()
            for _ in range(50):
                try:
                    self.registry.update(lease["leaseId"], "owner-one", "running")
                except activity.ActivityError as error:
                    if str(error) != "cancel_intent_is_authoritative":
                        errors.append(str(error))
                    return
                time.sleep(0.001)

        threads = [threading.Thread(target=canceller), threading.Thread(target=runner)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(10)
        self.assertEqual(errors, [])
        self.assertIn(self.lease(lease["leaseId"])["state"], {"cancel_requested", "cancelled"})

    # -- supervise sequences --------------------------------------------------

    def test_cancel_before_claim_starts_no_child(self):
        lease = self.reserve()
        self.registry.update(lease["leaseId"], "owner-one", "cancel_requested")
        with self.assertRaisesRegex(activity.ActivityError, "cancel_intent_is_authoritative"):
            activity.supervise(self.registry, lease, SLEEP_CHILD, self.work)
        saved = self.lease(lease["leaseId"])
        self.assertEqual(saved["state"], "cancel_requested")
        self.assertNotIn("childPID", saved, "a cancelled lease must never launch a child")

    def test_cancel_after_claim_before_child_record_starts_no_child(self):
        lease = self.reserve()

        def cancel_in_before_start():
            self.registry.update(lease["leaseId"], "owner-one", "cancel_requested")

        with self.assertRaisesRegex(activity.ActivityError, "cancel_intent_is_authoritative"):
            activity.supervise(self.registry, lease, SLEEP_CHILD, self.work,
                               before_start=cancel_in_before_start)
        saved = self.lease(lease["leaseId"])
        self.assertEqual(saved["state"], "cancel_requested")
        self.assertNotIn("childPID", saved, "cancel won before launch; no child may appear")
        self.assertIn("cli-launch-or-supervisor-failed", self.journal_issue_ids())

    def test_cancel_between_popen_and_metadata_keeps_pid_evidence_and_converges(self):
        lease = self.reserve()
        real_birth = activity.process_birth
        calls = {"count": 0}

        def birth_with_cancel(pid):
            calls["count"] += 1
            if calls["count"] == 2:  # first call is the runner claim, second the child lookup
                self.registry.update(lease["leaseId"], "owner-one", "cancel_requested")
            return real_birth(pid)

        with patch.object(activity, "process_birth", side_effect=birth_with_cancel):
            result = activity.supervise(self.registry, lease, SLEEP_CHILD, self.work)
        self.assertEqual(result, 0)
        saved = self.lease(lease["leaseId"])
        self.assertEqual(saved["state"], "cancelled",
                         "cancel landed before the running write; exit 0 must not resurrect it")
        self.assertEqual(saved["exitCode"], 0)
        self.assertIn("childPID", saved, "pid evidence is kept even though the phase was refused")

    def test_late_exit_zero_after_cancel_stays_cancelled(self):
        lease = self.reserve()

        def cancel_on_started():
            self.registry.update(lease["leaseId"], "owner-one", "cancel_requested")

        result = activity.supervise(self.registry, lease, SLEEP_CHILD, self.work,
                                    on_started=cancel_on_started)
        self.assertEqual(result, 0)
        saved = self.lease(lease["leaseId"])
        self.assertEqual(saved["state"], "cancelled")
        self.assertEqual(saved["exitCode"], 0, "the real exit code is kept as evidence")

    def test_cancel_then_nonzero_exit_records_both_truths(self):
        lease = self.reserve()

        def cancel_on_started():
            self.registry.update(lease["leaseId"], "owner-one", "cancel_requested")

        result = activity.supervise(self.registry, lease, FAIL_CHILD, self.work,
                                    on_started=cancel_on_started)
        self.assertEqual(result, 3)
        saved = self.lease(lease["leaseId"])
        self.assertEqual(saved["state"], "cancelled")
        self.assertEqual(saved["exitCode"], 3)

    def test_normal_success_path_is_unchanged(self):
        lease = self.reserve()
        result = activity.supervise(self.registry, lease, SLEEP_CHILD, self.work)
        self.assertEqual(result, 0)
        saved = self.lease(lease["leaseId"])
        self.assertEqual(saved["state"], "awaiting_acceptance")
        self.assertEqual(saved["exitCode"], 0)

    def test_claim_failure_journals_and_preserves_state(self):
        lease = self.reserve()
        self.registry.update(lease["leaseId"], "owner-one", "starting", claim=True,
                             runnerPID=os.getpid(),
                             runnerPIDBirth=activity.process_birth(os.getpid()))
        with self.assertRaisesRegex(activity.ActivityError, "reservation_already_claimed"):
            activity.supervise(self.registry, lease, SLEEP_CHILD, self.work)
        saved = self.lease(lease["leaseId"])
        self.assertEqual(saved["state"], "starting",
                         "a failed claim must not rewrite another runner's active lease")
        self.assertIn("cli-launch-or-supervisor-failed", self.journal_issue_ids())

    def test_surviving_descendants_keep_cancel_requested_occupied(self):
        lease = self.reserve()
        self.registry.update(lease["leaseId"], "owner-one", None, processGroupID=424242)
        self.registry.update(lease["leaseId"], "owner-one", "cancel_requested")
        with patch.object(activity, "group_has_live_process", return_value=True):
            with self.assertRaisesRegex(activity.ActivityError, "process_group_still_running"):
                self.registry.update(lease["leaseId"], "owner-one", "cancelled")
        self.assertIn(self.lease(lease["leaseId"])["state"], activity.ACTIVE)


if __name__ == "__main__":
    unittest.main(verbosity=2)
