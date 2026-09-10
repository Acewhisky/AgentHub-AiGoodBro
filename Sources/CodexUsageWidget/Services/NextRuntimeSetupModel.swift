import AppKit
import Foundation

final class NextRuntimeSetupModel: ObservableObject {
    typealias Component = NextRuntimeEnvironment.Component
    struct Report: Decodable {
        let schemaVersion: Int
        let components: [Component]
        let skill: String
        let hub: String
        let error: String?
    }

    @Published private(set) var report: Report?
    @Published private(set) var isBusy = false
    @Published private(set) var failed = false
    @Published private(set) var selectionFailed = false
    private let isPreview: Bool

    init(preview: Bool = false) {
        isPreview = preview
        if preview {
            report = Report(
                schemaVersion: 1,
                components: [
                    Component(id: "codex", version: "0.154.0", state: "ready"),
                    Component(id: "python", version: "", state: "missing"),
                    Component(id: "hub", version: "0910v2-next", state: "ready"),
                ], skill: "setup_needed", hub: "setup_needed", error: nil)
        }
    }

    var toolsReady: Bool { ["python", "codex"].allSatisfy { id in report?.components.contains { $0.id == id && $0.state == "ready" } == true } }
    var canSetUpHub: Bool { toolsReady && report?.components.contains { $0.id == "hub" && $0.state == "ready" } == true && report?.hub == "setup_needed" && !isBusy }

    func refresh() { execute("check") }
    func installTools() { execute("install-tools") }

    func chooseExecutable(for id: String) {
        guard !isBusy else { return }
        isBusy = true
        selectionFailed = false
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        let language = WidgetLanguage.storedOrAutomatic()
        panel.message = language.text(
            "选择已安装的 \(id == "python" ? "Python 3.9 或更新版本" : "Codex CLI")。选择后会验证版本与所需能力。",
            "Choose an installed \(id == "python" ? "Python 3.9 or newer" : "Codex CLI"). Its version and required capabilities will be checked.")
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url else {
                self?.isBusy = false
                return
            }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let valid = NextRuntimeEnvironment.validExecutable(url, for: id)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.isBusy = false
                    if valid {
                        UserDefaults.standard.set(url.path, forKey: id == "python" ? NextRuntimeEnvironment.pythonPathKey : CodexExecutable.preferredPathKey)
                        self.refresh()
                    } else {
                        self.selectionFailed = true
                    }
                }
            }
        }
    }

    func chooseProjectAndSetUpHub() {
        guard canSetUpHub else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        let language = WidgetLanguage.storedOrAutomatic()
        panel.message = language.text("选择允许调度任务读写的工作目录。启用后，服务仅在本机运行，任务仍需批准。", "Choose a workspace for dispatched tasks. The service runs locally and tasks still require approval.")
        panel.prompt = language.text("选择并启用", "Choose and enable")
        panel.begin { [weak self] result in
            guard result == .OK, let project = panel.url else { return }
            self?.execute("setup-hub", project: project)
        }
    }

    private func execute(_ command: String, project: URL? = nil) {
        guard !isBusy, !isPreview else { return }
        guard let resources = Bundle.main.resourceURL else {
            failed = true
            return
        }
        let codexCandidates = CodexExecutable.candidates().map { URL(fileURLWithPath: $0) }
        let preferredPython = UserDefaults.standard.string(forKey: NextRuntimeEnvironment.pythonPathKey)
        isBusy = true
        failed = false
        selectionFailed = false
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let snapshot = NextRuntimeEnvironment.inspect(resources: resources, codexCandidates: codexCandidates, preferredPython: preferredPython)
            var report = Report(schemaVersion: 1, components: snapshot.components, skill: "setup_needed", hub: "unknown", error: nil)
            if let python = snapshot.python, let codex = snapshot.codex {
                let script = resources.appendingPathComponent("SupportTools/next_runtime_setup.py")
                var arguments = ["-I", "-B", script.path, "--resources", resources.path, "--python", python.path, "--codex", codex.path, command]
                if let project { arguments += ["--project", project.path] }
                do {
                    let data = try BoundedLocalProcess.run(
                        executable: python, arguments: arguments, environment: NextRuntimeEnvironment.environment,
                        maximumOutputBytes: 64 * 1_024, timeout: 20, allowedExitCodes: [0, 1])
                    let result = try JSONDecoder().decode(Report.self, from: data)
                    report = Report(schemaVersion: result.schemaVersion, components: snapshot.components, skill: result.skill, hub: result.hub, error: result.error)
                } catch {
                    report = Report(schemaVersion: 1, components: snapshot.components, skill: "setup_needed", hub: "unknown", error: "setup_failed")
                }
            }
            let completedReport = report
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.report = completedReport
                self.failed = completedReport.schemaVersion != 1 || completedReport.error != nil
                self.isBusy = false
            }
        }
    }

    func failureMessage(_ language: WidgetLanguage) -> String {
        switch report?.error {
        case "setup_in_progress":
            return language.text("另一次环境准备正在进行。请等待完成后重新检查。", "Another setup is in progress. Wait for it to finish, then check again.")
        case "codex_check_failed", "codex_capability_missing":
            return language.text(
                "Codex CLI 可执行文件已变化或缺少调度能力。请升级或重新选择后再检查；不会改写原设置。",
                "The Codex CLI changed or lacks required dispatch capabilities. Update or choose it again; existing settings are unchanged.")
        case "python_selection_changed":
            return language.text("Python 在验证后发生变化。请重新选择 Python 并复检。", "Python changed after validation. Choose it again and recheck.")
        case "add_accounts_first":
            return language.text("请先添加并完成至少一个独立账号的登录，再回来启用调度。", "Add and finish signing in to at least one isolated account before enabling dispatch.")
        case "account_snapshot_invalid", "account_identity_invalid":
            return language.text(
                "账号快照或独立资料目录未通过身份校验。请在工作台重新登录相关账号，不要手动搬移资料目录。",
                "The account snapshot or isolated profile folder failed identity checks. Sign in again from the workspace; do not move profile folders manually.")
        case "project_folder_missing":
            return language.text("所选工作目录已不存在或不可访问。请重新选择。", "The selected workspace is missing or inaccessible. Choose it again.")
        case "existing_hub_preserved", "existing_hub_configuration_preserved":
            return language.text(
                "发现已有 Hub 状态或配置，Next 未启动第二个服务。请从原部署入口恢复或核实现有服务后再检查。",
                "An existing Hub state or configuration was found, so Next did not start another service. Restore or verify the existing deployment, then check again.")
        case "hub_start_needs_review":
            return language.text(
                "Hub 启动请求已发出，但健康状态尚未确认。不要重复启用；请先核实现有服务，再重新检查。",
                "The Hub start request was sent but health is not confirmed. Do not enable it again; verify the existing service, then check again.")
        case "companion_integrity_failed":
            return language.text("随包调度组件未通过完整性检查。请重新获取正式 Next 安装包。", "The bundled dispatch component failed its integrity check. Reinstall Next from an official package.")
        case "directory_symlink_conflict", "directory_permission_conflict", "existing_file_conflict", "runtime_link_conflict", "setup_lock_invalid":
            return language.text(
                "配套目录存在软链接、权限或文件冲突。原文件已保留；请核对 Next 私有目录后重新检查。",
                "A symlink, permission, or file conflict exists in the companion folders. Existing files were preserved; verify Next's private folders and check again.")
        case "rollback_conflict":
            return language.text(
                "回滚时检测到文件被另一操作改动，Next 已保留较新的文件并停止。请核对配套目录后重新检查。",
                "A file changed during rollback. Next preserved the newer file and stopped. Verify the companion folder, then check again.")
        case "command_cleanup_failed":
            return language.text(
                "依赖检查的子进程未能在限定时间内清理。请不要重复启用 Hub，先结束该次检查后再复检。",
                "A dependency-check subprocess could not be cleaned up in time. Do not enable another Hub; finish that check before retrying.")
        default:
            return language.text(
                "配套工具准备未完成。请重新检查安装与目录权限；已有配置会保留。", "Companion setup did not finish. Recheck installation and folder permissions; existing configuration is preserved.")
        }
    }
}
