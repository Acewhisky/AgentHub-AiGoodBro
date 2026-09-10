# Telegram 与企业微信 · 0911v2

相较 0911v1：已接入自动化中心、Next 独立 Keychain 存储及 UsageStore 实际事件来源；补齐配置变化失效、并发去重、严格响应校验与控制器回归。

在自动化中心打开“Telegram 与企业微信”，分别开启通道、填写配置并保存。Telegram 使用 Bot token 和目标 chat ID；企业微信使用群机器人 webhook key。输入采用安全字段，保存后清空草稿。只有 API 实际接受消息才显示已验证，重启或修改配置后重新验证。

两个通道默认关闭。后台凭据读取不请求系统弹窗，限两项在途并设置超时；只有用户点击保存时才允许系统授权。凭据和目标在 Next 自己的 Keychain 条目中，不写 UserDefaults、日志或公开回执。

现有额度变化、切换结果和观察确认的 Codex 完成事件通过结构化 DTO 发送。完成事件要求同一连接先运行、后完成；启用某通道前的状态不能借用另一通道的基线。飞书与这两个通道分别开关。各通道最多四项在途，去重缓存有界；停用、停止或修改配置后忽略迟到回调。

网络只使用官方 HTTPS host/path，禁重定向、缓存与 Cookie，12秒请求/20秒资源超时，响应流最多64 KiB。Telegram 的 ok 必须为布尔 true，WeCom errcode 必须为整数0；布尔或小数不能冒充成功。服务端错误文本丢弃，仅显示固定原因和安全数字。API 接收不等于人已收到。

| 微信入口 | 支持范围 |
| --- | --- |
| 企业微信群机器人 | 已实现官方 webhook 适配，可配置和测试 |
| 个人微信 | 当前应用没有可用的官方适配 |
| 公众号 | 当前应用没有服务端适配 |

协议来源：[Telegram Bot API](https://core.telegram.org/bots/api#sendmessage)、[企业微信群机器人](https://developer.work.weixin.qq.com/document/path/91770)。没有引入第三方 SDK 或非官方个人微信登录。

```sh
python3 scripts/test-message-channels.py
bash scripts/run-self-tests.sh --skip-build --only feishu-webhook
```

离线测试覆盖非法配置、超时、失败、响应类型、敏感错误清理、取消、重复请求和目标变化。控制器测试使用延迟返回的假存储和传输，覆盖默认关闭零 I/O、保存与启停竞态、两通道独立完成事件、容量上限及持久化开关。没有写真实 Keychain、发送真实消息或验证用户收件。
