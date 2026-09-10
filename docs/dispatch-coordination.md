# 调度共享占用接入 · 0910v1

供已有本机 Hub、Next 账号映射与调度 Skill 的集成者使用。安装 Next 不会自动建立这些配置，也不会把当前桌面连接器、浏览器权限或生图能力传给另一个 CLI 环境。

## 文件与读取

Next 和配套 Python 工具共同使用：

```text
~/Library/Application Support/CodexAccountManagerNext/dispatch-activity-v1.json
~/Library/Application Support/CodexAccountManagerNext/.dispatch-activity.lock
~/Library/Application Support/CodexAccountManagerNext/operations-issues-v1.jsonl
```

状态通过系统文件锁和原子替换写入；包含身份与目录哈希、任务/占用标识、时间和进程证据，不包含真实账号、目录或任务正文。禁止直接修改状态 JSON。

仓库脚本的只读与离线入口：

```sh
python3 scripts/next_dispatch_activity.py status
python3 scripts/next_dispatch_activity.py --help
python3 scripts/next_dispatch_preflight.py --self-test
python3 tests/test_dispatch_activity.py
python3 tests/test-dispatch-activity-interop.py
```

`reserve`、`run` 和 Hub 同步入口要求配套调度 Skill 的本机映射、政策和目标路由。仓库不附带作者的账号配置。集成时先检查帮助与已有 Skill 的配置约定，不从其他用户复制账号别名、身份、路由或参与政策。

## 调用顺序

1. 用户授权任务后，核实实际执行环境、所需工具、输入与验收办法。
2. 确定账号和真实项目目录后立即 `reserve`，记录返回的 leaseId。只占位不启动模型。
3. 用自己的 leaseId、所属任务 ID 与账号编号进行预检。别人的预约、过期心跳与未知进程不能忽略。
4. 通过当前身份、额度、参与、路由和 Hub 空闲检查后执行。同一次预约只能被一个运行器领取。
5. direct 路由由 `run` 托管实际进程和心跳；Hub 创建请求带本次 `dispatchLeaseId`，创建后先 `sync-hub` 绑定真实 task ID，再批准并使用 `watch-hub` 跟进。
6. 实际进程结束且进程组没有活动任务后进入待验收。及时检查最终回复、diff 和输出文件，再记录 accepted 或 rejected。
7. 失败和后续处理续写同一问题日志。状态不确定时保留预约，通过原 task ID 或进程证据恢复，不能重复启动。

运行器检查 capability 文件的时间、实际 CLI 二进制哈希与状态字段，但不能替集成者证明 Blender、浏览器、生图或外部服务可用。必须保留对应工具的实际证据。

`prioritizeDispatch` 只在资格门禁全部通过后影响自动选号排序。用户指定账号时不会被优先排序替换；Hub 自主选号是否消费该偏好取决于其版本。

## 维护占位

经授权的维护记录使用 maintenance 路由，可以在 Next 中显示“在线·维护中”。先冻结新准入、固定身份集合并保存开关原值，再等现有调用结束、逐账号占位，完成全量覆盖检查并保存恢复记录后才重启。旧 Hub 需要关闭其既有接单开关；不创建假 Hub 任务，也不发送模型请求。任何不确定占用或不可读状态都会阻止重启。

维护后核对运行版本、原设置、账号偏好和任务记录，恢复接单开关，再释放自己的所有占位。只按字段恢复，不用旧整份配置覆盖维护期间的其他修改；不终止其他 CLI 来制造空闲。

## 日志续写

```sh
python3 scripts/next_dispatch_activity.py issue \
  --issue-id 'example-problem' --component 'integration' \
  --phase 'observed' --summary 'A short sanitized observation' \
  --evidence 'review-identifier'
```

工具自动写入 UTC 时间与上海日期。后续修复、离线验证和真实运行验收沿用同一 issue ID，分别追加阶段。不要写账号邮箱、凭据、Webhook、任务正文或私有路径。界面的“运行问题日志”按钮打开这同一份文件。

## 保护范围

0910v1 的 Next 原生终端登记 terminal 占用，并核对私有启动回执与进程开始时间；账号重登使用 maintenance 占用，登录子进程未确认退出时不释放。Desktop 切换在同一文件锁内同时预约来源与目标身份，任一方冲突就不建立部分预约；恢复事务未完成时保留占用。配套新版 Hub 创建和批准均在同一文件锁下检查账号身份、别名、真实目录及自有预约绑定。旧 CLI 和旧 Hub 不会自动获得这些保护；注册表为空不能替代真实进程检查。

参与时段使用 IANA 命名时区、ISO 星期和半开区间。跨午夜归属开始日期；空的允许时段不放行，缺失字段或无效规则不放行。整项策略不存在时保留旧账号“不限时”的行为。Swift 编辑器、Python 预检和 Hub 门禁分别验证；Hub 的保护需要部署相应源码。

Next 的界面轮询约 10 秒，其他调用者可直接读取刚写入的预约。请求成功、退出码 0、通过预检、产物验收和用户收到通知是不同证据。

[README](../README.md) · [详细使用说明](usage-guide.md)
