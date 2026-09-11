# AiGoodBro / AgentHub 安装兼容说明 · 0911v1

AiGoodBro 是对外软件名，AH 是界面短名，AgentHub 是应用内主页工作台名。当前版把可见的应用包、执行文件和 macOS 安装资产统一为 AiGoodBro；隔离存储与协议键保持兼容。

## 用户可见名称（统一为 AiGoodBro）

| 项目 | 当前值 |
| --- | --- |
| App 包名与默认安装名 | `AiGoodBro.app` |
| 主执行文件 | `AiGoodBro` |
| 构建产物 | `build/AiGoodBro.app` |
| DMG 命名 | `AiGoodBro-<version>-mac-<arch>.dmg` |
| Finder / 菜单显示名 | AiGoodBro |

## 必须保留的兼容标识（不要借改名迁移账号）

| 项目 | 保留值 |
| --- | --- |
| bundle ID | `com.blackielf.codex-account-manager-next` |
| 旧包名（仅升级识别） | `CodexAccountManagerNext.app` |
| 账号目录 | `~/.codex-account-manager-next/profiles/` |
| Application Support | `~/Library/Application Support/CodexAccountManagerNext/` |
| Cache | `~/Library/Caches/CodexAccountManagerNext/` |
| 偏好、快捷键和 Keychain | 沿用已有命名与保存值 |

从旧版升级时，先核对实际运行路径，等待应用自己的操作完成并正常退出。`make install` 会把唯一的启动包落到 `/Applications/AiGoodBro.app`；若只存在旧名 `CodexAccountManagerNext.app`，在目标空闲后迁到新名。不要同时留下两份可启动 App，不要终止其他 CLI。账号、当前 Codex 登录、参与调度状态和执行偏好仍读原隔离目录。

`make build` 只构建；`make install` 会替换系统 Applications 内的应用并打开。使用安装命令前先完成备份。安装后核对实际版本和设置是否恢复。

## 仓库地址

规范仓库为 `BLACKIELF/AgentHub-AiGoodBro`。已有源码目录可更新 remote：

```sh
git remote set-url origin https://github.com/BLACKIELF/AgentHub-AiGoodBro.git
```

只读更新检查优先新仓库；仅在新地址返回 HTTP 404 时兼容旧仓库名。其他错误仍明确报告，检查不会自动安装。

历史发布记录保留当时的名称与链接。新安装口令和文档使用新仓库名。

[安装指南](usage-guide.md) · [0911v1 变更](release-notes-v9.5.19.md)
