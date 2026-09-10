# agent-cli 统一入口 · 0911v2

相较 0911v1：补齐 Codex 运行委托、取消权威性、真实模型参数、环境隔离、输出上限及状态真实性。复用现有 Registry 和 supervisor，不新增常驻调度器。

| 命令 | 当前行为 |
| --- | --- |
| capabilities | 检查本机程序存在性；认证与额度保持未知，回执存在不算最小调用成功 |
| plan --product codex | 委托 next_dispatch_activity 的既有只读计划 |
| run --product codex | 传入原 lease、owner、code、capability-report，委托既有受管入口完成准入检查与运行 |
| plan / run --product workbuddy | 仅应用自带 CLI；实际 argv 包含 --model，默认 deepseek-v4.1-flash，可显式选择 hy4-preview-f 或 hy3 |
| plan --product grok | 暂不支持通用受管计划；应用内的 Grok 官方终端入口独立保留 |
| status / result | 读取共享占用或校验产物哈希；取消/失败不显示成功，产物存在不代表验收 |
| cancel | 校验 owner、lease、进程组与 PID 创建时间，保留部分结果 |

运行需要 --allow-run 与 AGENT_CLI_ALLOW_RUN=1。这些开关只授权本次启动，不证明额度或费用。WorkBuddy 不自动重试或切换模型；请求模型与未验证的实际模型/费用分别表示。订阅是否仍免费可用须在执行前从原生产品核对。

取消意图不会被迟到的 running 或零退出覆盖。Hub 同步只在身份、项目与实时任务证据完整时更新，活动状态保留本地取消意图，真实终态才允许释放；Hub 原结果保留。进程组仍存活则保持占用。owner 是同机协作标识，不是同 uid 进程间的安全认证。

WorkBuddy 子进程清除 Codex、OpenAI、CodeBuddy、WorkBuddy、Anthropic、OpenCode、DashScope、xAI/Grok 等继承的认证或产品覆盖，PWD 与隔离工作目录一致，使用原生产品登录。简报经参数数组传入，stdout/stderr 持续排空但仅保留最多 1 MiB；截断、超时、取消不冒充成功，真实退出码不改写。可执行文件覆盖仅供显式启用的离线测试。

```sh
python3 -m unittest tests.test_cancel_authority tests.test_dispatch_activity tests.test_dispatch_invocation tests.test_agent_cli
```

当前89项离线回归通过，覆盖实际伪子进程的模型参数、超时、取消、输出上限、环境清理、Hub同步和结果状态。超时停止同样核对进程出生标识，PID复用时拒绝发信号并保留失败结果。没有调用真实模型、登录、切号、通知或重置卡；这些测试不证明真实供应商订阅权限。
