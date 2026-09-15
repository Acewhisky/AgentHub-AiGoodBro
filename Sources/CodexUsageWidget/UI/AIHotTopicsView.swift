import SwiftUI

struct AIHotTopicsView: View {
    let language: WidgetLanguage
    @ObservedObject private var model = AIHotTopicsStore.shared
    @Environment(\.workspaceTrendScreenshots) private var screenshots

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(language.text("AI 热点", "AI hot topics"), systemImage: "flame")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 4)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise").font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.isLoading || context.date < model.nextRefreshAt)
                    .accessibilityLabel(language.text("刷新热点", "Refresh hot topics"))
                    .help(language.text("按来源缓存间隔更新，最短 5 分钟", "Updates follow the source cache interval, at least 5 minutes"))
                }
            }
            if model.items.isEmpty {
                Text(
                    model.isLoading
                        ? language.text("正在获取热点…", "Loading hot topics…")
                        : model.failed
                            ? language.text("热点暂时无法加载", "Hot topics are unavailable")
                            : language.text("暂时没有热点", "No hot topics right now")
                )
                .font(.caption).foregroundStyle(.secondary)
                .padding(.vertical, 12)
            }
            ForEach(model.items.prefix(4)) { item in
                Link(destination: item.links.aihot) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(item.rank)").foregroundStyle(.tint).monospacedDigit()
                            Text(verbatim: item.title).foregroundStyle(.primary).lineLimit(2)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                        }
                        .font(.caption.weight(.medium))
                        Text(
                            language.text("\(item.sourceCount) 个来源 · ", "\(item.sourceCount) sources · ")
                                + PublicResetAnnouncementPresentation.compactEventTime(item.latestAt, language: language)
                        )
                        .font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
                Divider()
            }
            HStack(alignment: .top) {
                Text(
                    model.failed && !model.items.isEmpty
                        ? language.text("更新失败 · 显示上次热点", "Update failed · Previous topics")
                        : language.text("来源：AIHOT", "Source: AIHOT")
                )
                .font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Link(language.text("更多热点", "More topics"), destination: AIHotTopicsClient.siteURL).font(.caption2)
            }
        }
        .task {
            guard screenshots == nil else { return }
            while !Task.isCancelled {
                await model.refresh()
                do { try await Task.sleep(nanoseconds: 300_000_000_000) } catch { return }
            }
        }
    }
}
