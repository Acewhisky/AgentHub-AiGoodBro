# Codex Account Manager Next v9.5.5

Release name: 0907v1

源码版本：9.5.5 (17)。上一版：0905v4 / 9.5.4 (16)。本次仅推送源码，不创建 GitHub Release 或发布安装包。

## Highlights

- 主窗口和账号卡更紧凑：默认窗口调整为 980 × 700，保留现有功能的大致位置，将账号身份、额度与操作分组对齐；窄窗自动换行，长备注可省略。
- 右上角新增原生长截图按钮：导出当前展开状态下的完整工作台 PNG，包括滚动区之外的账号；不截其他窗口、不上传。九账号、三种宽度及浅深色均有合成回归覆盖，超出安全尺寸时拒绝导出，不静默裁切。
- 修复额度快照乱序：旧响应不能覆盖新状态；相同时间戳只补全字段，成功优先于失败，避免额度与 Reset 历史回退或重复累计。
- 强化调度设置同步：写入前核对当前身份、新鲜成功快照与同账号镜像一致性；三份配置先校验、备份，再逐个原子替换并检查竞争写入。未知或无法读取的恢复数据保留，不静默删除。
- 保留 0905v4 的重置后暖号、默认关闭的飞书额度恢复与 Reset 卡增加提醒，以及周额度临近重置提醒；官方额度桶标识缺失时只建立基线，不误发新事件。

## Validation

2026-09-07 完成最终源码复验，构建内版本已核实为 0907v1 / 9.5.5 (17)：

- `make lint`、`make memory-risk-check`：PASS；全局内存风险清单已逐类复核。
- `make build`：macOS arm64、`-O -j 2` 优化构建 PASS，ad-hoc codesign 与严格签名完整性检查 PASS。
- `make verify-runtime-resources`：5/5 PNG 资源一致。
- `scripts/run-self-tests.sh --skip-build --build-dir <isolated-build>`：在图形宿主执行 26/26 组 PASS，包含快照乱序与镜像身份校验、暖号/飞书纯策略，以及九账号长截图。
- `python3 scripts/test-dispatch-participation.py --tests-only`：69/69 PASS，包含身份不符、镜像冲突、校验失败零写入、竞争写入与恢复数据保护。
- `plutil -lint Resources/Info.plist`、`git diff --check`：PASS。

池账号实现与独立对抗审查后，由主线程再次复核补丁并执行上述最终版本验收。没有用较早候选构建的结果替代最终构建测试。

已验收的候选 UI：九账号浅深色 PNG 均为 1960 × 4736，第九账号及底部内容完整；820 宽窄窗与右上角工具条已目视检查。全部为隔离的合成数据，未使用真实账号。

截图生命周期探针：生产 exporter 连续导出 25 次九行合成内容，注册窗口数未累积；第 5–25 次 RSS 约 45 MiB，峰值 RSS 约 88 MiB。该探针不代表完整工作台或最大允许图片的峰值内存。

## Runtime acceptance boundaries

- 未安装或替换正在运行的 Next；未启动真实工作台、登录、切号、暖号、兑换 Reset 卡或发送真实飞书通知。
- 未修改或重启 Hub。参与调度写入的是配置，Hub 重新加载后才采用；当前 Hub 尚不消费 `prioritizeDispatch`，打开“优先派活”不会改变 Hub 选号顺序。
- 完整图像渲染和保存/取消/错误分支使用合成数据验收；未实际点按 NSSavePanel，也未操作真实九账号。
- 单文件替换具有原子性；不共同遵循 Next 锁的外部写入者仍只能尽力检测。三份配置不是断电级原子事务，恢复备份和未知内容不会自动清理。
- 保留原有身份隔离、手动切换、Hub 占用和未知状态拒绝操作的保护。不能把源码测试当成真实服务已生效。

## Assets and checksums

本次没有打包或上传 macOS DMG、Windows 安装器，因此没有安装包 SHA-256。GitHub Release、标签与二进制发布不在本次操作范围内。

本地验收使用 macOS arm64 优化构建与 ad-hoc 签名；没有执行 Apple notarization，也没有本地 Windows 运行验收。
