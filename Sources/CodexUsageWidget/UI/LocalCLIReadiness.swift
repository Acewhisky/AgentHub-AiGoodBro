import SwiftUI

/// Presentation mapping only. Availability is never treated as a dispatch preflight.
enum LocalCLIReadiness: Equatable {
    case notInstalled, needsLogin, unknown, quotaDisconnected, available, stale, readFailed, rateLimited
    case inputFailure(String)
    case endedReservation, taskFailed

    static func resolve(installed: Bool, result: LocalCLIQuotaResult?, stale: Bool = false) -> Self {
        guard installed else { return .notInstalled }
        switch result?.messageCode {
        case "capability_report_unavailable", "capability_report_invalid", "invocation_file_unavailable":
            return .inputFailure(result?.messageCode ?? "")
        case "preparing_reservation_required": return .endedReservation
        case "task_failed", "runner_failed": return .taskFailed
        default: break
        }
        guard let result else { return .unknown }
        if result.state == .needsLogin { return .needsLogin }
        if stale { return .stale }
        if result.state == .unavailable { return .readFailed }
        if result.state == .rateLimited { return .rateLimited }
        if result.state == .available { return result.windows.isEmpty && result.balance == nil ? .quotaDisconnected : .available }
        return result.maskedIdentity == nil ? .unknown : .quotaDisconnected
    }

    func title(_ language: WidgetLanguage) -> String {
        switch self {
        case .notInstalled: language.text("未安装官方工具", "Official tool not installed")
        case .needsLogin: language.text("等待登录", "Sign-in needed")
        case .unknown: language.text("额度未接通 · 登录待确认", "Limits disconnected · Check sign-in")
        case .quotaDisconnected: language.text("额度未接通", "Limits disconnected")
        case .stale: language.text("上次快照 · 请刷新", "Previous snapshot · Refresh")
        case .readFailed: language.text("额度读取失败", "Quota read failed")
        case .rateLimited: language.text("服务商暂时限流", "Provider rate limited")
        case .available: language.text("额度已接通", "Limits connected")
        case .inputFailure: language.text("准备不完整，可重试", "Preparation incomplete · Retry")
        case .endedReservation: language.text("预约已结束", "Reservation ended")
        case .taskFailed: language.text("任务失败", "Task failed")
        }
    }

    func detail(_ language: WidgetLanguage) -> String {
        switch self {
        case .inputFailure(let code):
            switch code {
            case "capability_report_unavailable":
                language.text(
                    "能力报告文件不存在或不可读。补文件后先核对运行器版本与预约状态；只有预约仍有效时才能直接重试。",
                    "Capability report is missing or unreadable. Restore the file, then check runner version and reservation state; retry only if the reservation is still valid.")
            case "capability_report_invalid":
                language.text(
                    "能力报告不是可用的 JSON。修正后核对预约状态；已结束的预约需重新创建。",
                    "The capability report is not valid JSON. Correct it and check reservation state; ended reservations must be recreated.")
            default: language.text("任务说明文件不可读，请检查文件的绝对路径。", "The task brief is unreadable. Check its absolute path.")
            }
        case .endedReservation: language.text("这次预约已经结束，需要重新预约。", "This reservation has ended. Create a new reservation.")
        case .taskFailed: language.text("任务启动后失败，请查看调用回执；继续调用前检查预约状态。", "The task failed after starting. Review its receipt and reservation state before continuing.")
        case .notInstalled: language.text("从官方说明完成安装后重新检测。", "Install using the official guide, then scan again.")
        case .needsLogin: language.text("点击登录打开现有官方登录流程。", "Choose Sign in to open the existing official flow.")
        case .available: language.text("额度来自当前快照；参与调度仍需检查依赖、能力报告与占用。", "Limits reflect the current snapshot. Dispatch still requires dependency, capability and occupancy checks.")
        case .stale: language.text("当前显示历史快照，不能当作实时额度；刷新后核对。", "This is a previous snapshot, not live quota. Refresh to check.")
        case .readFailed: language.text("本次没有读到额度。保留已有快照，不代表余额为零。", "This quota read failed. Existing snapshots are preserved; this does not mean zero balance.")
        case .rateLimited: language.text("请稍后刷新；无需因为限流重新登录。", "Refresh later; rate limiting does not require signing in again.")
        case .unknown, .quotaDisconnected: language.text("尚无可用额度数据，刷新后核对。未知额度不会记为 0。", "No quota evidence yet. Refresh to check; unknown is never zero.")
        }
    }

    var isFailure: Bool {
        switch self {
        case .inputFailure, .endedReservation, .taskFailed: true
        default: false
        }
    }
    var color: Color { isFailure ? FixedVisualPalette.statusWarning : self == .available ? FixedVisualPalette.statusSuccess : .secondary }
    var symbol: String { isFailure ? "exclamationmark.circle" : self == .available ? "checkmark.circle" : "circle.dotted" }
}
