#!/usr/bin/env python3
"""Upgrade-guard and rollback tests for in-place macOS replace.

Uses tempfile fake bundles and injected process tables only. Does not inspect
real accounts, credentials, config, Keychain, browser, desktop, or the daily
app. Does not install, launch, or replace /Applications/AiGoodBro.app or
/Applications/CodexAccountManagerNext.app.
Does not call host `ps` / `lsof` / `codesign`.
"""

from __future__ import annotations

import importlib.util
import os
import shutil
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "check_build_target_idle",
    ROOT / "scripts/check-build-target-idle.py",
)
assert SPEC is not None and SPEC.loader is not None
idle = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = idle
SPEC.loader.exec_module(idle)

MAKEFILE = (ROOT / "Makefile").read_text()
APP_NAME = "AiGoodBro"
LEGACY_APP_NAME = "CodexAccountManagerNext"
INSTALL_BLOCK = MAKEFILE.split("install: build", 1)[1].split("\ndmg:", 1)[0]


def _write_executable(path: Path, body: str = "#!/bin/sh\nexit 0\n") -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)
    return path


def _bundle_executable(root: Path, name: str = APP_NAME) -> Path:
    return _write_executable(root / f"{name}.app" / "Contents" / "MacOS" / name)


class InstallRecipe:
    """Model of Makefile `install` unique-staging swap. Never touches /Applications."""

    def __init__(self, applications: Path, app_dir: Path):
        self.applications = applications
        self.app_dir = app_dir
        self.dest = applications / f"{APP_NAME}.app"
        self.legacy = applications / f"{LEGACY_APP_NAME}.app"
        self.prev = applications / f"{APP_NAME}.app.previous"
        self.staging: Path | None = None

    def run(
        self,
        copy_ok: bool = True,
        codesign_ok: bool = True,
        idle_ok: bool = True,
        aside_ok: bool = True,
        promote_ok: bool = True,
        restore_mv_ok: bool = True,
    ) -> tuple[int, str]:
        staged_exe = self.app_dir / "Contents" / "MacOS" / APP_NAME
        if not self.app_dir.is_dir() or not staged_exe.is_file():
            return 1, "install: staged app bundle is missing or invalid."
        if self.dest.exists() and (self.dest.is_symlink() or not self.dest.is_dir()):
            return 1, (
                f"install: {self.dest} exists but is not a real app directory; "
                "refusing to replace."
            )
        if self.prev.exists() and self.dest.exists():
            return 1, f"install: leftover {self.prev} exists; refusing to replace."
        if self.prev.exists() and (self.prev.is_symlink() or not self.prev.is_dir()):
            return 1, (
                f"install: leftover {self.prev} exists but is not a real app "
                "directory; refusing to replace."
            )

        staging = Path(
            tempfile.mkdtemp(prefix=f"{APP_NAME}.app.staging.", dir=self.applications)
        )
        self.staging = staging
        if not copy_ok:
            shutil.rmtree(staging)
            return 1, "install: staging copy failed; the live app was left untouched."
        shutil.rmtree(staging)
        shutil.copytree(self.app_dir, staging, symlinks=True)
        if not codesign_ok:
            shutil.rmtree(staging)
            return 1, (
                "install: staged copy failed codesign verification; "
                "the live app was left untouched."
            )
        if self.dest.is_dir() and self.legacy.is_dir():
            shutil.rmtree(staging)
            return 1, "install: both apps exist; keep one launchable copy before replacing."
        live = self.dest if self.dest.is_dir() else (self.legacy if self.legacy.is_dir() else None)
        dest_exe = None if live is None else next(
            (
                live / "Contents" / "MacOS" / name
                for name in (APP_NAME, LEGACY_APP_NAME)
                if (live / "Contents" / "MacOS" / name).is_file()
            ),
            None,
        )
        if live is not None and dest_exe is None:
            shutil.rmtree(staging)
            return 1, (
                "install: existing app is missing its executable; "
                "refusing to replace without an idle check."
            )
        if dest_exe is not None and dest_exe.is_file() and not idle_ok:
            shutil.rmtree(staging)
            return 1, "install: the target app is running."
        if live is not None:
            if not aside_ok:
                shutil.rmtree(staging)
                return 1, "install: could not move the live app aside; it was left in place."
            live.rename(self.prev)
        if not promote_ok:
            shutil.rmtree(staging)
            if self.prev.is_dir():
                if restore_mv_ok:
                    self.prev.rename(self.dest)
                    if self.dest.is_dir() and not self.dest.is_symlink():
                        return 1, "install: promote failed; the previous installation was restored."
                return (
                    1,
                    "install: promote failed and the previous installation could not be restored "
                    f"at {self.dest} (left at {self.prev}).",
                )
            return 1, "install: promote failed; there was no previous installation to restore."
        staging.rename(self.dest)
        if not self.dest.is_dir() or self.dest.is_symlink():
            return 1, (
                f"install: promote reported success but {self.dest} is not a real app directory."
            )
        if self.prev.exists():
            shutil.rmtree(self.prev)
        return 0, ""


class ProcessTableParseTests(unittest.TestCase):
    def test_keeps_absolute_comm_with_spaces_and_does_not_split_argv0(self):
        spaced = "/tmp/My App.app/Contents/MacOS/AiGoodBro"
        table = (
            "  12 /sbin/launchd\n"
            f" 401 {spaced}\n"
            "not-a-row\n"
            "   7\n"
        )
        rows = idle.parse_process_table(table)
        self.assertEqual(
            [(row.pid, row.executable) for row in rows],
            [
                (12, "/sbin/launchd"),
                (401, spaced),
            ],
        )
        self.assertNotEqual(rows[1].executable, "/tmp/My")

    def test_keeps_basename_only_rows_for_ambiguity_classification(self):
        rows = idle.parse_process_table(
            "  403 AiGoodBro\n  404 ./AiGoodBro\n"
        )
        self.assertEqual(rows[0].executable, "AiGoodBro")
        self.assertEqual(rows[1].executable, "./AiGoodBro")

    def test_process_table_source_is_comm_not_command(self):
        self.assertEqual(idle.PS_ARGV, ("/bin/ps", "-ww", "-axo", "pid=,comm="))
        self.assertNotIn("command=", "".join(idle.PS_ARGV))


class ImageIdentityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="camnext-idle-id-")
        self.root = Path(self.temp.name).resolve()
        self.addCleanup(self.temp.cleanup)
        self.target = _bundle_executable(self.root / "real")
        self.resolved = self.target.resolve()
        self.identity = idle.file_identity(self.target)

    def test_absolute_path_match_and_posix_symlink_alias(self):
        alias_root = self.root / "alias-space"
        alias_root.mkdir()
        alias = alias_root / "AiGoodBro.app"
        os.symlink(self.target.parents[2], alias)
        alias_exe = alias / "Contents" / "MacOS" / APP_NAME
        self.assertEqual(
            idle.classify_image(str(alias_exe), self.resolved, self.identity),
            "match",
        )
        self.assertEqual(
            idle.classify_image(str(self.target), self.resolved, self.identity),
            "match",
        )

    def test_same_inode_via_hardlink_is_a_match(self):
        linked = self.root / "hardlinked-exe"
        os.link(self.target, linked)
        self.assertEqual(
            idle.classify_image(str(linked), self.resolved, self.identity),
            "match",
        )

    def test_same_basename_at_a_different_absolute_path_is_unrelated(self):
        other = _bundle_executable(self.root / "other-copy")
        self.assertEqual(
            idle.classify_image(str(other), self.resolved, self.identity),
            "unrelated",
        )

    def test_similar_name_unrelated_process_is_not_the_target(self):
        helper = _bundle_executable(self.root / "helper", name=f"{APP_NAME}Helper")
        nearby = _write_executable(self.root / f"{APP_NAME}-old")
        self.assertEqual(
            idle.classify_image(str(helper), self.resolved, self.identity),
            "unrelated",
        )
        self.assertEqual(
            idle.classify_image(str(nearby), self.resolved, self.identity),
            "unrelated",
        )
        self.assertEqual(
            idle.classify_image(f"{APP_NAME}Helper", self.resolved, self.identity),
            "unrelated",
        )

    def test_basename_or_relative_comm_with_the_same_name_is_ambiguous(self):
        self.assertEqual(
            idle.classify_image(APP_NAME, self.resolved, self.identity),
            "ambiguous",
        )
        self.assertEqual(
            idle.classify_image(f"./{APP_NAME}", self.resolved, self.identity),
            "ambiguous",
        )

    def test_unrelated_basename_is_not_ambiguous(self):
        self.assertEqual(
            idle.classify_image("sleep", self.resolved, self.identity),
            "unrelated",
        )

    def test_spaced_absolute_comm_matches_spaced_target(self):
        spaced_root = self.root / "My App"
        target = _bundle_executable(spaced_root)
        resolved = target.resolve()
        identity = idle.file_identity(target)
        self.assertEqual(idle.classify_image(str(target), resolved, identity), "match")
        truncated = str(target).split(" ", 1)[0]
        self.assertEqual(
            idle.classify_image(truncated, resolved, identity),
            "unrelated",
        )


class GuardDecisionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="camnext-idle-guard-")
        self.root = Path(self.temp.name).resolve()
        self.addCleanup(self.temp.cleanup)
        self.target = _bundle_executable(self.root)

    def test_running_absolute_comm_is_busy(self):
        rows = idle.parse_process_table(f"  401 {self.target}\n")
        decision = idle.evaluate_guard(self.target, rows)
        self.assertEqual(decision.status, 1)
        self.assertEqual(decision.matching_pids, (401,))
        self.assertEqual(decision.message, idle.RUNNING_MESSAGE)

    def test_running_spaced_absolute_comm_is_busy(self):
        target = _bundle_executable(self.root / "Install Path")
        rows = idle.parse_process_table(f"  402 {target}\n")
        decision = idle.evaluate_guard(target, rows)
        self.assertEqual(decision.status, 1)
        self.assertEqual(decision.matching_pids, (402,))
        truncated_rows = idle.parse_process_table(f"  402 {str(target).split(' ', 1)[0]}\n")
        truncated = idle.evaluate_guard(target, truncated_rows)
        self.assertEqual(truncated.status, 0)

    def test_similar_name_process_does_not_block_idle_target(self):
        helper = _bundle_executable(self.root / "helper", name=f"{APP_NAME}Helper")
        other = _bundle_executable(self.root / "someone-else")
        rows = idle.parse_process_table(
            f"  12 /sbin/launchd\n  88 {helper}\n  89 {other}\n"
        )
        decision = idle.evaluate_guard(self.target, rows)
        self.assertEqual(decision.status, 0)
        self.assertEqual(decision.message, "")

    def test_basename_only_ps_row_is_not_idle(self):
        rows = idle.parse_process_table(f"  403 {APP_NAME}\n")
        decision = idle.evaluate_guard(self.target, rows)
        self.assertEqual(decision.status, 1)
        self.assertEqual(decision.ambiguous_pids, (403,))
        self.assertEqual(decision.message, idle.AMBIGUOUS_MESSAGE)

    def test_missing_target_with_no_holders_is_idle(self):
        missing = self.root / "gone.app" / "Contents" / "MacOS" / APP_NAME
        decision = idle.evaluate_guard(missing, [])
        self.assertEqual(decision.status, 0)
        self.assertEqual(decision.message, "")

    def test_missing_target_still_matches_absolute_comm(self):
        missing = self.root / "gone.app" / "Contents" / "MacOS" / APP_NAME
        rows = idle.parse_process_table(f"  404 {missing}\n")
        decision = idle.evaluate_guard(missing, rows)
        self.assertEqual(decision.status, 1)
        self.assertEqual(decision.matching_pids, (404,))

    def test_directory_target_is_invalid(self):
        directory = self.root / "not-an-exe"
        directory.mkdir()
        decision = idle.evaluate_guard(directory, [])
        self.assertEqual(decision.status, 2)
        self.assertEqual(decision.message, idle.INVALID_TARGET_MESSAGE)

    def test_idle_when_process_table_is_clear(self):
        other = _bundle_executable(self.root / "someone-else", name="OtherApp")
        rows = idle.parse_process_table(f"  12 /sbin/launchd\n  88 {other}\n")
        decision = idle.evaluate_guard(self.target, rows)
        self.assertEqual(decision.status, 0)


class MainGuardTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="camnext-idle-main-")
        self.root = Path(self.temp.name).resolve()
        self.addCleanup(self.temp.cleanup)
        self.target = _bundle_executable(self.root)

    def test_usage_and_invalid_target(self):
        self.assertEqual(idle.main([]), 2)
        self.assertEqual(idle.main([str(self.target), "extra"]), 2)
        self.assertEqual(idle.main(["-n"]), 2)
        self.assertEqual(idle.main([str(self.root)]), 2)

    def test_ps_failure_is_fail_closed(self):
        with patch.object(idle, "read_process_table", side_effect=OSError("ps")):
            self.assertEqual(idle.main([str(self.target)]), 1)

    def test_main_refuses_running_resolved_alias(self):
        alias = self.root / "alias.app"
        os.symlink(self.target.parents[2], alias)
        alias_exe = alias / "Contents" / "MacOS" / APP_NAME
        table = f"  501 {self.target}\n"
        with patch.object(idle, "read_process_table", return_value=table):
            self.assertEqual(idle.main([str(alias_exe)]), 1)

    def test_main_rejects_active_target(self):
        table = f"  601 {self.target}\n"
        with patch.object(idle, "read_process_table", return_value=table):
            self.assertEqual(idle.main([str(self.target)]), 1)

    def test_main_idle_on_clear_fixture_file(self):
        with patch.object(idle, "read_process_table", return_value="  1 /sbin/launchd\n"):
            self.assertEqual(idle.main([str(self.target)]), 0)


class MakefileRecipeTextTests(unittest.TestCase):
    def test_build_and_install_invoke_the_idle_guard(self):
        self.assertIn("python3 scripts/check-build-target-idle.py", MAKEFILE)
        self.assertIn('"$(MACOS_DIR)/$(APP_NAME)"', MAKEFILE)
        self.assertIn('$$live/Contents/MacOS/$(APP_NAME)', INSTALL_BLOCK)
        self.assertIn("$(LEGACY_APP_NAME)", INSTALL_BLOCK)
        self.assertIn("keep one launchable copy before replacing", INSTALL_BLOCK)
        self.assertIn('$$bundle/Contents/MacOS/$$exe', INSTALL_BLOCK)

    def test_install_stages_to_unique_temp_then_verifies_and_swaps(self):
        self.assertIn("/usr/bin/mktemp -d", INSTALL_BLOCK)
        self.assertIn('cp -R "$(APP_DIR)/." "$$staging"', INSTALL_BLOCK)
        self.assertIn('codesign --verify --deep --strict "$$staging"', INSTALL_BLOCK)
        self.assertIn('codesign --verify --deep --strict "$(APP_DIR)"', INSTALL_BLOCK)
        self.assertIn('[ -L "$$dest" ]', INSTALL_BLOCK)
        self.assertIn("left untouched", INSTALL_BLOCK)
        self.assertIn("could not be restored", INSTALL_BLOCK)
        self.assertIn("the previous installation was restored.", INSTALL_BLOCK)
        self.assertIn('mv "$$live" "$$prev"', INSTALL_BLOCK)
        self.assertIn('mv "$$staging" "$$dest"', INSTALL_BLOCK)
        self.assertIn('mv "$$prev" "$$restore"', INSTALL_BLOCK)

    def test_install_does_not_rm_the_live_app_or_claim_restore_unconditionally(self):
        self.assertNotIn('rm -rf "/Applications/$(APP_NAME).app"', INSTALL_BLOCK)
        self.assertNotIn('rm -rf "$$dest"', INSTALL_BLOCK)
        self.assertNotIn(
            'echo "install: copy failed; the previous installation was restored." >&2;',
            INSTALL_BLOCK,
        )
        self.assertIn(
            'if mv "$$prev" "$$restore" && [ -d "$$restore" ] && [ ! -L "$$restore" ]; then',
            INSTALL_BLOCK,
        )


class InstallRollbackModelTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="camnext-install-model-")
        self.root = Path(self.temp.name).resolve()
        self.addCleanup(self.temp.cleanup)
        self.applications = self.root / "Applications"
        self.applications.mkdir()
        self.staged = self.root / "build" / f"{APP_NAME}.app"
        _bundle_executable(self.root / "build", name=APP_NAME)
        (self.staged / "Contents" / "marker").write_text("new")
        live = self.applications / f"{APP_NAME}.app"
        _bundle_executable(self.applications, name=APP_NAME)
        (live / "Contents" / "marker").write_text("old")
        self.recipe = InstallRecipe(self.applications, self.staged)

    def test_staging_copy_failure_leaves_live_app(self):
        status, message = self.recipe.run(copy_ok=False)
        self.assertEqual(status, 1)
        self.assertIn("left untouched", message)
        self.assertEqual((self.recipe.dest / "Contents" / "marker").read_text(), "old")
        self.assertTrue(self.recipe.dest.is_dir())
        self.assertFalse(self.recipe.dest.is_symlink())

    def test_failed_codesign_leaves_live_app(self):
        status, message = self.recipe.run(codesign_ok=False)
        self.assertEqual(status, 1)
        self.assertIn("codesign", message)
        self.assertIn("left untouched", message)
        self.assertEqual((self.recipe.dest / "Contents" / "marker").read_text(), "old")

    def test_active_target_leaves_live_app(self):
        status, message = self.recipe.run(idle_ok=False)
        self.assertEqual(status, 1)
        self.assertIn("running", message)
        self.assertEqual((self.recipe.dest / "Contents" / "marker").read_text(), "old")

    def test_missing_staged_bundle_is_invalid(self):
        shutil.rmtree(self.staged)
        status, message = self.recipe.run()
        self.assertEqual(status, 1)
        self.assertIn("missing or invalid", message)
        self.assertEqual((self.recipe.dest / "Contents" / "marker").read_text(), "old")

    def test_symlink_destination_is_refused(self):
        shutil.rmtree(self.recipe.dest)
        real = self.root / "real-install" / f"{APP_NAME}.app"
        _bundle_executable(self.root / "real-install", name=APP_NAME)
        (real / "Contents" / "marker").write_text("linked-old")
        os.symlink(real, self.recipe.dest)
        status, message = self.recipe.run()
        self.assertEqual(status, 1)
        self.assertIn("not a real app directory", message)
        self.assertTrue(self.recipe.dest.is_symlink())
        self.assertTrue(real.is_dir())
        self.assertEqual((real / "Contents" / "marker").read_text(), "linked-old")

    def test_leftover_previous_with_live_dest_is_refused(self):
        leftover = self.recipe.prev
        leftover.mkdir()
        (leftover / "keep").write_text("backup")
        status, message = self.recipe.run()
        self.assertEqual(status, 1)
        self.assertIn("leftover", message)
        self.assertEqual((self.recipe.dest / "Contents" / "marker").read_text(), "old")
        self.assertEqual((leftover / "keep").read_text(), "backup")

    def test_promote_failure_reports_honest_restore_miss(self):
        status, message = self.recipe.run(promote_ok=False, restore_mv_ok=False)
        self.assertEqual(status, 1)
        self.assertIn("could not be restored", message)
        self.assertNotIn("the previous installation was restored.", message)
        self.assertFalse(self.recipe.dest.exists())
        self.assertTrue(self.recipe.prev.exists())
        self.assertEqual((self.recipe.prev / "Contents" / "marker").read_text(), "old")

    def test_promote_failure_reports_restore_only_when_dest_is_back(self):
        status, message = self.recipe.run(promote_ok=False, restore_mv_ok=True)
        self.assertEqual(status, 1)
        self.assertIn("the previous installation was restored.", message)
        self.assertEqual((self.recipe.dest / "Contents" / "marker").read_text(), "old")
        self.assertFalse(self.recipe.prev.exists())

    def test_successful_promote_replaces_and_drops_previous(self):
        status, message = self.recipe.run()
        self.assertEqual(status, 0)
        self.assertEqual(message, "")
        self.assertEqual((self.recipe.dest / "Contents" / "marker").read_text(), "new")
        self.assertFalse(self.recipe.prev.exists())
        self.assertFalse(self.recipe.dest.is_symlink())


class DualNameInstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="camnext-dual-name-")
        self.root = Path(self.temp.name).resolve()
        self.addCleanup(self.temp.cleanup)
        self.applications = self.root / "Applications"
        self.applications.mkdir()
        self.staged = self.root / "build" / f"{APP_NAME}.app"
        _bundle_executable(self.root / "build", name=APP_NAME)
        (self.staged / "Contents" / "marker").write_text("new")

    def test_migrates_legacy_bundle_name_to_aigoodbro(self):
        legacy = self.applications / f"{LEGACY_APP_NAME}.app"
        _bundle_executable(self.applications, name=LEGACY_APP_NAME)
        (legacy / "Contents" / "marker").write_text("old-legacy")
        recipe = InstallRecipe(self.applications, self.staged)
        status, message = recipe.run()
        self.assertEqual(status, 0)
        self.assertEqual(message, "")
        self.assertTrue((recipe.dest / "Contents" / "MacOS" / APP_NAME).is_file())
        self.assertEqual((recipe.dest / "Contents" / "marker").read_text(), "new")
        self.assertFalse(recipe.legacy.exists())
        self.assertFalse(recipe.prev.exists())

    def test_refuses_when_both_launchable_names_exist(self):
        _bundle_executable(self.applications, name=APP_NAME)
        _bundle_executable(self.applications, name=LEGACY_APP_NAME)
        (self.applications / f"{APP_NAME}.app" / "Contents" / "marker").write_text("new-name")
        (self.applications / f"{LEGACY_APP_NAME}.app" / "Contents" / "marker").write_text("old-name")
        recipe = InstallRecipe(self.applications, self.staged)
        status, message = recipe.run()
        self.assertEqual(status, 1)
        self.assertIn("keep one launchable copy", message)
        self.assertEqual(
            (recipe.dest / "Contents" / "marker").read_text(),
            "new-name",
        )
        self.assertEqual(
            (recipe.legacy / "Contents" / "marker").read_text(),
            "old-name",
        )

    def test_running_legacy_bundle_is_left_in_place(self):
        legacy = self.applications / f"{LEGACY_APP_NAME}.app"
        _bundle_executable(self.applications, name=LEGACY_APP_NAME)
        (legacy / "Contents" / "marker").write_text("running-legacy")
        recipe = InstallRecipe(self.applications, self.staged)
        status, message = recipe.run(idle_ok=False)
        self.assertEqual(status, 1)
        self.assertIn("running", message)
        self.assertEqual((legacy / "Contents" / "marker").read_text(), "running-legacy")
        self.assertFalse(recipe.dest.exists())


if __name__ == "__main__":
    unittest.main()
