# Upgrade safety · 0911v6 (Grok isolated review)

In-place macOS replace now targets `AiGoodBro.app`. The idle guard still matches a live `CodexAccountManagerNext` executable so an old bundle is not overwritten while running. Accounts and settings outside the bundle stay on the original isolation names. This note covers the idle-guard and install rollback seams, plus the later dual-name install wiring. It is not a whole-repository review.

Timestamps in this note are not independently verified. Tests were written here and were **not executed** in this worktree (no shell). Parent validation is required.

## What was reviewed

| Surface | Role |
| --- | --- |
| `scripts/check-build-target-idle.py` | Idle guard used by `make build` and `make install` |
| `Makefile` `build` / `install` (read-only) | Staging, codesign, rename, copy, restore |
| `tests/test_install_upgrade_guard.py` | Pure helpers + tempfile fixture processes |
| `UPGRADE-INPUTS-0911v6.json` | Input hashes; stale if the idle script changed |

Accounts, Keychain, browser, desktop, `/Applications/CodexAccountManagerNext.app`, and the daily running app were not inspected. `make install` / `make run` were not invoked.

Stores that must stay in place (from `docs/brand-compat-0911v1.md`):

- User-visible package and executable: `AiGoodBro.app` / `AiGoodBro`
- Legacy package name, for idle-check and one-way migration only: `CodexAccountManagerNext.app`
- Profiles: `~/.codex-account-manager-next/profiles/`
- Application Support / Cache / defaults / Keychain names unchanged

Replacing the launchable bundle while keeping those store names is what preserves accounts. Leaving both `AiGoodBro.app` and `CodexAccountManagerNext.app` launchable, or following a symlink into a second copy, would not.

## Seam findings

### 1. Running target or alias path

**Proved defect (idle script, fixed here).** The ZCode candidate listed `ps -ww -axo pid=,comm=` and skipped every command that did not start with `/`. Darwin `comm` is the truncated command name, not the executable path, so a live target at `/Applications/CodexAccountManagerNext.app/Contents/MacOS/CodexAccountManagerNext` was dropped and the guard returned 0 (fail-open). `rm -rf` / `mv` of that bundle could then proceed while the process still held the vnode.

The script now:

- reads `pid=,command=` so argv0 can be a path
- matches resolved absolute paths
- matches device+inode when both files exist (POSIX symlink / hard link)
- lists holders of an existing file with `lsof -t` and fail-closes if that listing cannot be verified

**Makefile defect (not edited).** `[ -d /Applications/$(APP_NAME).app ]` is true for a symlink-to-directory. `mv` then moves the link, `cp -R` creates a real directory at the canonical path, and the original bundle is left in place — a second copy. Finder aliases are files, so `-d` is false and `-e` on the inner executable is false; the idle check is skipped.

### 2. Process identity ambiguity

**Proved defect (idle script, fixed here).** Basename-only or relative argv0 with the same final name cannot be proved to be, or not to be, the target. The old `startswith("/")` filter treated that as idle. The guard now returns status 1 with an ambiguous-identity message.

A second copy of the same basename at a different absolute path remains unrelated, so `make build BUILD_DIR=...` is not blocked merely because the daily app is running, as long as that app's argv0 is an absolute path (normal for `open` / LaunchServices).

### 3. Missing / invalid target

**Idle script.** A missing file with no matching argv0 is idle (status 0). A missing file whose absolute argv0 still appears in the process table is busy (deleted-but-running). A path that exists and is not a regular file is status 2.

**Makefile defect (not edited).** Idle check runs only `if [ -e .../MacOS/$(APP_NAME) ]`. A present `.app` directory without that executable skips the guard, then is renamed aside and replaced. `install: build` usually stages a signed bundle, but `make install -o build` or a broken `APP_DIR` is not rejected in the install recipe itself.

### 4. Failed staging / codesign

**Makefile defect (not edited).** `codesign` and `codesign --verify --deep --strict` run only on `$(APP_DIR)` during `build`. `install` then `mv`s the live app aside **before** `cp -R`. A failed copy therefore happens after the canonical path is already empty. There is no post-copy signature check. A successful `cp` immediately `rm -rf`s `.previous`.

### 5. Restore-after-rename failure

**Makefile defect (not edited).** On copy failure the recipe `rm -rf`s the dest, then `mv`s `.previous` back **without checking `mv`**, and always prints `install: copy failed; the previous installation was restored.` That sentence is false when there was no previous install, when `mv` fails, or when `rm -rf` of a partial dest fails and blocks the restore.

## Changes in this worktree

- `scripts/check-build-target-idle.py` — fail-closed identity helpers (see above).
- `tests/test_install_upgrade_guard.py` — characterization of the current recipe, model of the proposed recipe, and idle-guard unit tests.
- This document and `TASK-REPORT.md`.
- Makefile was **not** modified. Apply the patch below in the parent if accepted.
- `UPGRADE-INPUTS-0911v6.json` still hashes the pre-fix idle script. Parent must recompute after accepting the script change. Hashes were not calculated here.

## Proposed Makefile patch (parent only)

Replace the `install` recipe only. Do not run this from the isolated reviewer. `open` is retained as current product behavior after a successful replace; this reviewer must not execute it.

```diff
--- a/Makefile
+++ b/Makefile
@@ -186,23 +186,62 @@ phase-one-soak: build
    ./scripts/phase-one-soak.sh

 install: build
-	@if [ -e "/Applications/$(APP_NAME).app/Contents/MacOS/$(APP_NAME)" ]; then \
-		python3 scripts/check-build-target-idle.py "/Applications/$(APP_NAME).app/Contents/MacOS/$(APP_NAME)"; \
-	fi
-	@if [ -d "/Applications/$(APP_NAME).app" ]; then \
-		rm -rf "/Applications/$(APP_NAME).app.previous"; \
-		mv "/Applications/$(APP_NAME).app" "/Applications/$(APP_NAME).app.previous"; \
-	fi
-	@if cp -R "$(APP_DIR)" "/Applications/$(APP_NAME).app"; then \
-		rm -rf "/Applications/$(APP_NAME).app.previous"; \
-	else \
-		rm -rf "/Applications/$(APP_NAME).app"; \
-		if [ -d "/Applications/$(APP_NAME).app.previous" ]; then \
-			mv "/Applications/$(APP_NAME).app.previous" "/Applications/$(APP_NAME).app"; \
-		fi; \
-		echo "install: copy failed; the previous installation was restored." >&2; \
-		exit 1; \
-	fi
+	@if [ ! -d "$(APP_DIR)" ] || [ ! -x "$(MACOS_DIR)/$(APP_NAME)" ]; then \
+		echo "install: staged app bundle is missing or invalid." >&2; \
+		exit 1; \
+	fi
+	@codesign --verify --deep --strict "$(APP_DIR)"
+	@dest="/Applications/$(APP_NAME).app"; \
+	prev="$$dest.previous"; \
+	staging="$$dest.staging"; \
+	if [ -e "$$dest" ] && { [ -L "$$dest" ] || [ ! -d "$$dest" ]; }; then \
+		echo "install: $$dest exists but is not a real app directory; refusing to replace." >&2; \
+		exit 1; \
+	fi; \
+	if [ -d "$$dest" ] && [ ! -e "$$dest/Contents/MacOS/$(APP_NAME)" ]; then \
+		echo "install: existing app is missing its executable; refusing to replace without an idle check." >&2; \
+		exit 1; \
+	fi; \
+	if [ -e "$$dest/Contents/MacOS/$(APP_NAME)" ]; then \
+		python3 scripts/check-build-target-idle.py "$$dest/Contents/MacOS/$(APP_NAME)"; \
+	fi; \
+	rm -rf "$$staging"; \
+	if ! cp -R "$(APP_DIR)" "$$staging"; then \
+		rm -rf "$$staging"; \
+		echo "install: staging copy failed; the live app was left untouched." >&2; \
+		exit 1; \
+	fi; \
+	if ! codesign --verify --deep --strict "$$staging"; then \
+		rm -rf "$$staging"; \
+		echo "install: staged copy failed codesign verification; the live app was left untouched." >&2; \
+		exit 1; \
+	fi; \
+	if [ -d "$$dest" ]; then \
+		rm -rf "$$prev"; \
+		if ! mv "$$dest" "$$prev"; then \
+			rm -rf "$$staging"; \
+			echo "install: could not move the live app aside; it was left in place." >&2; \
+			exit 1; \
+		fi; \
+	fi; \
+	if ! mv "$$staging" "$$dest"; then \
+		rm -rf "$$dest" "$$staging"; \
+		if [ -d "$$prev" ]; then \
+			if mv "$$prev" "$$dest"; then \
+				echo "install: promote failed; the previous installation was restored." >&2; \
+			else \
+				echo "install: promote failed and the previous installation could not be restored at $$dest (left at $$prev)." >&2; \
+			fi; \
+		else \
+			echo "install: promote failed; there was no previous installation to restore." >&2; \
+		fi; \
+		exit 1; \
+	fi; \
+	rm -rf "$$prev"
    open "/Applications/$(APP_NAME).app"
```

The Python model of this recipe is `ProposedInstallRecipe` in `tests/test_install_upgrade_guard.py`.

## Tests

Parent command (this reviewer did not run it):

```sh
python3 -m unittest tests.test_install_upgrade_guard -v
```

Optional after accepting the script change (parent computes hashes; this reviewer cannot):

```sh
python3 -c "import hashlib, pathlib; p=pathlib.Path('scripts/check-build-target-idle.py'); print(hashlib.sha256(p.read_bytes()).hexdigest())"
```

Do not run `make install`, `make run`, or any command against the daily app as part of this validation.

## Remaining limits

- Finder aliases are not POSIX symlinks; neither the guard nor `[ -L ]` follows them.
- argv0 with spaces is split on the first space (`command=` is not quoted).
- Helper/XPC processes that do not hold the main executable and do not share its argv0 are not treated as the target.
- Fail-closed basename ambiguity will also refuse `make build` while an unrelated same-basename process has a relative argv0.
- `lsof -t` holders include readers of the file, not only `txt` mappings; that is conservative.
- Settings preservation is a path-identity property of the bundle id and support directories; this review did not read those directories.
- Leftover `.previous` is still removed immediately before rotating a live dest. A prior failed restore that left the only good copy at `.previous` while dest is also present remains a residual risk.
- `install` still launches the replaced app with `open`.
