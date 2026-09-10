# 本机入口与故障参考

版本：0910v1。以下为默认布局示例，操作前重新核实实际部署；本文件不授予安装、重启、登录或切号权限。

| 组件 | 当前入口与验证 |
|---|---|
| Next | `build/CodexAccountManagerNext.app`；先核对 Info.plist、实际可执行路径、PID 和单实例；从独立候选构建验收后按维护授权替换。 |
| Next 数据 | `~/Library/Application Support/CodexAccountManagerNext/` 中的快照及 `dispatch-codes-v1.json`；不读取或输出原始凭据。 |
| Hub | `http://127.0.0.1:8787`；`GET /api/overview` 看任务与账号/项目占用，`GET /api/manager/overview` 看 Next 数据映射；有效任务状态、租约、正文可读性分别核实。 |
| Hub 部署 | `~/Library/Application Support/arc-0828v1/bin/agent-remote-control`，LaunchAgent `com.agenthub.arc-hub`；日志在 `~/Library/Logs/arc-hub/`。现场核实实际路径，不能另起第二个 nohup 服务。 |
| Hub 配置 | 与 Next 仓库相邻的 `agent-remote-control-0828v1/config.json`；账号 alias/home 身份集合未变时，现役 Hub 可热读取 dispatchDisabled，仍须检查 API。 |
| CLI | 使用已选 profile 的独立 CODEX_HOME，读实际入口版本/帮助/模型/工具。Hub 忽略用户配置及规则，不能推断本对话工具在其中可用。 |

## 按阶段处理

- **预检**：`preflightPassed` 是账号、额度、策略和路由结果；缺少 capability 验证或启动授权仍不执行。只有报告生成成功的退出码 0 没有启动含义。
- **创建**：结构化参数或已保存的 body 文件提交 brief，保留同一次逻辑提交的 requestId。Hub 在创建时冻结 Next 保存模型；目前不支持创建参数中的一次性模型覆盖。先核对该限制再决定入口，不能只在 prompt 里指定模型。
- **批准**：核对 task ID、账号、项目、actionHash、TTL、冻结参数和截止时间；已有执行授权覆盖必要 API 批准。用户要求自己审批时交给用户。
- **执行**：只有 running 的任务状态或可核对的实际 CLI 进程证明已开始。读到超时/断连先查任务是否继续，勿重发。
- **完成**：resultNote/最终回复配合真实文件、差异和适用检查。真实网页、应用 UI、服务调用、文件导出/发送须各有对应证据。

## 维护中容易误判的点

- 当前 Hub 的只读任务用 read-only；需要写入才选 workspace-write。模式应匹配任务，不能把所有只读审计都当成空跑。
- Swift 快照数字时间从 2001-01-01 UTC 起算；换算 Unix 加 978307200，时间比较用 UTC，重置点展示上海时间。null 是未知，不是 0。
- 同一真实项目目录的不同别名共享租约。`uncertain` 不等于空闲；查进程与日志后才能作明确停止确认。
- `journal_locked` 通常仍有原持有进程。确认无非终态任务后按授权 bootout 原 LaunchAgent、核对实际 PID，再替换恢复；不要反复 start 或修写 journal 来掩盖第二实例。
- GUI 应用优雅退出，避免 SIGKILL 引起恢复窗口或启动卡住；日志落点不使用受 TCC 保护的 Documents。
- profile 登录恢复一次一个账号，使用用户已选择的原生/浏览器方式；设备码只在该流程适用且已授权时使用，不能把一次成功写成永久禁止其他官方登录入口。身份与额度读回均通过才算恢复。
- 0910v1 将 Next 原生终端接入占用与启动回执，Hub 创建/批准增加共享占用和参与时间窗检查；必须分别核对实际 Next 与 Hub 二进制，不能把候选构建当成已部署。旧 CLI 和旧 Hub 仍可能绕过协议，不能仅凭注册表为空判定全局空闲。
- 当前仍有边界：Hub 单任务参数覆盖、所有宿主工具的统一探测、旧入口的全生命周期接入。Blender、GUI 和导出必须在实际目标入口验证，启动失败不能算模型验收。参见[共享占用协议](coordination.md)。
- 已观察过的回归点：额度仍为 100% 时成功暖号被重复触发、几分钟完成的任务延迟收取、统计刷新使无关控制变灰。处理与验证继续写同一个问题日志，不把源代码修复当成已部署的运行效果。
