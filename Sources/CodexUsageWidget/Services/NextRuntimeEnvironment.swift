import Foundation

/// Read-only discovery. A missing Python never prevents native account management.
enum NextRuntimeEnvironment {
    static let pythonPathKey = "CodexManagerNext.runtime.pythonPath"
    static let pythonInstallationURL = URL(string: "https://www.python.org/downloads/macos/")!
    static let codexInstallationURL = URL(string: "https://github.com/openai/codex#installing-and-running-codex-cli")!
    static let codexInstallCommand = "curl -fsSL https://chatgpt.com/codex/install.sh | sh"

    struct Component: Decodable, Identifiable {
        let id: String
        let version: String
        let state: String
    }
    struct Snapshot {
        let components: [Component]
        let python: URL?
        let codex: URL?
    }

    static var environment: [String: String] {
        ProcessInfo.processInfo.environment.filter { ["HOME", "USER", "TMPDIR"].contains($0.key) }
            .merging(["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"], uniquingKeysWith: { _, last in last })
    }

    static func inspect(resources: URL, codexCandidates: [URL], preferredPython: String?, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Snapshot {
        let candidates = pythonCandidates(preferred: preferredPython, home: home)
        var python: URL?
        var detectedPythonVersion = ""
        let discoveryDeadline = Date().addingTimeInterval(15)
        for candidate in candidates {
            if Date() >= discoveryDeadline { break }
            guard let text = pythonVersion(of: candidate) else { continue }
            python = candidate
            detectedPythonVersion = text
            break
        }
        var codex: URL?
        var detectedCodexVersion = ""
        var foundCodexVersion = false
        let codexDeadline = Date().addingTimeInterval(15)
        for candidate in codexCandidates.prefix(12) {
            if Date() >= codexDeadline { break }
            guard let candidateVersion = version(of: candidate) else { continue }
            if !foundCodexVersion {
                detectedCodexVersion = candidateVersion
                foundCodexVersion = true
            }
            guard codexCapabilitiesReady(candidate) else { continue }
            codex = candidate
            detectedCodexVersion = candidateVersion
            break
        }
        let hub = resources.appendingPathComponent("CompanionHub/agent-remote-control")
        let hubVersion = version(of: hub)
        return Snapshot(components: [
            Component(id: "codex", version: detectedCodexVersion, state: codex != nil ? "ready" : foundCodexVersion ? "incompatible" : "missing"),
            Component(id: "python", version: detectedPythonVersion, state: python == nil ? "missing" : "ready"),
            Component(id: "hub", version: hubVersion ?? "", state: hubVersion == nil ? "missing" : "ready"),
        ], python: python, codex: codex)
    }

    static func supportedPython(_ text: String) -> Bool {
        let fields = text.split(separator: ".", omittingEmptySubsequences: false)
        let parts = fields.compactMap { Int($0) }
        return fields.count == 3 && parts.count == 3 && parts[0] == 3 && parts[1] >= 9 && parts[2] >= 0
    }

    static func validExecutable(_ executable: URL, for id: String) -> Bool {
        if id == "python" { return pythonVersion(of: executable) != nil }
        return id == "codex" && version(of: executable) != nil && codexCapabilitiesReady(executable)
    }

    private static func pythonVersion(of executable: URL) -> String? {
        guard FileManager.default.isExecutableFile(atPath: executable.path),
            let data = try? BoundedLocalProcess.run(executable: executable,
                arguments: ["-I", "-B", "-c", "import sys,ssl,sqlite3,ctypes,fcntl,zoneinfo; zoneinfo.ZoneInfo('Asia/Shanghai'); print('.'.join(map(str,sys.version_info[:3])))"],
                environment: environment, maximumOutputBytes: 1_024, timeout: 2),
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), supportedPython(text)
        else { return nil }
        return text
    }

    private static func codexCapabilitiesReady(_ executable: URL) -> Bool {
        guard let data = try? BoundedLocalProcess.run(executable: executable, arguments: ["exec", "--help"], environment: environment,
                maximumOutputBytes: 64 * 1_024, timeout: 3), let help = String(data: data, encoding: .utf8)
        else { return false }
        return ["--output-last-message", "--sandbox", "--model"].allSatisfy(help.contains)
    }

    private static func version(of executable: URL) -> String? {
        guard FileManager.default.isExecutableFile(atPath: executable.path),
            let data = try? BoundedLocalProcess.run(executable: executable, arguments: ["--version"], environment: environment,
                maximumOutputBytes: 1_024, timeout: 2),
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
            let value = text.split(whereSeparator: \.isWhitespace).last,
            !value.isEmpty, value.count <= 40,
            value.utf8.allSatisfy({ (45...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) })
        else { return nil }
        return String(value)
    }

    private static func pythonCandidates(preferred: String?, home: URL) -> [URL] {
        var paths = [preferred, "/opt/homebrew/bin/python3", "/usr/local/bin/python3",
                     "/Library/Frameworks/Python.framework/Versions/Current/bin/python3",
                     "/Library/Developer/CommandLineTools/Library/Frameworks/Python3.framework/Versions/3.9/bin/python3",
                     home.appendingPathComponent(".local/bin/python3").path].compactMap { $0 }
        // Common python.org and uv installations; never recursively scan the user's home.
        let roots = [URL(fileURLWithPath: "/Library/Frameworks/Python.framework/Versions"), home.appendingPathComponent(".local/share/uv/python")]
        for root in roots {
            if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]) {
                var items: [URL] = []
                while items.count < 64, let item = enumerator.nextObject() as? URL { items.append(item) }
                paths += items.sorted { $0.lastPathComponent > $1.lastPathComponent }.prefix(12).map { $0.appendingPathComponent("bin/python3").path }
            }
        }
        var seen = Set<String>()
        return paths.prefix(30).filter { $0.hasPrefix("/") && seen.insert($0).inserted }.map { URL(fileURLWithPath: $0) }
    }
}
