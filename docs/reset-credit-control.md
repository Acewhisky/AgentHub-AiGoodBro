# Reset-credit control

Next exposes reset-card redemption only as an account-card control with three separate confirmations.
This is a human-operated control. Agents must not initiate redemption, call the consume tool/RPC, or automate the confirmations. No CLI, Hub, menu, URL, automation, or background redemption entry is exposed. This policy does not claim to technically distinguish a human click from operating-system UI automation.
The first performs a fresh `account/rateLimits/read` and shows the selected account's remark plus the
short expiry of one specifically verified card. The second explains that eligible windows reset and the
weekly reset time changes. The third has the sole destructive button. Cancellation, selection/identity
change, challenge expiry, or view disappearance invalidates the sequence.

The implementation adapts—not copies—the Apache-2.0 OpenAI Codex `rust-v0.154.0` protocol snapshot at
[the tagged protocol source](https://github.com/openai/codex/blob/rust-v0.154.0/codex-rs/app-server-protocol/src/protocol/v2/account.rs): `app-server-protocol/src/protocol/v2/account.rs` defines card details, request fields,
and outcomes; `protocol/common.rs` maps `account/rateLimitResetCredit/consume`; the app-server and
backend-client processors establish timeout/idempotency and exact-`creditId` behavior; and the TUI
establishes available-card filtering and earliest-expiry selection. The product behavior is also
described by the [official banked resets article](https://help.openai.com/en/articles/20001498-how-banked-codex-resets-work).
The activity reservation uses the same normalized account key and Hub alias as login, warm-up and CLI launch; a configured Hub must report idle. The pipe reader has a 15-second deadline, nonblocking polling and a total 1 MiB output limit so a retained descendant pipe cannot keep its reader alive.

Reusing the existing Swift app-server process, per-home credential gate, process bounds, shared activity
lease, and private atomic store is smaller and safer than importing the Rust clients or adding a manager.

Only detailed rows whose `resetType` is `codexRateLimits`, status is `available`, identifier is non-empty,
and expiry is still future are eligible. Account IDs and card IDs are bounded and reject control
characters. Reset counts and timestamps accept only exact bounded JSON integers: booleans, fractions,
nonfinite values, and overflow fail closed. An absent or JSON-null `expiresAt` follows the official
no-expiry schema; any present malformed value invalidates the details. Duplicate card IDs, mixed or
oversized detail arrays, and missing detail remain unavailable rather than selecting an ambiguous card.
Purchased usage balance is never used as reset-card evidence.

The consume conversation re-reads account identity and the exact chosen card before sending one RPC.
It checks the card expiry against a fresh clock reading and checks the two-minute review lifetime again
after executable/version/process/app-server preflight, immediately before the write. It always supplies
`creditId`; it never retries automatically.

RPC stage, terminal result, write permission, and the "consume may have been sent" bit share one lock.
Only the expected response ID can advance `initialize -> rateLimits -> consume`; duplicate or
out-of-order IDs are ignored. Timeout, EOF, output-bound failure, and shutdown acquire that same lock and
close write permission before publishing a terminal result. If timeout wins before response 2, the late
response sees terminal state and cannot write consume, so the result is `requestNotSent`. If response 2
wins, it validates and performs the consume write while holding the lock; timeout waits and then reports
`outcomeUnknown`, retaining the attempt because the write may have reached the child. There is no second
lock and therefore no cross-lock ordering cycle.

One logical attempt has one UUID idempotency key. Before the RPC, Next stores a 0600 Next-scoped pending
envelope in a verified 0700 directory. Creation and clearing use
`DispatchParticipationSync.withSnapshotLock` plus `writeSnapshot`: each transaction re-reads the bounded
16 KiB file while locked, compares the expected bytes, atomically replaces it, and re-reads the result.
Creation never replaces an existing pending attempt. Clearing requires the exact expected account hash,
profile, card, expiry, and idempotency key, so a different process cannot erase another account's attempt.
Malformed, oversized, wrong-owner, linked, or group/world-accessible state fails closed.

An unknown outcome retains the pending attempt. The only allowed product retry repeats all three explicit
confirmations for the same account and exact card and sends the same idempotency key; no new key is
generated while uncertainty exists. A different account or card remains blocked. If the recorded card is
no longer reported as available, simply starting the flow again cannot reconcile or clear the attempt;
there is intentionally no bypass or clear control. Raw account/card identifiers, email, response bodies,
and private paths are never rendered or logged.

## Integration

The main workspace places the control only on the selected, independently signed-in account outside preview mode and supplies its existing refresh callback:

```swift
ResetCreditButton(
    profile: profile,
    selectedProfileID: selectedProfileID,
    hubAccountAlias: hubAccountAlias,
    onConfirmedResult: { refreshProfile(profile.id) }
)
```

`onConfirmedResult` runs for a parsed official outcome (`reset`, `nothingToReset`, `noCredit`, or
`alreadyRedeemed`) and should refresh limits. Result copy states only the concrete outcome and that limits
will refresh.

The SwiftUI source keeps three separate `alert(isPresented:)` stages. Each stage is reachable only from
its preceding explicit button, every stage has Cancel with the cancel shortcut, and the final destructive
button has no default-action shortcut. Alert dismissal calls `cancel()` only when that same stage remains
active, so advancing from a deliberate button does not cancel the next stage or consume automatically.

## Deliberate validation limit

**The reset flow has NOT been executed or tested.** No real or mocked redemption, confirmation traversal,
consume call, reset preview, reset fixture, or reset-related credential operation was performed.
The ordinary application self-tests run with this control excluded from preview mode. Validation is limited to whole-source macOS compiler typechecking and static source/call-graph
review, as explicitly required for this feature.
