# 开源复用与备选方案 · 0912v1

核对日期：2026-09-12。目标是稳定接收额度消息、准确统计和可恢复的账号操作。优先修已有原生实现，保留独立 CLI 代理作为后续备选；本次没有安装额外代理、导入凭据或改变 Codex 配置。

## 判断

**codex-switcher 有可借鉴实现，目前不能据此判断整体替换会更稳定。** 它覆盖 HTTP/SSE/WebSocket 代理与请求重试，解决的范围比 AiGoodBro 当前的账号事务更广；同时增加代理、账号存储和 token 刷新参与者。与现有账号管理器共用登录状态前，必须验证单一凭据写入者、任务连续性、失败恢复与日志边界。

| 项目 | star（核对当日）与维护 | 可复用部分 | 本轮决定 |
|---|---|---|---|
| [VallierDev/codex-switcher](https://github.com/VallierDev/codex-switcher) | 80；9/11 发布 v0.7.15；MIT | 代理错误分类、有限重试、会话与账号绑定、切换原因记录 | 保留为独立 CLI 代理备选；借鉴方法，不接管现有 Desktop 登录 |
| [farion1231/cc-switch](https://github.com/farion1231/cc-switch) | 132,466；9/11 有推送；MIT | 已在本机使用的用量数据库与跨工具记录 | 继续使用现有数据源，修复读取器版本/结构兼容与日期聚合；避免再安装一份同类工具 |
| [router-for-me/CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) | 51,520；9/12 有推送；MIT | 独立代理服务候选 | 作为第二代理备选；本轮只核对仓库/许可，未完成源码稳定性或运行验收 |
| [caronc/apprise](https://github.com/caronc/apprise) | 17,304；9/12 有推送；BSD-2-Clause | 飞书与企业微信接口适配参考 | 保留现有原生通道；接入整套 Python 通知框架不能替代业务事件接线和投递回执 |

star 和近期推送是背景信息，不能证明投递成功、数据正确或客户端任务不中断。根 LICENSE 均已读取；若以后复制实现，需要随代码/分发保留相应版权和许可声明。

## 已读源码与适配边界

- codex-switcher 固定在 [f64a44a](https://github.com/VallierDev/codex-switcher/tree/f64a44a81b9ae8354d76bcdff0e77ab23c8790e1)。[proxy.rs](https://github.com/VallierDev/codex-switcher/blob/f64a44a81b9ae8354d76bcdff0e77ab23c8790e1/src-tauri/src/proxy.rs) 的 `read_sse_bootstrap`、`try_switch_and_retry` 区分账号限额与全局容量，约束重试次数；这是可借鉴的故障分类方法。请求已经产生内容或工具副作用后，不应仅因连接断开就声称可安全重放。
- [account.rs](https://github.com/VallierDev/codex-switcher/blob/f64a44a81b9ae8354d76bcdff0e77ab23c8790e1/src-tauri/src/account.rs) 的 `write_codex_auth` 会写 Codex 登录状态。直接接入会改变现有身份写入边界，不能仅增加一个菜单按钮就当完成集成。
- [switch_log.rs](https://github.com/VallierDev/codex-switcher/blob/f64a44a81b9ae8354d76bcdff0e77ab23c8790e1/src-tauri/src/switch_log.rs) 有明确的切换原因枚举，可对照现有审计日志；[quota_snapshot.rs](https://github.com/VallierDev/codex-switcher/blob/f64a44a81b9ae8354d76bcdff0e77ab23c8790e1/src-tauri/src/quota_snapshot.rs) 把 email 放入快照，不能直接沿用到 AiGoodBro 的脱敏调用日志。
- Apprise 固定在 [bb6cc9c](https://github.com/caronc/apprise/tree/bb6cc9c163771dd8a7356d6e3e0e32eea2e1cc6b)。其 [Feishu](https://github.com/caronc/apprise/blob/bb6cc9c163771dd8a7356d6e3e0e32eea2e1cc6b/apprise/plugins/feishu.py) 与 [WeCom Bot](https://github.com/caronc/apprise/blob/bb6cc9c163771dd8a7356d6e3e0e32eea2e1cc6b/apprise/plugins/wecombot.py) 在已读 `send` 路径按 HTTP 状态判断成功，未再校验 JSON 业务错误码；WeCom 调试日志还包含完整 API URL。因此本轮保留 AiGoodBro 的业务错误码检查、固定主机/路径、禁重定向及凭据脱敏，不能为了高 star 退回较弱判断。

以上属于源码审查，不是对这些产品整体质量或真实稳定性的评级。本轮只保存来源与适配结论，没有把这些源文件加入应用二进制。

## 备选方案的最小验收

如主路径修复后仍需代理备选，先只接一个独立测试 CLI，保持 Desktop 登录和现有账号存储不变。只监听本机，使用单独配置与可停止进程，并验证：正常请求、额度不足、全局容量、连接中断、已经输出内容的失败、重复工具调用防护、恢复原路径及日志无凭据。完成后才决定是否把代理做成可选执行后端。

当前 resets 消息问题优先通过公开事件模型、主线程发布、通道分别去重、失败可见和来源链接解决。换账号代理本身不会修好这些通知问题。
