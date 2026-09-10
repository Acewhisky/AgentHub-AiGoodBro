# Codex Account Manager Next v9.5.16

Release name: 0910v1

## Highlights

- 卡片压缩为并排双额度布局，820 点窄窗可显示三列；常用操作集中，完整暖号与重置记录保留在详情。飞书显示编号与备注，按测试、手动或低额度事件准确说明触发原因。
- 修复真实切换后当前账号标记滞留：身份验证通过后开始新账号的快照序列，迟到的旧账号查询不能把标记改回去。

- 飞书可在首次引导中保存并连接，已有凭据可显式授权。后台遇到钥匙串权限不足只显示待授权，不弹密码框；保存、授权和移除异步执行。电脑密码仅在 macOS 系统弹窗输入，ad-hoc 版本更新可能需再次授权。

- 重置消息默认开启：Next 运行期间每 5 分钟读取公开消息，不消耗账号额度。通过 macOS 通知接收，自动化中心可查看最新内容；飞书折叠为可选转发。首次不补发历史，已有关闭设置保留。
- Desktop 切换立即显示准备状态，可取消等待；身份与额度校验在后台并行执行，随后展示退出、切换、打开及验证阶段。来源与目标同时占位；来源身份变化就取消，普通切换不会自动强退。
- 修复终端按钮的启动路径与状态反馈。使用已校验绝对路径和隔离环境，优先本机独立 CLI，保留模型参数；启动回执、进程开始时间与退出记录共同维护账号占用。
- 账号参与调度新增时钟编辑器：允许或排除时段、星期、IANA 时区、跨午夜均可设置。只限制新任务，额度刷新与暖号按原开关继续执行。
- 保存暖号成功与失败历史；重登先占位，修复旧账号缺少 account ID 的验证。登录子进程未确认退出时保留占用，避免失败清理与新任务冲突。
- 公告恢复保留已校验的历史页面，并按有界检查点跨轮推进；历史存在缺口时显示真实状态，允许明确选择从当前消息继续，不删除待发或待核实记录。
- Apple Silicon 与 Intel 安装包均附调度 Skill、脚本和中文说明，只含虚构停用配置。升级保留个人映射、参与选择、模型偏好及开关；Hub 仍需单独部署。

## Verification

- 候选源码已通过 26 组原生自测、22 项 Python 协调测试、Python/Swift 文件锁互通与 Swift lint。
- 时间窗覆盖跨午夜、边界、空允许规则、无效字段、固定偏移拒绝及夏令时重复小时。调度配置另有 77 项隔离检查。
- 配套 Hub 的 Go 测试覆盖创建、批准、时段变更、取消预约、账号别名共用身份及不安全目录权限。本机部署完成，原配置、服务入口和 250 条任务元数据保持一致，维护预约已释放。
- 前四轮网页 6 Pro 发现的问题已逐项修复并增加对应回归；第四轮要求的飞书账本持续不可写、第 7 页本机恢复测试已通过。第五轮仅审新增钥匙串路径，未发现可证实 P0/P1；确认的两项 P2 已按建议修复：连接回读失败清除旧就绪状态，保存回调只清空本次提交值。对应本机回归、完整 26 组自测及双架构打包均已通过。末轮原始审查为两项 P2；修复后完成本机验证，未再发起网页复审。
- 源身份变化、同身份令牌更新、登录清理延迟、双身份原子占位、失败分页保留、跨轮恢复及无飞书原生基线恢复均有隔离回归。
- 全局内存风险门禁检查进程与管道、定时器、观察者、缓存、文件读取及父路径遍历。新增网络响应在读取过程中限量；公告状态最多 500 条、512 KiB。

## Runtime boundaries

- 公告来自 [Codex Resets 的公开 API](https://codex-resets.com/api/docs)，属于第三方汇总。公开公告不代表某个账号已重置，不会写入账号官方重置历史，也不会兑换重置卡。
- 暖号请求成功不证明官方 5 小时或 7 天窗口已经改变。终端启动回执、进程退出和真实模型请求分别验收。
- 已在用户明确授权下执行取消测试和真实桌面往返验证。现场发现身份切换后当前账号标记仍停留在旧快照，本次增加独立回归并修复。源码和模拟回归不代替修复后再次进行真实往返验证；恢复当前会话、回滚和异常中断仍按各自证据验收。
- 已在本机验证原生终端按钮、启动回执、实际 CLI 子进程与受控退出；没有向该终端发送模型任务。原生时段弹窗已操作验证，完整 7 天自然窗口和真实通知送达仍需各自证据。
- 界面控制工具打开自动化中心时断线；运行中的 Next 进程仍在。自动化中心图片由生产视图和合成状态渲染，只证明布局，不冒充实际点击验收。
- 已按后续明确授权覆盖此前候选并验证主窗口及设置保留；14:16 用户确认桌面已切回原 Pro 账号。本次卡片与推送修订已于 14:47 按授权更新，当前账号标记、列表与卡片切换均已在真实窗口核对。公开消息基线、预览图和自测均不代表真实新通知送达。
- Windows 源码保留，本轮仅构建与验证 macOS。

## Artifacts and signing

当前为本地候选，尚未推送、打标签或发布。

macOS Apple Silicon 与 Intel 安装包由仓库 release-package 流程构建，挂载后核对架构、签名及九个配套 Skill 文件。签名为 ad-hoc；没有执行 Apple notarization。标签工作流默认只运行 macOS；Windows 保留为手动选择。

```text
6034910a2c60b06afcda5e9c173cbb88c2cab87c21f193c739f714651ed47a66  CodexAccountManagerNext-9.5.16-mac-arm64.dmg
34186b2f5359e8fe9065759a0cd5b227fad24575209e253553018e59315e0dfe  CodexAccountManagerNext-9.5.16-mac-x86_64.dmg
```

## Implementation references

- [Apple：代码签名要求](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)：ad-hoc 签名的程序身份绑定具体构建，因此不能保证升级后沿用上次钥匙串授权。

- [Apple：macOS 钥匙串实现差异](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychain-apis-and-implementations)：保留已有文件式钥匙串凭据，以兼容接口控制后台交互；不扩大 ACL 或迁移凭据。

- [OpenAI 官方 CLI 登录实现](https://github.com/openai/codex/blob/main/codex-rs/login/src/server.rs)：沿用隔离的官方登录流程，并在写回前后验证身份。
- [OpenAI 官方长 socket 路径问题](https://github.com/openai/codex/issues/27765)：终端入口携带显式 CLI 配置；不为修复警告迁移凭据目录。
- [Planet 的原生 Terminal 打开方式](https://github.com/Planetable/Planet/blob/main/Planet/TemplateBrowser/TemplateBrowserSidebar.swift)：采用 NSWorkspace 打开命令文件的系统接口，没有引入依赖。
- [原生账号切换器的阶段反馈设计](https://github.com/aqwsde321/codex-account-switcher-macos/tree/5a429281b42f6f3b6b318f7622c8caf65385550e)：仅借鉴异步进度思路，未复制未声明许可的代码。

[共享协议](dispatch-coordination.md) · [使用说明](usage-guide.md)
