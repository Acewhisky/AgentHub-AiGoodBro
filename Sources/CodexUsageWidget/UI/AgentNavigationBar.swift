import SwiftUI

struct AgentNavigationBar: View {
    @Binding var navigation: AgentNavigationState
    let language: WidgetLanguage
    let detectedIDs: [String]
    let selectedID: String?
    let showingHome: Bool
    let existingUser: Bool
    var onSelectHome: () -> Void
    var onSelect: (String) -> Void
    var onRefresh: () -> Void
    var showsGettingStarted: Bool
    var onGettingStarted: () -> Void

    @State private var isAdding = false
    @State private var isManaging = false
    @State private var manageDraft: AgentNavigationState?
    @State private var undoIDs: [String]?
    @State private var availableWidth: CGFloat = 980

    var body: some View {
        let visible = navigation.renderableIDs()
        let overflow = AgentNavigationOverflow.layout(
            orderedIDs: visible,
            availableWidth: Double(availableWidth)
        )
        HStack(spacing: 6) {
            navButton(
                id: AgentNavCatalog.homeID,
                title: language.text("主页", "Home"),
                selected: showingHome,
                systemImage: "house",
                action: onSelectHome
            )
            ForEach(overflow.visibleIDs, id: \.self) { id in
                agentButton(id: id, selected: !showingHome && selectedID == id)
            }
            if overflow.showsMore {
                Menu {
                    ForEach(overflow.overflowIDs, id: \.self) { id in
                        Button(AgentNavCatalog.displayName(id)) { onSelect(id) }
                    }
                } label: {
                    let title =
                        overflow.overflowIDs.contains(selectedID ?? "") && !showingHome
                        ? AgentNavCatalog.displayName(selectedID ?? "")
                        : language.text("更多", "More")
                    Label(title, systemImage: "ellipsis")
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(!showingHome && overflow.overflowIDs.contains(selectedID ?? "") ? Color.accentColor.opacity(0.12) : .clear, in: Capsule())
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel(language.text("更多 Agent", "More agents"))
            }
            Spacer(minLength: 8)
            Button {
                isAdding = true
            } label: {
                Label(language.text("添加 Agent", "Add Agent"), systemImage: "plus")
                    .padding(.horizontal, 10).padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(language.text("添加 Agent", "Add Agent"))
            Button {
                manageDraft = navigation
                isManaging = true
            } label: {
                Text(language.text("管理", "Manage")).padding(.horizontal, 10).padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless).padding(.horizontal, 6).padding(.vertical, 8)
            .help(language.text("重新检测本机 CLI", "Scan installed CLIs"))
            if showsGettingStarted {
                Button(language.text("使用引导", "Getting started"), action: onGettingStarted)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .background(widthReader)
        .frame(minHeight: 40)
        .onAppear {
            navigation.bootstrapIfNeeded(existingUser: existingUser, currentVisible: defaultVisible)
        }
        .sheet(isPresented: $isAdding) { addSheet }
        .sheet(isPresented: $isManaging) { manageSheet }
        .overlay(alignment: .topTrailing) {
            if undoIDs != nil {
                Button(language.text("撤销移除", "Undo remove")) {
                    if let undoIDs { navigation.orderedVisibleProviderIDs = undoIDs }
                    self.undoIDs = nil
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, 36)
            }
        }
    }

    private var defaultVisible: [String] {
        [AgentNavCatalog.codexID] + detectedIDs.filter { $0 != AgentNavCatalog.codexID }
    }

    private func agentButton(id: String, selected: Bool) -> some View {
        navButton(
            id: id,
            title: AgentNavCatalog.displayName(id),
            selected: selected,
            providerID: id,
            action: { onSelect(id) }
        )
        .contextMenu {
            Button(language.text("从导航移除", "Remove from navigation")) { remove(id) }
            Button(language.text("左移", "Move left")) { navigation.move(id, by: -1) }
            Button(language.text("右移", "Move right")) { navigation.move(id, by: 1) }
        }
    }

    private func navButton(
        id: String,
        title: String,
        selected: Bool,
        providerID: String? = nil,
        systemImage: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: ProviderIconSlot.navigation.container, height: ProviderIconSlot.navigation.container)
                } else if let providerID {
                    ProviderMark(providerID: providerID, slot: .navigation)
                }
                Text(title).font(.callout.weight(.medium)).fixedSize()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(selected ? Color.accentColor.opacity(0.12) : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func remove(_ id: String) {
        undoIDs = navigation.orderedVisibleProviderIDs
        _ = navigation.remove(id)
        if selectedID == id { onSelectHome() }
    }

    private var widthReader: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: AgentNavigationWidthKey.self, value: proxy.size.width)
        }
        .onPreferenceChange(AgentNavigationWidthKey.self) { availableWidth = $0 }
    }

    private var addSheet: some View {
        let added = Set(navigation.orderedVisibleProviderIDs)
        return VStack(alignment: .leading, spacing: 16) {
            Text(language.text("添加 Agent", "Add Agent")).font(.headline)
            Text(language.text("只加入导航入口，不会安装、登录或发起调用。", "This only adds a navigation tab. It does not install, sign in or call a model."))
                .font(.caption).foregroundStyle(.secondary)
            Group {
                Text(language.text("已添加", "Added")).font(.subheadline.weight(.semibold))
                ForEach(navigation.renderableIDs(), id: \.self) { id in
                    catalogRow(id: id, added: true)
                }
                if navigation.renderableIDs().isEmpty {
                    Text(language.text("导航里还没有 Agent，主页和添加入口仍可用。", "No agents are in the navigation yet. Home and Add stay available."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            Text(language.text("可添加", "Available")).font(.subheadline.weight(.semibold))
            ForEach(AgentNavCatalog.workspaceProviders.filter { !added.contains($0.id) }) { provider in
                catalogRow(id: provider.id, added: false, detected: detectedIDs.contains(provider.id) || provider.id == AgentNavCatalog.codexID)
            }
            Divider()
            Text(language.text("尚未作为工作台 Agent 支持", "Not a workspace Agent yet")).font(.subheadline.weight(.semibold))
            ForEach(AgentNavCatalog.upcomingProviders) { provider in
                HStack {
                    ProviderMark(providerID: provider.id, slot: .navigation)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(provider.displayName)
                        Text(language.text("可在目录中查看，当前不能加入导航。", "Listed for reference and cannot be added yet."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Spacer()
                Button(language.text("完成", "Done")) { isAdding = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480, height: 560)
    }

    private func catalogRow(id: String, added: Bool, detected: Bool = false) -> some View {
        HStack(spacing: 10) {
            ProviderMark(providerID: id, slot: .navigation)
            VStack(alignment: .leading, spacing: 2) {
                Text(AgentNavCatalog.displayName(id))
                Text(
                    added
                        ? language.text("已在导航中", "Already in navigation")
                        : detected
                            ? language.text("已检测到 · 建议添加", "Detected · suggested")
                            : language.text("待配置", "Needs setup")
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if added {
                Button(language.text("移除", "Remove")) { remove(id) }
            } else {
                Button(language.text("添加到导航", "Add to navigation")) { _ = navigation.add(id) }
            }
        }
    }

    private var manageSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(language.text("管理导航", "Manage navigation")).font(.headline)
            Text(language.text("仅移除导航入口，账号与任务保留。", "Removing a tab only hides it. Accounts and tasks stay."))
                .font(.caption).foregroundStyle(.secondary)
            List {
                ForEach((manageDraft ?? navigation).renderableIDs(), id: \.self) { id in
                    HStack {
                        ProviderMark(providerID: id, slot: .navigation)
                        Text(AgentNavCatalog.displayName(id))
                        Spacer()
                        Button(language.text("上移", "Up")) { manageDraft?.move(id, by: -1) }
                        Button(language.text("下移", "Down")) { manageDraft?.move(id, by: 1) }
                        Button(language.text("移除", "Remove"), role: .destructive) { _ = manageDraft?.remove(id) }
                    }
                }
            }
            HStack {
                Button(language.text("恢复默认", "Restore default")) {
                    manageDraft?.restoreDefault(currentVisible: defaultVisible)
                }
                Spacer()
                Button(language.text("取消", "Cancel")) {
                    manageDraft = nil
                    isManaging = false
                }.keyboardShortcut(.cancelAction)
                Button(language.text("完成", "Done")) {
                    if let manageDraft { navigation = manageDraft }
                    isManaging = false
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520, height: 480)
        .onExitCommand {
            manageDraft = nil
            isManaging = false
        }
    }
}

private struct AgentNavigationWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 980
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
