# Task lifecycle fixes · 0911v2

Compared with 0911v1, the candidate is integrated and passes the full macOS build and 26 native self-tests.

- TaskRuntimeReducer captures the notification generation when thread/list is sent. A newer notification retains its state and turn identity when an older list response arrives. An omitted task is retained for one qualifying notification cycle, then removed if a later complete list still omits it without fresh evidence.
- turn/completed rejects a different current turn ID. Duplicate completion is idempotent; a single failed item cannot end a running turn, and an item from another turn is ignored.
- Switching and startup recovery carry transaction generations. Starting, finishing or invalidating a transaction cancels the pending restore retry and invalidates older callbacks.
- Restore retries return cancellable handles, checked before opening a deep link and before completion. The pure tests cover cancellation, late work, repeated cancellation and duplicate completion.
- awaitSnapshot removes an individual waiter on timeout. Another coalesced request can still complete. Request generations and callbacks are cleared on response, write failure, disconnect and connection replacement.

Unknown cancellation spellings remain conservative. No real app-server session, account switch, deep link, sign-in, notification or reset redemption was exercised by these regressions.
