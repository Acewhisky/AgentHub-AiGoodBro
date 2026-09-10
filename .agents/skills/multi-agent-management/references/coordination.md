# 共享占用与日期问题日志

版本：0910v1。相对 0909v4 增加原生终端回执、Hub 准入门禁和参与时间窗；不接管旧任务，不修改账号身份。

## 状态与边界

| 状态 | 对外含义 | 是否占用 |
|---|---|---|
| preparing / starting | 在线·准备中；已经预约，尚未证明执行 | 是 |
| running | 在线·运行中；有实际进程或 Hub 运行证据 | 是 |
| cancel_requested | 等待取消完成 | 是 |
| uncertain / 心跳过期 | 状态待核实 | 是，不能当空闲 |
| awaiting_acceptance | 已结束·待验收 | 否；退出成功还需产物验收 |
| accepted / rejected / failed / cancelled | 已验收通过、验收失败、执行失败、取消完成 | 否 |

共用 `~/Library/Application Support/CodexAccountManagerNext/dispatch-activity-v1.json`，通过同目录 `.dispatch-activity.lock` 的系统文件锁与原子替换操作。状态中只有账号/目录哈希、字母、任务标识、阶段、时间及必要进程标识，不存任务正文或真实路径。禁止手改状态文件。

同一账号或同一 realpath 目录只允许一个活动占用；不同目录必须是经过授权的独立工作范围。新版 Next 原生终端登记 `terminal` 占用，新版 Hub 在创建和批准时读取同一文件锁下的占用。旧 CLI、旧 Next 和旧 Hub 不自动获得这些保障；不能用注册表为空替代全局进程证据，也不得通过终止既有 CLI 制造空闲。

Next 的 Desktop 切换在同一个文件锁内同时预约来源与目标身份；任何一方忙碌就不写入部分预约。登录进程未确认退出、切换恢复事务未完成时保留维护占用。重启恢复只处理已确认退出的原 Next 所有者及匹配的维护记录，不根据心跳过期释放。

Next 的新状态展示与暖号互斥需要部署支持协议的版本；候选版本号不能代替当前运行二进制证据。状态文件写入后其他对话可立即读取，Next 界面约每 10 秒更新。

## 准备与预检

下列命令中的标识和路径用当前任务实际值替换。所有示例本身不构成启动授权。

```sh
activity="$HOME/.codex/skills/multi-agent-management/scripts/next_dispatch_activity.py"
preflight="$HOME/.codex/skills/multi-agent-management/scripts/next_dispatch_preflight.py"
owner='<本次 Codex 任务 ID>'
task='<本次可验收子任务 ID>'
code='A'
workdir='<已核实的真实项目目录>'

# 只读查看。别人的准备、运行、待核实均阻止同账号/目录新调用。
python3 "$activity" status

# 确定账号后立刻预约，先于耗时环境探测、刷新等待、创建或启动。
python3 "$activity" reserve --code "$code" --cwd "$workdir" --owner "$owner" --task-id "$task" --route direct
# 使用命令返回的真实 leaseId，不能预编或复制旧任务的值。
lease='<本次返回的 leaseId>'

# 自己的预约不阻止自己的预检；三个标识必须一起提供。
python3 "$preflight" --cwd "$workdir" --refresh --code "$code" --lease-id "$lease" --owner-thread "$owner"

# 准备超过数分钟时，由所有者在 10 分钟宽限前续期。
python3 "$activity" heartbeat --lease-id "$lease" --owner "$owner"
```

`reserve` 在本地锁内重新核实 Hub 占用与路由、验证账号参与和身份后写准备状态；不调用模型。返回失败就没有获得新预约，不能继续启动。`preflightPassed` 仍只是额度/身份/路由检查，不能代替执行授权或工具能力。

## direct 调用

完成已授权的最小能力探测，保留实际入口、版本、参数支持、所需工具及输入读取结果。capability 文件必须由这些证据得出，不能为通过门槛先填 passed；探测缺工具时记问题，停止该环节或按已有授权缩小交付范围。Blender 最小导出、图片生成、原生 UI 等需要各自的真实能力证据，不能拿 CLI 帮助页替代。

运行器读取下列最低字段；`checkedAt` 需为一小时以内、带时区的真实验证时间，`cliSHA256` 对应本次 `codex` 实际可执行文件。任务级工具证据放在同一 capability 文件供编排者验收，运行器只验证下面三个字段，**不会替编排者证明所有工具能用**。

```json
{
  "status": "passed",
  "checkedAt": "<带时区的实际 ISO 8601 时间>",
  "cliSHA256": "<本次目标 codex 的 SHA-256>",
  "checks": ["<实际命令、观察结果和该证据能证明的范围>"]
}
```

```sh
python3 "$activity" run \
  --lease-id "$lease" --owner "$owner" --code "$code" --cwd "$workdir" \
  --codex-bin '<已核实的 codex 绝对路径>' \
  --brief-file '<本次自包含 brief 文件>' --output '<本次最终回复文件>' \
  --capability-report '<上述实际能力验证文件>' --refresh
```

运行器在真正启动前重新读取身份、参与政策、Hub 占用及新鲜额度，使用该 profile 的隔离 CODEX_HOME 和 Next 保存参数；本次明确指定参数用 `--model`、`--effort`、`--service-tier` 覆盖。默认 `workspace-write`，只读任务显式 `--sandbox read-only`；只有入口支持且授权范围合适时执行。环境不能继承当前桌面连接器的假设。

同一预约只能被一个运行器领取。它每 20 秒维护状态，保存实际进程及启动时间指纹；进程结束且进程组中无存活任务时才释放执行占用。结束后读最终回复、diff 和真实产物；失败会自动追加问题日志。长任务使用执行工具返回的 session 等待结果，不派完就离开。运行器不终止任何进程。

## Hub 调用

用 `--route hub` 预约，通过带自身 lease 的实时预检后，按主 Skill API 创建任务，请求中的 `dispatchLeaseId` 必须使用本次预约值。保存 requestId、返回的 task ID、冻结参数与审批 TTL；响应不明先查原请求，禁止重复创建。

```sh
# 创建返回后立即绑定；会核对账号哈希、真实目录路由及 Hub task ID。
python3 "$activity" sync-hub --lease-id "$lease" --owner "$owner" --cwd "$workdir" --hub-task-id '<真实 Hub task ID>'

# 核对并按已有授权批准后，托管状态同步；只读 Hub，不创建或批准。
python3 "$activity" watch-hub --lease-id "$lease" --owner "$owner" --cwd "$workdir" --hub-task-id '<同一 Hub task ID>'
```

watch 每 20 秒同步一次，终态或 uncertain 返回；网络失败则显式报告，预约保持占用，不能据此重发。恢复后用同一个 Hub task ID `sync-hub`，只从新鲜 Hub 事实恢复状态。Hub 自身的账号/项目锁继续生效。用户暂停/停止时停止后续监控；是否取消执行遵照用户的明确范围。

## 收尾与恢复

```sh
# 实际产物通过验收才写 accepted；不通过写 rejected 并追加问题记录。
python3 "$activity" finish --lease-id "$lease" --owner "$owner" --outcome accepted

# 准备阶段决定不启动，且确无活动进程时清理自己的预约。
python3 "$activity" finish --lease-id "$lease" --owner "$owner" --outcome cancelled
```

运行器意外退出、预约超时或 PID 证据不明时，保留占用并记问题；先查所属任务与当前进程，核对 PID 启动指纹及进程组。不能改 `owner` 抢走预约，不能只凭心跳过期认定进程结束。原所有者使用 `finish`，工具会拒绝仍存活的运行器、子进程或进程组；绑定 Hub 的活动任务须先同步真实终态。所有者不在场或进程证据不可读则报告阻塞，不强制清锁。

## 问题日志

唯一文件为 `~/Library/Application Support/CodexAccountManagerNext/operations-issues-v1.jsonl`。日志每行独立 JSON，追加使用同一系统锁和 fsync；不要用 `>`、整文件重写、每日新文件或版本日志替代它。

```sh
python3 "$activity" issue \
  --issue-id 'cli-tool-capability-gap' --component 'cli' --phase 'observed' \
  --code "$code" --owner "$owner" --evidence "$lease" \
  --summary '预期目标入口可完成约定导出；实际最小调用失败。已保留产物和错误类别；当前只完成可验收分析，导出仍待目标环境复核。'

# 同一个问题继续写，不改上一条。
python3 "$activity" issue \
  --issue-id 'cli-tool-capability-gap' --component 'cli' --phase 'verified_offline' \
  --code "$code" --owner "$owner" --evidence "$lease" \
  --summary '离线修复已通过对应检查；真实目标入口的导出与交付尚待验证。'
```

日期自动附带 UTC `recordedAt` 与上海 `dateShanghai`；phase 建议 `observed`、`investigating`、`candidate_fixed`、`verified_offline`、`deployed_verified`、`recurred`。同一 issueId 记录问题发展的每个阶段。摘要最多 1200 字，写预期、实际、影响、处理、验证和下一步；账号用字母，证据用不含私人信息的编号。

不要粘贴凭据、完整邮箱、私人绝对路径、私密链接或任务 prompt/response。详细业务产物保留在所属项目，由不敏感引用连接；日志负责跨任务的问题索引。无法写入时在当前任务明确报告、保留事实，恢复后再补写；不能声称已落盘。

## 经授权的维护占位

维护记录使用 `maintenance` 路由，在 Next 显示“在线·维护中”；只有占位，没有模型任务。先冻结新准入并保存每项开关原值与身份集合，等待真实 CLI 与 Hub 活跃任务结束，逐一占位，再核对全量覆盖和状态。恢复记录必须在重启前持久化；只恢复本次修改的字段，不能用整份旧配置覆盖其他修改。`uncertain` 或不可读状态阻止重启。重启后核对进程、任务、设置并释放自己的占位。没有维护授权时不执行维护，也不替其他任务清除占用。
