#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)}"
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
BUILD_DIR="${BUILD_DIR:-build}"
DIST_DIR="${DIST_DIR:-dist}"

if [[ "$VERSION" != "$PLIST_VERSION" ]]; then
  echo "Requested version $VERSION does not match Info.plist version $PLIST_VERSION" >&2
  exit 1
fi

make memory-risk-check BUILD_DIR="$BUILD_DIR"
python3 tests/test_health_boundaries.py
plutil -lint Resources/Info.plist
git diff --check

make test-macos-compatibility
make test
CAMNEXT_SKIP_BUILD=1 ./scripts/test-parsers.sh

make release-all BUILD_DIR="$BUILD_DIR" DIST_DIR="$DIST_DIR" BUNDLE_COMPANION=1

verify_asset() {
  local arch="$1"
  local expected_arch="$2"
  local dmg="$DIST_DIR/AiGoodBro-${VERSION}-mac-${arch}.dmg"
  local checksum="${dmg}.sha256"
  local mount_dir

  [[ -f "$dmg" ]] || { echo "Missing release asset: $dmg" >&2; exit 1; }
  [[ -f "$checksum" ]] || { echo "Missing checksum: $checksum" >&2; exit 1; }
  shasum -a 256 -c "$checksum"
  hdiutil verify "$dmg" >/dev/null

  mount_dir="$(mktemp -d)"
  hdiutil attach -nobrowse -readonly -mountpoint "$mount_dir" "$dmg" >/dev/null
  file "$mount_dir/AiGoodBro.app/Contents/MacOS/AiGoodBro" | grep -q "$expected_arch"
  codesign --verify --deep --strict "$mount_dir/AiGoodBro.app"
  local resources="$mount_dir/AiGoodBro.app/Contents/Resources"
  local hub="$resources/CompanionHub/agent-remote-control"
  [[ -x "$hub" ]] || { echo "Missing bundled Companion Hub" >&2; exit 1; }
  file "$hub" | grep -q "$expected_arch"
  codesign --verify --strict "$hub"
  cmp scripts/next_runtime_setup.py "$resources/SupportTools/next_runtime_setup.py"
  python3 - "$resources" "$arch" <<'PY'
import hashlib, json, pathlib, sys
resources, expected_arch = pathlib.Path(sys.argv[1]), sys.argv[2]
manifest = json.loads((resources / 'CompanionHub/manifest.json').read_text())
hub = resources / 'CompanionHub/agent-remote-control'
assert manifest == {
    'schemaVersion': 1,
    'architecture': expected_arch,
    'version': '0910v2-next',
    'executable': 'agent-remote-control',
    'sha256': hashlib.sha256(hub.read_bytes()).hexdigest(),
    'sourceManifestSHA256': hashlib.sha256(pathlib.Path('Companion/Hub/SOURCE.json').read_bytes()).hexdigest(),
}
for forbidden in ('runtime-paths.json', 'runtime-python.txt'):
    assert not list(resources.rglob(forbidden)), forbidden
for forbidden in ('__pycache__', '.pytest_cache', 'node_modules'):
    assert not list(resources.rglob(forbidden)), forbidden
for forbidden in ('python', 'python3', 'codex'):
    assert not list(resources.rglob(forbidden)), forbidden
PY
  while IFS= read -r relative; do
    cmp ".agents/skills/multi-agent-management/$relative" "$resources/CompanionSkill/$relative"
  done < <(python3 - <<'PY'
import runpy
print('\n'.join(runpy.run_path('scripts/prepare-companion-resources.py')['SKILL_FILES']))
PY
)
  for relative in SKILL.md 使用说明.md config/dispatch-codes-v1.json config/dispatch-policy-v1.json references/coordination.md references/dispatch-brief.md references/local-runtime.md scripts/next_dispatch_activity.py scripts/next_dispatch_preflight.py; do
    cmp ".agents/skills/multi-agent-management/$relative" "$mount_dir/Companion Skill/multi-agent-management/$relative"
  done
  hdiutil detach "$mount_dir" >/dev/null
  rmdir "$mount_dir"
}

verify_asset arm64 arm64
verify_asset x86_64 x86_64

echo "Release artifacts verified for AiGoodBro $VERSION"
cat "$DIST_DIR/AiGoodBro-${VERSION}-mac-arm64.dmg.sha256"
cat "$DIST_DIR/AiGoodBro-${VERSION}-mac-x86_64.dmg.sha256"
