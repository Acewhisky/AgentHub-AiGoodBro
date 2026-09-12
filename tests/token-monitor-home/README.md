# Token home projection regression · 0913v1

Run `python3 tests/token-monitor-home/run.py` from a source checkout on macOS with Xcode command-line tools. `--repo-root` accepts an isolated reviewed checkout. No dependencies are installed, no account data is read, and no native GUI is opened.

The runner extracts `HomeEngineProjection` from the actual production main view, uses actual engine Models/process source and statistics-timezone implementation, and extracts actual announcement/channel DTO fields. Only the SwiftUI chart namespace/type shell is synthesized so Foundation-level projection tests can run without an application lifecycle.

19 assertions cover unknown versus real zero, partial sources, unknown cost independent of complete Token coverage, Int64 bounds, stale cache timestamps, selected timezone, both reset types, multiple events on one day, all53 announcement ordering, real channel-result ordering and full JSON dimensions. They do not prove native dragging, fullscreen, live notification delivery or installed UI layout.

All generated compiler/cache/executable files use an owned temporary directory cleaned on exit. This runner contains no fixed private project or home path.
