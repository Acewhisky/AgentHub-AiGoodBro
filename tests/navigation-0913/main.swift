import Foundation
import CoreGraphics

// Catalog fixture only; no account storage, providers, or credentials.
enum LocalCLIKind: String, CaseIterable {
    case alpha, beta
    var displayName: String { rawValue }
}
var count = 0
func check(_ value: @autoclosure () -> Bool, _ label: String) {
    precondition(value(), label)
    count += 1
}
let original = ["codex", "unknown", "alpha", "beta"]
var draft = DirectReorderTransaction(original: original, visible: ["codex", "alpha"], source: "alpha", knownIDs: ["codex", "alpha"])!
draft.step(-1)
check(draft.committed(current: original) == ["alpha", "unknown", "codex", "beta"], "hidden and overflow slots stay fixed")
check(draft.committed(current: []) == nil, "concurrent edit rejected")
check(original == ["codex", "unknown", "alpha", "beta"], "draft/cancel does not mutate original")
check(DirectReorderTransaction(original: original, visible: ["unknown"], source: "unknown", knownIDs: ["codex"]) == nil, "unknown rejected")
check(DirectReorderTransaction(original: original, visible: ["codex"], source: "home", knownIDs: ["codex"]) == nil, "home rejected")
draft.move(before: nil)
check(draft.committed(current: original) == original, "move to last and undo")
draft.move(before: "forged")
check(draft.committed(current: original) == original, "invalid target ignored")
draft.step(1)
check(draft.committed(current: original) == original, "boundary unchanged")
for ids in ["[]", "[\"future-agent\",\"codex\"]"] {
    var backup: Data?
    var state = AgentNavigationState.load(Data("{\"orderedVisibleProviderIDs\":\(ids)}".utf8), backupRaw: &backup)
    let saved = state.orderedVisibleProviderIDs
    state.bootstrapIfNeeded(existingUser: true, currentVisible: ["alpha"])
    check(state.orderedVisibleProviderIDs == saved, "migration preserves explicit selection")
    check(AgentNavigationState.load(state.encoded(), backupRaw: &backup) == state, "roundtrip")
}
let centered = AvatarCropGeometry.rect(image: CGSize(width: 400, height: 200), scale: 2, offset: .zero)
check(centered == CGRect(x: 150, y: 50, width: 100, height: 100), "zoom stays centered")
let edge = AvatarCropGeometry.rect(image: CGSize(width: 400, height: 200), scale: 2, offset: CGSize(width: 999, height: 999))
check(edge == CGRect(x: 0, y: 100, width: 100, height: 100), "clamped to image bounds and flipped y")
check(AvatarCropGeometry.rect(image: CGSize(width: 160, height: 160), scale: 1, offset: CGSize(width: 90, height: -90)) == CGRect(x: 0, y: 0, width: 160, height: 160), "no blank edges")
print("Passed \(count) pure navigation/crop fixture checks")
