# 运行环境引导与调用流程

0910v2 相比 0910v1：Next 检测并复用现有 Codex CLI 与 Python，缺少时引导官方安装，回到应用后自动复检。Python 与 Codex 不随 Next 打包；Next 自有的 Hub 二进制与配套 Skill 随正式包提供，用户不需要安装 Go。

首次打开 Next 的「使用引导 → 准备运行环境」，查看每项用途、版本和状态。Codex CLI 使用官方独立安装器，不必为了它安装 Node；Python 3.9 或更新版本仅用于配套 Skill，缺少时不影响 Next 基础账号管理。可从安装菜单打开官方指南、复制 Codex 官方安装命令，或选择已经安装的程序。软件不会静默运行第三方安装器。

检查通过后选择「安装配套调用工具」。已有账号政策、配置和其他 Skill 会保留，更新的配套文件先备份。需要本机调度时先添加独立账号，再选择工作目录启用服务；发现现有 Hub 时复用并显示实测状态，不另起第二个服务。

统一入口是本 Skill 的 `bin/next-dispatch`。它优先使用 Next 验证后登记的 Python 与 Codex 路径，不要求修改 shell 的 PATH。高级调用可显式传入 `CAMNEXT_PYTHON` / `CAMNEXT_CODEX_BIN` 或 `--codex-bin`，仍需通过原有身份、能力和占用检查。

## 一次执行

1. `plan --code <编号> --cwd <项目目录> --brief-file <brief> --output <新结果文件>`：只读校验本地输入并冻结参数预览，不联网、不预约、不调用模型；输出 `preflightRequired:true` 与 `capabilityRequired:true`。
2. 按原有协议 `reserve`，再做能力检查与 `preflight`。已有授权覆盖启动时，使用同一预约执行 `run`；用 `--refresh` 请求本次新额度证据。账号、身份、占用、路由和能力门禁继续有效。
3. `run` 在输入后冻结 brief 字节与哈希，以 stdin 传递，避免正文进入进程参数。最终回复与 `<结果文件>.next-run.json` 以私有权限独占创建，已有输出或回执会阻止重复提交。
4. 中断或收取延迟后先 `status --lease-id <预约>` / `status --owner <任务所有者>`；`result --output <结果文件>` 校验回执与最终回复哈希。不要靠新建输出文件绕过尚在运行的原任务。
5. CLI 退出 0 且有可验证的最终回复后才进入 `awaiting_acceptance`；这仍不是成果验收。读取回复，核对真实文件、差异、适用测试与外部回执后才 `finish --outcome accepted`。

## 等待与失败

`watch-hub --wait-seconds 60` 单次最多等 60 秒，仍在执行会返回 `waitTimedOut:true`，预约继续保持。下一次沿用同一 task ID 和 lease ID 等待；超时不等于失败，也不授权重复批准或重新提交。

回执只保存哈希、参数与状态；正文保留在用户选定的结果文件。brief 最大 1 MiB、最终回复最大 8 MiB；超出限制先整理输入/交付方式，不静默截断。只读 `plan` / `status` / `result` 失败不会写全局问题日志。真实执行错误继续进入统一问题日志。

配套依赖保证 Next 核心 CLI 流程可用，不代表继承 Desktop 的插件、浏览器、图像生成或应用控制能力。第三方业务工具仍按任务逐项验证。
