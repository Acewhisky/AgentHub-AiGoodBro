# 0907v3 English screenshots

Software: **0907v3 · 9.5.7 (19)**. These PNGs render the production SwiftUI/AppKit views at native 2×. They are not AI-redrawn interfaces.

All accounts, limits, dates and token counts are synthetic. The previews use temporary account storage and isolated settings; they do not connect to Hub, read real credentials, switch an account or send a warm-up request. Unverified status and disabled actions intentionally reflect the disconnected fixture.

| Image | Content |
| --- | --- |
| 01 | Card-grid viewport with Pro missing-5h and two weekly-exhaustion cases |
| 02 | Single-account workspace |
| 03 | Single-account menu |
| 04 | Multi-account list viewport |
| 05 | Expanded model settings panel; this is not an open native model-choice menu |
| 06 | Automation settings |
| 07 | Appearance settings |
| 08 | Menu-bar settings |
| 09 | Workspace settings |
| 10 | About settings |

The `中文` option in Appearance deliberately keeps the language's own name. Old 0905v3 screenshots remain in their original folder for historical reference.

Reproduce with the built binary's `--render-workspace-previews <output> --preview-english` and `--render-settings-previews <output>` commands. The settings renderer exports both languages; this public set selects English only.
