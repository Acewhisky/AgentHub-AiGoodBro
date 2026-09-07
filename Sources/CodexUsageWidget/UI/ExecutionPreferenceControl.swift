import SwiftUI

/// Shared by the workspace, account rows and menu bar. Preferences are persisted by the caller.
struct ExecutionPreferenceControl: View {
    @Environment(\.widgetLanguage) private var language
    let preference: CodexExecutionPreference
    var allowsApplyToAll = true
    var expanded = false
    var compact = false
    var inlineEditor = false
    let onSave: (CodexExecutionPreference, Bool) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.visualTokens) private var visualTokens
    @State private var isPresented = false
    @State private var draft: CodexExecutionPreference

    init(
        preference: CodexExecutionPreference,
        allowsApplyToAll: Bool = true,
        expanded: Bool = false,
        compact: Bool = false,
        inlineEditor: Bool = false,
        onSave: @escaping (CodexExecutionPreference, Bool) -> Void
    ) {
        self.preference = preference
        self.allowsApplyToAll = allowsApplyToAll
        self.expanded = expanded
        self.compact = compact
        self.inlineEditor = inlineEditor
        self.onSave = onSave
        _draft = State(initialValue: preference)
    }

    var body: some View {
        Group {
            if inlineEditor {
                editor
            } else {
                selector
            }
        }
    }

    private var selector: some View {
        Button {
            draft = preference
            isPresented = true
        } label: {
            HStack(spacing: compact ? 6 : 10) {
                Image(systemName: preference.serviceTier == .fast ? "bolt.fill" : "bolt")
                    .font(.system(size: expanded ? 22 : 16, weight: .medium))
                    .foregroundStyle(executionGradient)
                    .accessibilityHidden(true)
                if compact {
                    Text(preference.model.displayName)
                        .font(.caption.weight(.semibold))
                    Text("\(preference.reasoningEffort.displayName) · \(speedTitle)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(preference.model.displayName)
                            .font(.system(size: expanded ? 19 : 13, weight: .semibold))
                        Text("\(preference.reasoningEffort.displayName) · \(speedTitle)")
                            .font(.system(size: expanded ? 12 : 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .foregroundStyle(.primary)
            .padding(.horizontal, compact ? 8 : expanded ? 18 : 12)
            .padding(.vertical, compact ? 4 : expanded ? 16 : 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(executionGradient.opacity(colorScheme == .dark ? 0.16 : 0.08), in: RoundedRectangle(cornerRadius: expanded ? 18 : 12))
            .overlay {
                RoundedRectangle(cornerRadius: expanded ? 18 : 12)
                    .strokeBorder(executionGradient.opacity(0.32), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(ExecutionPreferenceButtonStyle())
        .help(language.text("设置后续 CLI 与任务派单的模型、思考强度和速度", "Set the model, reasoning effort and speed for new CLI sessions and dispatched tasks."))
        .accessibilityLabel(language.text("任务模型", "Task model"))
        .accessibilityValue("\(preference.model.displayName)，\(preference.reasoningEffort.displayName)，\(speedTitle)")
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            editor
        }
        .onChange(of: preference) { draft = $0 }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(spacing: 18) {
                HStack(alignment: .top, spacing: 12) {
                    Button {
                        fastBinding.wrappedValue.toggle()
                    } label: {
                        Image(systemName: draft.serviceTier == .fast ? "bolt.fill" : "bolt")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(draft.serviceTier == .fast ? Color.accentColor : Color.secondary)
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!draft.model.supportsFast)
                    .help(language.text("切换标准 / Fast 速度", "Toggle Standard / Fast"))
                    .accessibilityLabel(language.text("Fast 速度", "Fast mode"))
                    .accessibilityValue(draft.serviceTier == .fast ? language.text("开启", "On") : language.text("关闭", "Off"))

                    VStack(spacing: 5) {
                        Menu {
                            Picker(language.text("思考强度", "Reasoning effort"), selection: effortBinding) {
                                ForEach(draft.model.supportedReasoningEfforts, id: \.rawValue) { effort in
                                    Text(language.isChinese ? "\(effort.localizedTitle) · \(effort.displayName)" : effort.displayName).tag(effort)
                                }
                            }
                            .pickerStyle(.inline)
                            .labelsHidden()
                        } label: {
                            Text(language.isChinese ? draft.reasoningEffort.localizedTitle : draft.reasoningEffort.displayName)
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(.tint)
                        }
                        .menuStyle(.borderlessButton)
                        .tint(.accentColor)
                        .fixedSize()
                        .accessibilityLabel(language.text("思考强度", "Reasoning effort"))
                        .accessibilityValue(draft.reasoningEffort.displayName)

                        Menu {
                            Picker(language.text("模型", "Model"), selection: modelBinding) {
                                ForEach(CodexExecutionPreference.Model.allCases, id: \.rawValue) { model in
                                    Text(model.displayName).tag(model)
                                }
                            }
                            .pickerStyle(.inline)
                            .labelsHidden()
                        } label: {
                            Text(draft.model.displayName)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .accessibilityLabel(language.text("模型", "Model"))
                    }
                    .frame(maxWidth: .infinity)

                    Button {
                        save(.defaultValue)
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 20))
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(defaultSettingsHelp)
                    .accessibilityLabel(language.text("恢复默认任务模型", "Restore default model settings"))
                }

                VStack(spacing: 4) {
                    Slider(value: effortIndexBinding, in: 0...Double(draft.model.supportedReasoningEfforts.count - 1), step: 1)
                        .controlSize(.large)
                        .tint(.accentColor)
                        .accessibilityLabel(language.text("思考强度", "Reasoning effort"))
                        .accessibilityValue(draft.reasoningEffort.displayName)
                    HStack {
                        Text(language.text("更轻量", "Lighter"))
                        Spacer()
                        Text(language.text("更深入", "Deeper"))
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 5)
                }
            }
            .padding(18)
            .background(Color.primary.opacity(colorScheme == .dark ? 0.05 : 0.025), in: RoundedRectangle(cornerRadius: 20))
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5)
            }

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(language.text("Fast 速度", "Fast mode")).font(.subheadline.weight(.medium))
                    Text(
                        draft.model.supportsFast
                            ? language.text("更快响应，会消耗更多额度", "Faster responses; higher usage") : language.text("此模型仅支持标准速度", "This model supports Standard speed only.")
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle(language.text("Fast 速度", "Fast mode"), isOn: fastBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!draft.model.supportsFast)
            }
            .padding(.horizontal, 4)

            if allowsApplyToAll {
                Divider()
                Button {
                    onSave(draft, true)
                    isPresented = false
                } label: {
                    Label(language.text("应用到所有账号", "Apply to all profiles"), systemImage: "person.2")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .help(language.text("覆盖所有独立账号的偏好，之后仍可分别调整", "Replace saved settings for all isolated profiles. You can still adjust each one."))
            }

            Text(
                language.text(
                    "选择即保存。后续 CLI 和派单使用相同的模型、强度与速度；正在运行的任务不变。不会修改系统 Codex 配置。",
                    "Changes save immediately for new CLI sessions and dispatched tasks. Running tasks and your system Codex configuration stay unchanged.")
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: 340)
    }

    private var modelBinding: Binding<CodexExecutionPreference.Model> {
        Binding(
            get: { draft.model },
            set: { model in
                let efforts = model.supportedReasoningEfforts
                save(
                    .init(
                        model: model,
                        reasoningEffort: efforts.contains(draft.reasoningEffort) ? draft.reasoningEffort : (efforts.last ?? .low),
                        serviceTier: model.supportsFast ? draft.serviceTier : .standard
                    ))
            })
    }

    private var effortBinding: Binding<CodexExecutionPreference.ReasoningEffort> {
        Binding(
            get: { draft.reasoningEffort },
            set: { effort in
                save(.init(model: draft.model, reasoningEffort: effort, serviceTier: draft.serviceTier))
            })
    }

    private var effortIndexBinding: Binding<Double> {
        Binding(
            get: { Double(draft.model.supportedReasoningEfforts.firstIndex(of: draft.reasoningEffort) ?? 0) },
            set: { index in
                let efforts = draft.model.supportedReasoningEfforts
                let boundedIndex = min(max(Int(index.rounded()), 0), efforts.count - 1)
                effortBinding.wrappedValue = efforts[boundedIndex]
            }
        )
    }

    private var fastBinding: Binding<Bool> {
        Binding(
            get: { draft.serviceTier == .fast },
            set: { enabled in
                save(.init(model: draft.model, reasoningEffort: draft.reasoningEffort, serviceTier: enabled && draft.model.supportsFast ? .fast : .standard))
            })
    }

    private func save(_ updated: CodexExecutionPreference) {
        guard updated != draft else { return }
        draft = updated
        onSave(updated, false)
    }

    private var speedTitle: String { preference.serviceTier == .fast ? "Fast" : language.text("标准速度", "Standard") }

    private var defaultSettingsHelp: String {
        let value = CodexExecutionPreference.defaultValue
        return language.text("恢复默认：", "Restore defaults: ")
            + "\(value.model.displayName) · \(value.reasoningEffort.displayName) · \(value.serviceTier.displayName)"
    }

    private var executionGradient: LinearGradient {
        LinearGradient(
            colors: [visualTokens.accent.primaryLight.color, visualTokens.accent.secondaryStrong.color],
            startPoint: .leading, endPoint: .trailing
        )
    }
}

/// Immediate feedback remains visible for keyboard and Reduce Motion users.
private struct ExecutionPreferenceButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.75 : 1)
    }
}
