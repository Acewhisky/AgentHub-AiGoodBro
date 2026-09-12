#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
tmp=$(mktemp -d /tmp/navigation-fixtures.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
flags=(-swift-version 5 -module-cache-path "$tmp/cache")
swiftc "${flags[@]}" Sources/CodexUsageWidget/Domain/{DirectReorderTransaction,AvatarCropGeometry,AgentNavigationPreferences}.swift tests/navigation-0913/main.swift -o "$tmp/fixtures"
"$tmp/fixtures"
swiftc -typecheck "${flags[@]}" -target arm64-apple-macos13.0 Sources/CodexUsageWidget/Domain/{DirectReorderTransaction,AgentNavigationPreferences}.swift Sources/CodexUsageWidget/UI/{DirectReorderGrip,AgentNavigationBar}.swift tests/navigation-0913/NavigationTypecheckFixtures.swift
swiftc -typecheck "${flags[@]}" -target arm64-apple-macos13.0 Sources/CodexUsageWidget/Domain/{AvatarCropGeometry,AccountAvatarPreference}.swift Sources/CodexUsageWidget/UI/AccountAvatarEditor.swift tests/navigation-0913/AvatarTypecheckFixtures.swift
swiftc -frontend -parse -swift-version 5 Sources/CodexUsageWidget/UI/{AgentNavigationBar,DirectReorderGrip,AccountAvatarEditor,MessageChannelsSettingsView,SettingsPanelView}.swift
