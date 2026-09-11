# 逐模型可用性与 free 来源日期 · 0911v7 / 0911v11 收尾

相较此前额度/账号适配：受管派单只认**同一个模型**在**当前环境**、**当前匿名账号指纹**下、且仍在时效内的最小返回证据。一个模型通过不能写成整个 CLI 可用。打开、登录等既有入口保持原样。

0911v7 新增模块文件；0911v11 只收尾文案、无效回执保原文件、C 回执归一化桥和父任务接线包，不重做 v7 行为边界。

本模块文件：

- `Sources/CodexUsageWidget/Domain/LocalCLIModelAvailability.swift`
- `Sources/CodexUsageWidget/Domain/LocalCLIModelReceiptBridge.swift`（0911v11）
- `Sources/CodexUsageWidget/Services/LocalCLIModelAvailabilityStore.swift`
- `Sources/CodexUsageWidget/UI/LocalCLIModelAvailabilityView.swift`
- `tests/LocalCLIModelAvailabilityFixture.swift`
- `tests/test_local_cli_model_availability.py`

未改 `LocalCLIAccount`、已有 Store、`LocalCLIWorkspaceView`、renderer、`agent-cli` 脚本。跨归属文件只给建议，不在本树应用。

## 证据合同

每条模型证据包含：`provider`、`modelID`、`requestedModel`、`observedActualModel`、CLI 版本、可执行文件 SHA-256、非敏感环境指纹、同账号匿名指纹、最小返回 `matched` / `toolCalls=0` / `exitCode`、`testedAt`、`validUntil`、状态 `untested` / `passed` / `invalid`。

派单判定 `LocalCLIModelDispatch.allows`：

1. 隔离根上的 JSON 通过版本与内容校验（或文件不存在，视为全部未测试）
2. 绑定的 provider + modelID 精确匹配，且该模型对本 provider 是已承认 ID
3. 账号指纹与环境指纹与当前绑定一致
4. `testedAt` 不在未来（允许 300 秒钟差）
5. `now <= validUntil`
6. 最小返回成立，且记录状态解析后仍为 `passed`

缺文件、错身份、错模型、过期、未来测试时间、最小返回失败都不得派单。Grok 只承认精确 `grok-4.6-build`。C 0911v8 仓内没有 `grok-4.6` → `grok-4.6-build` 的官方入口映射，本模块不自造该别名、不做前缀通配；`grok-4.5` 未验，继续不可用。

## free 是独立事实

来源只能是 `official` 或 `userConfirmed`。缺少 `source` 的记录整条拒绝。`sourceURL` 可选，且仅允许已登记的公开支持站（`https://zcode.z.ai`、`opencode.ai`、`docs.opencode.ai`）。`confirmedOn` 必须是日期。`startsOn` / `endsOn` 未提供则界面显示「未注明」，不写永久、不写未知。有民事时刻但原文未给时区时，保留原起止并标注「时区未注明」。过期只影响 free 窗口文案，不改写模型测试状态。free 目录不是登录/订阅恢复，也不是逐模型可用证据。

已记录、**不是派单授权、不含私人额度**的公开目录：

| CLI | 原文 label / 模型 ID | 来源 | 确认日 | 截止 |
|---|---|---|---|---|
| WorkBuddy | DeepSeek 4 Flash → `deepseek-v4.1-flash`；HY4 → `hy4-preview-f`；HY3 → `hy3`（该顺序） | 用户确认 | 2026-09-11 | 未注明 |
| OpenCode | `mimo-v2.5-free`（官方 modelId 含 free；native 标价全 0 的证据日期同确认日） | 官方 | 2026-09-11 | 未注明 |
| ZCode | GLM-5.3/Flash（`glm-5.3` / `glm-5.3-flash`） | 官方 | 2026-09-11 | 2026-09-15 23:59（原文未给时区，按民事时刻保存，界面标注时区未注明） |

ZCode 官方试用窗口在 2026-09-11 仍未到截止日，但当日刷新耗尽属于私人账号额度，**不写入公共 fixture 或默认种子**。没有逐模型通过证据时，目录行显示「不可用于受管派单」。

## 存储（实际代码，纠正 v7 报告）

`LocalCLIModelAvailabilityStore.load(root:now:binding:)` 只读调用方给出的隔离目录下 `model-availability-v1.json`。目录或文件为 symlink、超过 64 KiB、`version != 1`、含 token/cookie/email 等键、指纹写成邮箱（含 `example.invalid`）、缺 source 时：**运行状态失败关闭**（`origin == .rejected`，内存证据为空，不得派单），**不删除、截断或覆盖原文件**。v7 报告写「清空磁盘证据」与代码不一致，以本段为准。

不访问网络、钥匙串、进程环境或凭据文件。`now` 与当前绑定由调用方注入；绑定不在读取时过滤，只在派单与展示时使用。

公共测试只用虚构 `example.invalid` 与 `synthetic-*` 指纹。

## 回执归一化桥（0911v11）

`LocalCLIModelReceiptBridge` 只离线消费 C `grok-entry-c` 脱敏最小回执字段，不读认证、不启动 provider。任意手填 JSON 不能变成可信通过。

父任务必须注入当前绑定和**本次运行**的精确随机标记。回执缺字段 → `untested`；字段在但与当前绑定/标记不一致 → `invalid`。两种结果都不得派单，也不得改回执文件。

C 最小回执实际字段（只读对照 `scripts/agent_cli_grok.py` `_load_min_return_record` / `tests/test_agent_cli_grok.py`）：

| C 回执 | 本模块 |
|---|---|
| `schemaVersion==1` | 缺则未验证，错则 invalid |
| `product` | 映射为 `LocalCLIKind`（`grok`/`workbuddy`/…） |
| `requestedModel` / `actualModel` | 必须同时存在且精确相等；Grok 仅 `grok-4.6-build` 可承认 |
| `accountKey` | 匿名账号指纹，须等于当前绑定 |
| `environmentKey` | 隔离环境指纹，须等于当前绑定 |
| `executableSHA256` | 环境可执行摘要，补 `sha256:` 后须等于当前绑定 |
| `cliVersion` | 若绑定提供版本则须一致 |
| `isolatedEnvironment==true` | 缺则未验证，false 则 invalid |
| `toolsDisabled==true` 或 `toolCalls==0` | 零工具；缺两者则未验证 |
| `exitCode==0` | 非零 invalid |
| `outputMatched==true` | 对应 `matched` |
| `capturedAt` | `testedAt`；超 86400s 或未来则 invalid |
| **`randomMarker`（本模块要求）** | 必须与父任务注入的精确随机标记一致；缺则未验证 |

C 现有最小回执**没有** `randomMarker`。没有该字段的文件保持未验证，不能靠手填 `status: passed` 过关。

## 界面

`LocalCLIModelAvailabilityView` 是供应商详情页用的小型折叠列表，文案走现有 `WidgetLanguage`（中/英）。每行展示模型 ID、free 原词（含官方 id 里的 free）、来源类型、来源链接（若有）、确认日、已知起始、已知截止或「未注明」、民事时刻的「时区未注明」、测试时间与状态、是否可用于受管派单。

## 父任务精确接线包

证据根必须是 Next 自己的隔离目录，不要指向 CLI home、Keychain 或认证文件。本模块不计算可执行哈希、不读二进制、不启动 provider。

### 最小可编译调用点（本模块已提供的类型）

```swift
let supportRoot = /* Next Application Support isolation, not CLI home */
let evidenceRoot = supportRoot.appendingPathComponent("local-cli-model-availability", isDirectory: true)
let binding = LocalCLICurrentBinding(
    provider: kind,
    modelID: requestedModel,
    environmentFingerprint: currentEnvFingerprint,
    accountFingerprint: currentAccountFingerprint,
    cliVersion: installedVersion,
    executableHash: installedHash
)
let snapshot = LocalCLIModelAvailabilityStore.load(
    root: evidenceRoot,
    now: Date(),
    binding: binding
)
LocalCLIModelAvailabilityView(
    snapshot: snapshot,
    language: language,
    provider: kind,
    binding: binding
)
if LocalCLIModelDispatch.allows(snapshot: snapshot, binding: binding, now: Date()) {
    // only this admitted model, in this environment, on this account fingerprint
}

let receiptOutcome = LocalCLIModelReceiptBridge.normalize(
    data: receiptData,
    expectation: LocalCLIModelReceiptBridge.Expectation(
        provider: kind,
        modelID: requestedModel,
        environmentFingerprint: currentEnvFingerprint,
        accountFingerprint: currentAccountFingerprint,
        executableHash: installedHash,
        randomMarker: exactRunMarker,
        now: Date(),
        cliVersion: installedVersion
    )
)
```

Grok 绑定的 `modelID` 必须是 `grok-4.6-build`。把请求写成 `grok-4.6` 不会被映射，派单保持未测试。

### 跨归属差异建议（不在本树应用）

1. **E / `LocalCLIWorkspaceView`**：在供应商详情、账号卡片下方嵌入 `LocalCLIModelAvailabilityView`。不要把 free 目录行当成可派单。已有折叠列表即可，不必另建抽象。
2. **C / `agent-cli` Grok 入口**：生产 run 仍因额度桥缺失 fail-closed。本桥不替代 `agent_cli_grok_bridge.PRODUCTION_READY`。若以后要承认 `grok-4.6` 请求名，须先有官方入口把它映射到 `grok-4.6-build` 的证据；本模块不会先做通配。
3. **F / `LocalCLIQuotaReader`**：额度与 free 截止、逐模型测试是三件事实。不要用额度剩余或 free 窗口回写本模块证据。
4. 可执行 SHA-256 由父任务对已安装常规文件计算后传入；与 C 回执 `executableSHA256`（无前缀）对齐时补 `sha256:`。

```sh
python3 -m unittest tests.test_local_cli_model_availability
```

离线 fixture 覆盖错身份、错模型、过期、未来测试时间、无结束日（未注明）、free 已过期、来源缺失、symlink、超限、邮箱指纹、非公开 URL、拒绝后原文件保留、Grok 别名不映射、回执缺标记/错标记。未调用真实模型、登录、切号或账号额度接口。
