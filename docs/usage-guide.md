# Next 使用说明 · 0909v4

本页保留 README 之外的配置和行为说明。版本 9.5.15 (29)，macOS 13+；Apple Silicon 与 Intel 源码保留，本次只在当前 Apple Silicon Mac 验证。

## 安装与配置

需要 Xcode Command Line Tools、Swift、Git、Make 和能正常登录的 Codex。缺少编译工具时，由用户完成 `xcode-select --install`。源码构建：

```sh
git clone https://github.com/BLACKIELF/codex-account-manager-next.git
cd codex-account-manager-next
make build
codesign --verify --deep --strict build/CodexAccountManagerNext.app
```

构建产物不会自动安装或启动。确认没有已有 Next 时，可以选择安装到当前用户目录：

```sh
mkdir -p "$HOME/Applications"
ditto build/CodexAccountManagerNext.app "$HOME/Applications/CodexAccountManagerNext.app"
open "$HOME/Applications/CodexAccountManagerNext.app"
```

已有 Next 时，先记录实际运行路径、设置和账号偏好，等待自己的操作结束，正常退出并备份后在原路径覆盖。不要新增同名副本，也不要覆盖名称不同的旧管理器。构建脚本会拒绝覆盖正在运行的目标二进制；开发时可以指定独立 `BUILD_DIR`。

第一次打开会显示四步引导，可以跳过、续看和重新进入。通用偏好采用 README 中的默认值；账号、当前登录、机器人配置与“已完成引导”状态不会从其他用户复制。

单账号可以先监控当前 Codex。需要独立 CLI 时，在 Next 添加同一账号的隔离登录；它与系统入口不会被当成两个不同身份。登录、MFA 和 Chrome 账号选择由用户通过官方页面完成。

## 账号动作

![新版列表工作台，原生演示数据](images/0909v4/03-workspace-list-zh-light@2x.png)

| 动作 | 作用 | 额度与身份 |
|---|---|---|
| 刷新 | 获取官方身份、额度、会员日期及重置时间 | 不发送任务生成请求 |
| 暖号 | 通过门禁后发送一次最小请求，再读额度 | 消耗额度；不切换 Desktop |
| 独立 CLI | 使用目标账号自己的 CODEX_HOME 和参数 | 任务消耗对应账号额度；不改 Desktop |
| 监控 | 选择工作台与菜单栏显示的账号 | 不切换登录 |
| 重新登录 | 通过官方流程更新目标登录 | 系统入口会影响系统登录；独立入口保留隔离 |
| 切换 Desktop | 显式改变 Codex App 当前登录 | 经过身份、任务、锁、写后核验及回滚事务 |

低额度推荐只给出候选提示，不自动派单或切号。开始 CLI 时还要重新检查当前占用。

账号备注最多 40 个字符；长备注可以省略，详情保留完整显示。编辑模式支持排序、改名和移除；排序提交一次，取消拖动不写顺序。删除账号会将目标资料移到废纸篓，不删除平台账号。

## 模型与参数

新账号默认 `gpt-6-astra / low / default`。已有保存参数优先。界面支持的模型与推理强度：

| 模型 | 可选思考强度 | 速度 |
|---|---|---|
| GPT-6 Astra、5.6 Sol、5.6 Terra | Low、Medium、High、XHigh、Max、Ultra | Standard / Fast |
| 5.6 Luna | Low、Medium、High、XHigh、Max | Standard / Fast |
| GPT-5.5、GPT-5.2 | Low、Medium、High、XHigh | GPT-5.5 支持 Fast；GPT-5.2 仅 Standard |

以上是本版参数校验表，不保证每个账号获得服务端访问。无效组合被拒绝，不静默降级。修改用于后续 CLI 及其默认子 Agent；“应用到所有账号”是一次批量设置，不持续覆盖之后的单独调整。

暖号固定使用轻量维护模型，不跟随任务偏好。费用估算不等于订阅账单。

## Hub 与共享占用

Hub 是另外运行的本机服务。Next 读取 `127.0.0.1:8787/api/overview` 和预配置账号映射，不负责安装 Hub 或替它创建真实任务。缺少可信映射、任务列表或新鲜概览时，CLI 与暖号保持关闭。

调度编号保存在 Next 支持目录的 `dispatch-codes-v1.json`。编号是唯一的大写字母，关联本机已有 profile 与 Hub alias。通过“参与调度”进行受验证的三源同步；关闭后保留原字母，重新加入沿用。不要各自手改三份配置。

共享占用把准备、运行、维护与待验收阶段写入 `dispatch-activity-v1.json`。Next 暖号和接入协议的调度器共用账号锁；本机 UI 也能按身份哈希显示排除调度账号的维护占用。释放维护记录后，原有映射门禁继续生效。

旧交互 CLI 和直接绕过协议的 Hub 调用需要单独检查。详见[接入说明](dispatch-coordination.md)。

## 暖号与提醒

5 小时与 7 天维护分别跟随全局开关，不受账号是否参与调度影响。到期先刷新，身份、额度和任务证据有效才请求；忙碌则等待。失败至少延后 5 分钟复核。周额度耗尽时继续刷新恢复状态，暂缓暖号。

满额度并不是新一轮窗口的证据。本版用重置事件代次区分已处理事件和请求途中出现的新事件；成功会确认本次处理事件，避免继续每分钟发送。官方 reset 与本地维护计划分别显示，以实际官方结果判断窗口是否更新。

低额度提醒线默认 5 小时 ≤5%、7 天 <10%，两者可分别选 5/10/15/20/25%。推荐还要求可信任务状态、用户离开 Codex 前台、参与选择和间隔等条件；没有候选时不制造通知。

系统通知开关默认开启，但要由用户主动授予 macOS 权限。飞书开关及额度重置、Reset 卡增加两类事件默认开启，机器人未配置时只显示待配置。Webhooks 保存在 Keychain，不回填到界面或日志。真实测试发送由用户明确点击。

## 截图、外观与工作区

右上角相机按钮通过生产 SwiftUI/AppKit 组件导出当前完整工作台，包含滚动区外账号，不截其他窗口或临时弹窗。原生保存面板由用户选择 PNG 位置，不自动上传。正常导出为 2×；大图降为 1×，超出 3200 万像素或单边 32768 像素时提示调整，不静默裁切。

设置分为外观、菜单栏、自动化、工作区、关于。支持中文 / English、跟随系统 / 浅色 / 深色、内置配色、菜单栏密度与指标、置顶、后台驻留、统计时区、Runtime 来源和全局快捷键，并尊重减少动态效果。

菜单栏默认 Classic，显示 7 天剩余额度。可以选择已用口径、多窗口指标、今日 Token 和重置倒计时。自动更新检查只读取本仓库公开 Release，不静默安装。

## 数据与恢复

Next 的 bundle ID 为 `com.blackielf.codex-account-manager-next`。账号、支持文件与缓存使用各自的 Next 命名空间：

```text
~/.codex-account-manager-next/profiles/
~/Library/Application Support/CodexAccountManagerNext/
~/Library/Caches/CodexAccountManagerNext/
```

独立 CLI、纯刷新与暖号不修改当前 Desktop 身份。显式 Desktop 切换、系统账号重新登录及未完成切换恢复可能写系统登录。切换使用身份核验、专属锁、优雅退出、原子写入、写后验证与安全回滚；有任务或身份证据不明时不继续。

运行问题始终追加到同一个 `operations-issues-v1.jsonl`，包含日期、问题标识、阶段、脱敏编号和证据引用。不能把日志条数当成已经解决的数量。

卸载 App 不自动删除账号、设置或 Keychain。需要删除这些资料时另行明确操作。

## 排查入口

- CLI 灰色：检查当前 Hub 概览、可信映射、共享预约及真实进程；“未知”不等于“空闲”。
- 暖号没执行：看开关、最近结果、周额度、占用和官方重置；失败会延迟复核。
- 额度显示“—”：官方未返回该窗口，或本次读取失败；查看旁边说明与详情。
- 通知没显示：区分开关、系统授权/机器人配置、发送结果以及实际送达。
- 升级后状态不符：核对实际运行路径、版本、单实例和保存偏好，不先删数据重装。

[README](../README.md) · [安全说明](../SECURITY.md) · [变更历史](../CHANGELOG.md)
