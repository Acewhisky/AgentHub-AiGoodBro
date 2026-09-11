# AiGoodBro 9.5.21

Release name: 0911v3

Build: 35 · macOS · 2026-09-11

## 主要更新

相较 0911v2 / 9.5.20 (34)：

- 对外应用包、执行文件、菜单/窗口和 macOS 打包资产统一为 AiGoodBro；界面短名 AH，工作台名 AgentHub。
- 主窗口支持原生全屏；绿色按钮与 Control-Command-F / 显示菜单可用。状态栏浮窗和任务概览仍为全屏辅助窗口。
- 合入当前版候选：Grok 受管 CLI 入口、Grok 重置观察、启动监控选择、官方登录服务层（未接 UI）、主窗口五项工作台与终端组合入口、账号浮窗、设置/菜单栏外观、逐模型可用性离线回执桥，以及安装空闲保护与新旧包名迁移。
- bundle ID、Application Support、defaults、Keychain 和账号目录保持原隔离名；不借改名迁移账号。
- Codex / Grok / Claude 等供应商品牌和 codexU MIT 来源署名保留。

## 验证与运行边界

本版在独立 `BUILD_DIR` 完成 macOS 编译、ad-hoc 签名、全局内存风险门禁、安装保护测试和必要候选纯测试。不安装、不启动日用应用、不登录/切号、不调用真实 provider、不提交/推送。

未执行真实桌面全屏点击、菜单栏点击、浮窗拖动、官方登录、真实 Grok 派单或额度接口。D 的登录工作流未接 UI。逐模型可用性缺真实模型证据。C 的进程级 runner 测试在无可用 `ps` 的沙箱中保持未验。Windows 源码保留，未构建。

## 源码安装

本版提供源码，无公开 DMG、二进制 Release 或对应 checksum。按 README 构建得到 `build/AiGoodBro.app`。从旧名 `CodexAccountManagerNext.app` 升级时，先退出正在运行的副本，再迁移为唯一的 `AiGoodBro.app`。本地构建使用 ad-hoc 签名，未进行 Apple 公证。

[README](../README.md) · [品牌兼容表](brand-compat-0911v1.md) · [统一 CLI](agent-cli-entry-0911v1.md)
