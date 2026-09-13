import Foundation

/// Production navigation session and real item-provider serialization; no UI,
/// preferences, accounts or installed application are opened by this fixture.
@main
struct NavigationManagementTests {
    @MainActor
    static func main() async {
        var count = 0
        func check(_ result: @autoclosure () -> Bool, _ label: String) {
            precondition(result(), label)
            count += 1
        }
        var saved = AgentNavigationState()
        saved.initialized = true
        saved.customized = true
        saved.orderedVisibleProviderIDs = ["codex", "future-agent", "alpha"]
        var session = AgentNavigationManagementSession(saved)
        check(session.draft == saved, "opening management does not alter settings")
        check(session.committed(current: saved) == saved, "unchanged Done preserves all fields")
        check(session.beginDragging("home") == nil, "Home is not draggable")
        check(session.beginDragging("future-agent") == nil, "unknown IDs are not draggable")
        check(session.beginDragging("missing") == nil, "missing IDs are not draggable")

        let firstToken = session.beginDragging("alpha")!
        check(session.isDragging, "whole-row drag creates active transaction")
        check(!firstToken.contains("alpha"), "pasteboard token carries no provider identity")
        check(!session.drop(token: "external", targetID: "codex", after: false), "external token rejected")
        check(session.draft == saved, "external drop leaves order unchanged")
        check(!session.drop(token: firstToken, targetID: "future-agent", after: false), "hidden unknown target rejected")
        check(session.drop(token: firstToken, targetID: "codex", after: false), "upward drop accepted")
        check(session.draft.orderedVisibleProviderIDs == ["alpha", "future-agent", "codex"], "upward drop preserves hidden slot")
        check(!session.isDragging, "successful drop invalidates token")
        check(!session.drop(token: firstToken, targetID: "codex", after: true), "replayed drop rejected")
        check(saved.orderedVisibleProviderIDs == ["codex", "future-agent", "alpha"], "drag only changes draft")
        check(session.committed(current: saved)?.orderedVisibleProviderIDs == ["alpha", "future-agent", "codex"], "Done returns reordered state")

        let downToken = session.beginDragging("alpha")!
        check(session.drop(token: downToken, targetID: "codex", after: true), "downward drop after last accepted")
        check(session.draft == saved, "downward drop restores original order")
        let selfToken = session.beginDragging("alpha")!
        check(session.drop(token: selfToken, targetID: "alpha", after: true), "self drop succeeds without movement")
        check(session.draft == saved, "self drop does not shift adjacent rows")

        session.move("alpha", by: -1)
        check(session.draft.orderedVisibleProviderIDs == ["alpha", "future-agent", "codex"], "accessibility move uses same hidden-slot transaction")
        session.move("alpha", by: -1)
        check(session.draft.orderedVisibleProviderIDs == ["alpha", "future-agent", "codex"], "accessibility move clamps at boundary")
        session.move("alpha", by: 1)
        check(session.draft == saved, "accessibility move down restores order")

        let removedToken = session.beginDragging("alpha")!
        session.remove("alpha")
        check(!session.isDragging, "removal invalidates pending drop")
        check(!session.drop(token: removedToken, targetID: "codex", after: false), "drop for removed row rejected")
        check(session.draft.orderedVisibleProviderIDs == ["codex", "future-agent"], "removal preserves unrelated hidden entry")
        check(saved.orderedVisibleProviderIDs.count == 3, "removal does not write saved state")
        let beforeResetToken = session.beginDragging("codex")!
        session.restoreDefault(currentVisible: ["alpha", "codex", "alpha"])
        check(session.draft.orderedVisibleProviderIDs == ["alpha", "codex"], "restore defaults stays in draft and deduplicates")
        check(!session.drop(token: beforeResetToken, targetID: "alpha", after: true), "restore defaults invalidates pending drop")

        var concurrent = saved
        _ = concurrent.remove("codex")
        check(session.committed(current: concurrent) == nil, "concurrent order change rejects Done")
        concurrent = saved
        concurrent.customized = false
        check(session.committed(current: concurrent) == nil, "concurrent metadata change rejects Done")

        var canceled = AgentNavigationManagementSession(saved)
        let canceledToken = canceled.beginDragging("alpha")!
        _ = canceled.drop(token: canceledToken, targetID: "codex", after: false)
        canceled = AgentNavigationManagementSession(saved)
        check(canceled.draft == saved, "Cancel and reopen restore original order")
        let currentToken = canceled.beginDragging("alpha")!
        check(!canceled.drop(token: canceledToken, targetID: "codex", after: false), "late callback from canceled sheet rejected")
        check(canceled.drop(token: currentToken, targetID: "codex", after: false), "new session token remains usable")

        var providerSession = AgentNavigationManagementSession(saved)
        let providerToken = providerSession.beginDragging("alpha")!
        let provider = NSItemProvider(object: providerToken as NSString)
        check(provider.canLoadObject(ofClass: NSString.self), "real onDrag provider can be read by onDrop")
        let loaded: String? = await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: NSString.self) { object, error in
                continuation.resume(returning: error == nil ? object as? String : nil)
            }
        }
        check(loaded == providerToken, "item-provider roundtrip preserves exact nonce")
        check(providerSession.drop(token: loaded!, targetID: "codex", after: false), "deserialized drop reaches production reorder logic")
        var roundtripBackup: Data?
        let committed = providerSession.committed(current: saved)!
        check(AgentNavigationState.load(committed.encoded(), backupRaw: &roundtripBackup) == committed, "Done result persists through existing JSON model")

        let overflow = AgentNavigationOverflow.layout(orderedIDs: saved.renderableIDs(), availableWidth: 80)
        check(overflow.overflowIDs == ["codex", "alpha"], "normal More list keeps saved order")
        check(providerSession.draft.renderableIDs() == ["alpha", "codex"], "management can reorder the entire overflow population")
        var empty = AgentNavigationState()
        empty.initialized = true
        empty.customized = true
        let emptySession = AgentNavigationManagementSession(empty)
        check(emptySession.committed(current: empty) == empty, "explicit empty navigation is preserved")
        var accounts = AccountOrderSheetDraft(visibleIDs: ["a", "b", "c"], originalAllIDs: ["a", "hidden", "b", "c"])
        check(accounts.isValid && !accounts.hasChanges, "opening account order keeps the saved order")
        check(accounts.beginDragging("missing") == nil, "unknown account cannot start a drag")
        let accountToken = accounts.beginDragging("a")!
        check(!accounts.drop(token: "external", targetID: "c", after: true), "external account drop is rejected")
        check(accounts.drop(token: accountToken, targetID: "c", after: true), "account drag supports downward movement")
        check(accounts.orderedVisibleIDs == ["b", "c", "a"], "account drag changes the local draft")
        check(accounts.fullOrder(currentAllIDs: ["a", "hidden", "b", "c"]) == ["b", "hidden", "c", "a"], "account save preserves hidden slots")
        check(!accounts.drop(token: accountToken, targetID: "b", after: false), "account drop token is single-use")
        let staleAccountToken = accounts.beginDragging("a")!
        accounts.move("a", by: -1)
        check(!accounts.drop(token: staleAccountToken, targetID: "b", after: false), "a keyboard move invalidates a pending account drop")
        accounts.move("a", by: -1)
        check(accounts.orderedVisibleIDs == ["a", "b", "c"], "accessible moves can restore account order")
        let accountSelfToken = accounts.beginDragging("b")!
        check(accounts.drop(token: accountSelfToken, targetID: "b", after: true) && accounts.orderedVisibleIDs == ["a", "b", "c"], "self drop preserves adjacent accounts")
        check(accounts.fullOrder(currentAllIDs: ["b", "hidden", "a", "c"]) == nil, "concurrent account changes reject saving")
        let canceledAccountToken = accounts.beginDragging("c")!
        accounts = AccountOrderSheetDraft(visibleIDs: ["a", "b", "c"], originalAllIDs: ["a", "hidden", "b", "c"])
        check(!accounts.drop(token: canceledAccountToken, targetID: "a", after: false), "canceled account drag cannot alter a reopened sheet")
        check(accounts.drop(token: accounts.beginDragging("c")!, targetID: "a", after: false), "account drag supports upward movement")
        check(accounts.orderedVisibleIDs == ["c", "a", "b"], "upward account drop has the expected order")
        print("Passed \(count) production navigation and account management fixture checks; native dragging is checked separately")
    }
}
