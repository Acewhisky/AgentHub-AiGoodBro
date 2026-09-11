# agent-cli 统一入口 · 0911v8

相较 0911v1：补齐 Codex 运行委托、取消权威性、真实模型参数、环境隔离、输出上限及状态真实性。复用现有 Registry 和 supervisor，不新增常驻调度器。0911v8 审查 Grok 候选后保留零启动 plan 和受管 argv，但生产 run 因原生额度桥接缺失保持 fail-closed；调用者 JSON 不能冒充实时探测。

| 命令 | 当前行为 |
| --- | --- |
| capabilities | 检查本机程序存在性；认证与额度保持未知，回执存在不算最小调用成功 |
| plan --product codex | 委托 next_dispatch_activity 的既有只读计划 |
| run --product codex | 传入原 lease、owner、code、capability-report，委托既有受管入口完成准入检查与运行 |
| plan / run --product workbuddy | 仅应用自带 CLI；实际 argv 包含 --model，默认 deepseek-v4.1-flash，可显式选择 hy4-preview-f 或 hy3 |
| plan --product grok | 固定官方 `~/.grok/bin/grok`（解析到常规文件）；环境变量不能重定向生产钉。只接受精确 `grok-4.6-build`，argv 含 `--model`；`grok-4.6` 别名映射与 `grok-4.5` 均未获官方入口证据。plan 零启动、零额度声明；显式测试 executable 须测试开关 |
| run --product grok | 当前固定拒绝 `grok_quota_bridge_missing`。现有 `LocalCLIQuotaReader` 虽能读取官方额度与生成匿名 fingerprint，但其结果不保留证明禁付费回退所需的 on-demand cap/used，也没有受认证的 Swift→Python 导出通道。运行骨架要求同账号原始 fingerprint、精确 requested/actual model、同环境、可执行摘要、新鲜订阅额度和禁付费回退共同通过；手写 JSON 永不算生产探针 |
| status / result | 读取共享占用或校验产物哈希；取消/失败不显示成功，产物存在不代表验收 |
| cancel | 校验 owner、lease、进程组与 PID 创建时间，保留部分结果 |

运行需要 --allow-run 与 AGENT_CLI_ALLOW_RUN=1。这些开关只授权本次启动，不证明额度或费用。WorkBuddy 不自动重试或切换模型；请求模型与未验证的实际模型/费用分别表示。订阅是否仍免费可用须在执行前从原生产品核对。

取消意图不会被迟到的 running 或零退出覆盖。Hub 同步只在身份、项目与实时任务证据完整时更新，活动状态保留本地取消意图，真实终态才允许释放；Hub 原结果保留。进程组仍存活则保持占用。owner 是同机协作标识，不是同 uid 进程间的安全认证。

WorkBuddy 子进程清除 Codex、OpenAI、CodeBuddy、WorkBuddy、Anthropic、OpenCode、DashScope、xAI/Grok 等继承的认证或产品覆盖，PWD 与隔离工作目录一致，使用原生产品登录。简报经参数数组传入，stdout/stderr 持续排空但仅保留最多 1 MiB；截断、超时、取消不冒充成功，真实退出码不改写。可执行文件覆盖仅供显式启用的离线测试。

```sh
python3 -m unittest tests.test_cancel_authority tests.test_dispatch_activity tests.test_dispatch_invocation tests.test_agent_cli tests.test_agent_cli_grok
```

离线回归覆盖伪子进程的模型参数、超时、取消、输出上限、环境清理、Hub 同步、结果状态，以及 Grok 固定入口、桥接缺失拒绝、共享锁同身份冲突、额度字段校验和最小回执的身份/环境/二进制/模型/新鲜度匹配。没有调用真实模型、登录、切号、通知或重置卡；这些测试不证明真实供应商订阅权限。Grok 回执存在本身不算通过。
