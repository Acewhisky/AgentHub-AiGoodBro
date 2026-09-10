# AiGoodBro 9.5.19

Release name: 0911v1

Build: 33 · macOS · 2026-09-11

## 主要更新

- 原 Codex Account Manager Next 更名为 **AiGoodBro**，主页工作台名为 **AgentHub**。新仓库为 `BLACKIELF/AgentHub-AiGoodBro`，原安装路径、账号和设置继续保留。
- 主页增加专业与极简模式。极简模式可看总览、账号卡片或最多四个自选模块；专业模式保留完整工作区。
- 模型与强度选择使用完整原生菜单；编辑面板按内容确定高度。官方余额主显示取整数，详情保留精确值、来源与读取时间。
- Grok 官方额度读取补全客户端请求头，并严格检查已过期的缓存。缺失字段显示未知，不推断可用额度。
- OpenCode、WorkBuddy 和 ZCode 提供官方终端入口；TRAE SOLO 提供桌面入口。系统与用户 Applications 文件夹内的应用均可被发现。不同入口的账号和额度支持范围见[覆盖说明](local-cli-accounts.md)。
- 任一已知订阅窗口耗尽时，自动和手动暖号均被阻止；异步占用检查后重新核对额度，额外余额不会绕过订阅门禁。

## 源码预览与验证

本版提供源码与文档，尚无 9.5.19 二进制 Release 或 DMG checksum。

macOS 本地完整构建、26 组应用自检与内存风险门禁已通过。CLI 离线回归检查账号关联、目录校验、官方响应解析和终端命令隔离。更新地址通过 URLProtocol 桩检查 404 回退逻辑。

这些检查没有执行真实 Desktop 切号、暖号、重置卡兑换或通知送达。多 CLI 的登录、官方额度和真实调用支持并不相同，界面会保留未知或未接通状态。本版未安装到日用环境，Windows 源码保留且未验证。

## 安装与兼容

从 README 的源码步骤构建。App 包仍为 `CodexAccountManagerNext.app`，显示为 AiGoodBro；升级前备份，在原路径覆盖并核对版本、账号和设置。沿用 Next 的 bundle ID、profiles、support、cache、defaults 与 Keychain 命名。

本地构建使用 ad-hoc 签名，未进行 Apple 公证。将来发布的安装包继续使用 `CodexAccountManagerNext-9.5.19-mac-<arch>.dmg` 命名。

[README](../README.md) · [安装兼容说明](brand-compat-0911v1.md) · [使用指南](usage-guide.md) · [完整变更历史](../CHANGELOG.md)
