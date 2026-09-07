# Codex Account Manager Next v9.5.7

Release name: 0907v3

## Highlights

- 相比 0907v2，补齐主窗口、账号卡、菜单栏、模型面板、设置、导出对话框及主要操作反馈的英文文案；日期和 Token 单位跟随界面语言，飞书通知同步支持英文。保留中文及原有设置。
- Pro 等账号缺少官方 5 小时窗口时，大字改为中性的“—”，小字说明未返回。缺失数据不等于无限额度。
- 官方周剩余额度为 0 时，账号卡、顶部概览与菜单栏的 5 小时可用额度同步显示 0；原始快照和官方重置时间不被改写，周窗口恢复后重新显示原始 5 小时数值。小于 1% 但仍大于 0 的数值使用 `<1%`。
- CLI 主按钮和更多菜单统一检查隔离登录、占用、启动中及登录中状态。“优先派活”改为明确的“优先标记 / 仅保存偏好”，英文为 `Priority / Saved only`；不宣称当前 Hub 已消费该标记。
- 替换公开主界面、单账号、模型与设置截图，全部使用当前英文生产组件的原生 2× 演示数据预览。

## Validation

- macOS arm64 release-optimized build (`make build BUILD_DIR=build-english-0907v3`) passed with Swift 6.3.2 and deployment target macOS 13. The bundle is `9.5.7 (19) / 0907v3`; strict ad-hoc signature verification and all five runtime PNG comparisons passed.
- All 26 pure self-test groups passed, including weekly-zero propagation with present/missing 5h data, source preservation, recovery, Claude non-interference, English date/token units, warm-up summaries, masked English notification payloads and existing screenshot save/cancel/failure coverage.
- All 69 isolated dispatch-participation tests passed. The standalone harness now includes the production language value type and token formatter instead of loading live app settings.
- `make lint`, `make test-macos-compatibility`, `make memory-risk-check` and `git diff --check` passed. The full memory-risk inventory was reviewed; localization adds no process, timer, observer or unbounded collection.
- Native previews were rendered in both appearances at 820/980/1280-point workspace widths. The English Pro/weekly-zero card cases, model panel and Automation settings were visually checked.

## Runtime acceptance boundaries

- Source-only update. No tag, GitHub Release or installer is created by this change.
- No installation or replacement of the running Next app; no real sign-in, account switch, warm-up, reset redemption, notification or Hub deployment was performed.
- Button callbacks and their safety guards were checked in source and isolated tests. This does not claim live provider or real-account acceptance.
- Weekly exhaustion affects presentation only. It does not change raw quota persistence, account eligibility or dispatch policy. Claude's independent windows retain their previous semantics.
- Historical audit entries, user-written labels and third-party error text are not rewritten by localization. Their original language may remain visible.
- Published screenshots use synthetic accounts and disconnected Hub state. The model screenshot shows the expanded settings panel, not a captured native dropdown.
- Windows sources are preserved; this delivery contains macOS validation only.

## Assets and checksums

No DMG or Windows installer was produced or uploaded, so there are no installer SHA-256 values. The local validation build uses ad-hoc signing; Apple notarization was not performed.
