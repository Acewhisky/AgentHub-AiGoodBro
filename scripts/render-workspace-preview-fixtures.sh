#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

TASK_BUILD_DIR="${1:-.local-artifacts/workspace-preview-build}"
TASK_OUTPUT_DIR="${2:-.local-artifacts/workspace-previews}"
LANGUAGE_FLAG="${3:-}"
RENDERER="Sources/CodexUsageWidget/Domain/WorkspacePreviewRenderer.swift"

if [[ "$LANGUAGE_FLAG" != "" && "$LANGUAGE_FLAG" != "--preview-english" ]]; then
    echo "usage: $0 [BUILD_DIR] [OUTPUT_DIR] [--preview-english]" >&2
    exit 2
fi

# Fail before compilation if this fixture entrypoint loses its synthetic-data
# markers or grows a direct real-environment discovery/read call.
rg -q 'example\.invalid' "$RENDERER"
if rg -n 'homeDirectoryForCurrentUser|LocalCLIAccountStore\(\)|UsageStore\(\)|\.discover\(\)|Keychain|NSWorkspace\.shared' "$RENDERER"; then
    echo "workspace preview isolation check failed" >&2
    exit 1
fi

make build BUILD_DIR="$TASK_BUILD_DIR" SWIFT_OPTIMIZATION=-Onone
mkdir -p "$TASK_OUTPUT_DIR"

BIN="$TASK_BUILD_DIR/AiGoodBro.app/Contents/MacOS/AiGoodBro"
[[ -x "$BIN" ]] || { echo "missing fixture renderer: $BIN" >&2; exit 1; }

if [[ -n "$LANGUAGE_FLAG" ]]; then
    "$BIN" --render-workspace-previews "$TASK_OUTPUT_DIR" "$LANGUAGE_FLAG"
else
    "$BIN" --render-workspace-previews "$TASK_OUTPUT_DIR"
fi

find "$TASK_OUTPUT_DIR" -maxdepth 1 -type f -name 'acceptance-*.png' -print | sort
