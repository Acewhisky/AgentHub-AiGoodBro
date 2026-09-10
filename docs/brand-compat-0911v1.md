# AiGoodBro / AgentHub 安装兼容说明 · 0911v1

AiGoodBro 是原 Codex Account Manager Next 的新显示名，AgentHub 是应用内的主页工作台。0911v1 · 9.5.19 (33) 提供 macOS 源码预览，尚无本版 Release 安装包。

## 保留现有安装

| 项目 | 保留值 |
| --- | --- |
| App 包名与默认安装名 | `CodexAccountManagerNext.app` |
| 主执行文件 | `CodexAccountManagerNext` |
| bundle ID | `com.blackielf.codex-account-manager-next` |
| 构建产物 | `build/CodexAccountManagerNext.app` |
| DMG 命名 | `CodexAccountManagerNext-<version>-mac-<arch>.dmg` |
| 账号目录 | `~/.codex-account-manager-next/profiles/` |
| Application Support | `~/Library/Application Support/CodexAccountManagerNext/` |
| Cache | `~/Library/Caches/CodexAccountManagerNext/` |
| 偏好、快捷键和 Keychain | 沿用已有命名与保存值 |

升级前核对实际运行路径，等待应用自己的操作完成，正常退出并备份，再在原路径覆盖。保留账号、当前 Codex 登录、参与调度状态和执行偏好。不要另建 AiGoodBro.app，避免出现两份应用。

`make build` 只构建；`make install` 会替换系统 Applications 内的原应用并打开。使用安装命令前先完成上述备份。安装后核对实际版本和设置是否恢复。

## 仓库地址

规范仓库为 `BLACKIELF/AgentHub-AiGoodBro`。已有源码目录可更新 remote：

```sh
git remote set-url origin https://github.com/BLACKIELF/AgentHub-AiGoodBro.git
```

只读更新检查优先新仓库；仅在新地址返回 HTTP 404 时兼容旧仓库名。其他错误仍明确报告，检查不会自动安装。

历史发布记录保留当时的名称与链接。新安装口令和文档使用新仓库名。

[安装指南](usage-guide.md) · [0911v1 变更](release-notes-v9.5.19.md)
