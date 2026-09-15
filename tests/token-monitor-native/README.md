# Native token-monitor regression tests · 0913v1

Run `python3 tests/token-monitor-native/run.py` from a published source checkout on macOS with Xcode command-line tools. `--repo-root` supports isolated reviewed checkouts; `--suite` selects one group. No third-party install, account read, GUI launch or real notification is used.

- Engine: production Models + process supervisor, actual bounded synthetic child processes, extracted real quota DTO/custom decoder. C helper is synthetic output only.
- Routing: extracted production quota/reorder/cancel methods with explicit fake lock/RPC/store seams; it does not log in or prove an installed account switched.
- Selection: extracted production configure method and candidate expression, no real UsageStore startup.
- Interop: corrected D handler + pinned original upstream produced the four committed usage/limits envelopes with synthetic runners/HTTP. Only request filesystem roots are normalized to stable `/tmp/token-monitor-native-fixture` paths. The decoder does not open those paths. These fixtures preserve original numeric messages, model/session/project dimensions and distinct source/account IDs.

Complete process/DTO suite is 87 PASS lines, routing 16, selection 4, interop 7. Counts include suite summary lines. They are not evidence of a packaged native scanner or real credential/notification delivery.
