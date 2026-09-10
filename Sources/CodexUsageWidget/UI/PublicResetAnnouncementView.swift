import SwiftUI

struct PublicResetAnnouncementView: View {
    @Environment(\.widgetLanguage) private var language
    @ObservedObject var monitor: PublicResetAnnouncementMonitor
    let paused: Bool
    var deliveryDetailsOnly = false
    @State private var isResolvingDelivery = false
    @State private var resolvingID = ""
    @State private var isEstablishingBaseline = false
    @State private var isEstablishingLocalBaseline = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !deliveryDetailsOnly {
                Toggle(
                    language.text("接收重置消息", "Receive reset updates"),
                    isOn: Binding(get: { monitor.enabled }, set: { monitor.setEnabled($0) })
                )
                .toggleStyle(.switch)
                .disabled(paused)
                Text(
                    language.text(
                        "默认开启。有新消息时自动提醒，不消耗账号额度。",
                        "On by default. New updates are checked automatically and use no account quota."
                    )
                )
                .font(.caption).foregroundStyle(.secondary)
                if let announcement = monitor.latest {
                    Text(announcement.title(language)).font(.caption.weight(.semibold))
                    Text(language.dateTime(announcement.announcedAt)).font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup(language.text("查看消息", "Read update")) {
                        Text(announcement.summary(language)).font(.caption).foregroundStyle(.secondary)
                        Text(announcement.text).font(.caption).textSelection(.enabled)
                        Text(language.text("公开消息由第三方汇总；账号实际额度以官方刷新为准。", "Public updates are collected by a third party. Official account data confirms your limits."))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button(monitor.checking ? language.text("更新中…", "Checking…") : language.text("刷新", "Refresh")) { monitor.check() }
                        .disabled(monitor.checking)
                    Link(language.text("来源与历史", "Source and history"), destination: PublicResetClient.siteURL)
                    if let checkedAt = monitor.checkedAt {
                        Text(language.dateTime(checkedAt)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if let status = monitor.localStatus ?? monitor.status { Text(status).font(.caption).foregroundStyle(.secondary) }
                if monitor.needsLocalBaseline {
                    Button(language.text("从当前消息继续接收", "Resume from current updates")) { isEstablishingLocalBaseline = true }
                        .disabled(monitor.checking || !monitor.enabled)
                }
            } else {
                if monitor.missingDeliveryCount > 0 {
                    Text(
                        language.text(
                            "有 \(monitor.missingDeliveryCount) 条旧记录需要恢复，已保存的完整消息会继续处理。",
                            "Recovering \(monitor.missingDeliveryCount) older records. Complete saved updates continue to be processed.")
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                if monitor.needsNewBaseline {
                    Button(language.text("重新建立公告基线", "Establish a new baseline")) { isEstablishingBaseline = true }
                        .disabled(monitor.checking || !monitor.enabled)
                }
                ForEach(monitor.uncertainDeliveryIDs, id: \.self) { id in
                    Button(language.text("核实待确认推送：", "Verify delivery: ") + id) {
                        resolvingID = id
                        isResolvingDelivery = true
                    }
                    .disabled(monitor.checking)
                }
            }
        }
        .alert(language.text("请先核对飞书中的重置公告", "Check the reset announcement in Feishu first"), isPresented: $isResolvingDelivery) {
            Button(language.text("已收到", "Received")) { monitor.resolveUncertainDelivery(id: resolvingID, received: true) }
            Button(language.text("未收到，允许重试", "Not received; allow retry")) { monitor.resolveUncertainDelivery(id: resolvingID, received: false) }
            Button(language.text("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(
                language.text(
                    "公告 ID：\(resolvingID)。只有确认未收到时才允许重试；重试可能造成重复消息。", "Announcement ID: \(resolvingID). Allow retry only if it did not arrive. Retrying can produce a duplicate."))
        }
        .alert(language.text("从当前公告重新开始跟踪？", "Track announcements from the current page?"), isPresented: $isEstablishingBaseline) {
            Button(language.text("建立基线", "Establish baseline")) { monitor.establishNewBaseline() }
            Button(language.text("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(
                language.text(
                    "保留已保存的待发与待核实公告；当前页其余历史消息不补发。", "Saved pending and uncertain deliveries are preserved. Other historical announcements on the current page will not be sent."))
        }
        .alert(language.text("从当前消息继续接收？", "Resume from current updates?"), isPresented: $isEstablishingLocalBaseline) {
            Button(language.text("继续接收", "Resume updates")) { monitor.establishNewBaseline(local: true) }
            Button(language.text("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(
                language.text(
                    "保留已保存的待发与待核实消息。当前历史仅作为起点，不补发；之后的新消息恢复提醒。",
                    "Saved pending and uncertain updates are preserved. Current history becomes the baseline without being resent; future updates resume notifications."))
        }
    }
}
