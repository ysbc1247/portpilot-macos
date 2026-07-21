import AppKit
import Foundation

struct MCPIntegrationSnapshot: Equatable, Sendable {
    let installedHelperURL: URL?
    let installedVersion: String?
    let bundledHelperURL: URL?
    let bundledVersion: String?
    let globalConfigurationReady: Bool
    let globalConfigurationMessage: String

    var canInstall: Bool { bundledHelperURL != nil }
    var needsUpdate: Bool {
        guard let installedVersion, let bundledVersion else { return false }
        return installedVersion != bundledVersion
    }
}

struct MCPSetupResult: Equatable, Sendable {
    let snapshot: MCPIntegrationSnapshot
    let configurationPreview: CodexConfigurationPreview
}

enum CodexConfigurationScope: Equatable, Sendable {
    case global
    case project(URL)
}

struct CodexConfigurationPreview: Equatable, Sendable {
    let targetURL: URL
    let previousText: String
    let proposedText: String

    var changed: Bool { previousText != proposedText }

    var summary: String {
        if !changed { return "No changes are required." }
        let oldLines = previousText.split(separator: "\n", omittingEmptySubsequences: false).count
        let newLines = proposedText.split(separator: "\n", omittingEmptySubsequences: false).count
        return "Update \(targetURL.path) (\(oldLines) → \(newLines) lines) while preserving unrelated TOML tables."
    }
}

@MainActor
protocol MCPIntegrationManaging: AnyObject {
    func inspect() async -> MCPIntegrationSnapshot
    func installOrRepair() async throws -> MCPIntegrationSnapshot
    func setUpGlobalCodex() async throws -> MCPSetupResult
    func uninstall() async throws -> MCPIntegrationSnapshot
    func previewCodexConfiguration(scope: CodexConfigurationScope) throws -> CodexConfigurationPreview
    func applyCodexConfiguration(_ preview: CodexConfigurationPreview) throws
    func openCodexConfiguration(scope: CodexConfigurationScope) throws
}

@MainActor
final class MCPIntegrationManager: MCPIntegrationManaging {
    static let stableHelperURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/DevBerth/bin", isDirectory: true)
        .appendingPathComponent("devberth-mcp", isDirectory: false)

    private let fileManager: FileManager
    private let bundle: Bundle

    init(fileManager: FileManager = .default, bundle: Bundle = .main) {
        self.fileManager = fileManager
        self.bundle = bundle
    }

    func inspect() async -> MCPIntegrationSnapshot {
        let installed = fileManager.isExecutableFile(atPath: Self.stableHelperURL.path) ? Self.stableHelperURL : nil
        let bundled = bundledHelperURL()
        let configuration: (ready: Bool, message: String)
        do {
            let preview = try previewCodexConfiguration(scope: .global)
            configuration = preview.changed
                ? (false, "Setup required")
                : (true, "Configured")
        } catch {
            configuration = (false, error.localizedDescription)
        }
        return MCPIntegrationSnapshot(
            installedHelperURL: installed,
            installedVersion: installed.flatMap(helperVersion),
            bundledHelperURL: bundled,
            bundledVersion: bundled.flatMap(helperVersion),
            globalConfigurationReady: configuration.ready,
            globalConfigurationMessage: configuration.message
        )
    }

    func installOrRepair() async throws -> MCPIntegrationSnapshot {
        guard let source = bundledHelperURL() else {
            throw DevBerthError.unexpected("The application bundle does not contain devberth-mcp. Reinstall DevBerth or use Scripts/install-mcp-helper.")
        }
        let destination = Self.stableHelperURL
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        guard chmod(directory.path, mode_t(0o700)) == 0 else {
            throw DevBerthError.permissionDenied("The DevBerth helper directory could not be secured.")
        }

        let temporary = directory.appendingPathComponent(".devberth-mcp-\(UUID().uuidString)")
        let backup = directory.appendingPathComponent(".devberth-mcp-backup-\(UUID().uuidString)")
        defer {
            try? fileManager.removeItem(at: temporary)
            try? fileManager.removeItem(at: backup)
        }
        try fileManager.copyItem(at: source, to: temporary)
        guard chmod(temporary.path, mode_t(0o700)) == 0 else {
            throw DevBerthError.permissionDenied("The staged DevBerth MCP helper could not be made executable.")
        }

        let hadExisting = fileManager.fileExists(atPath: destination.path)
        if hadExisting { try fileManager.moveItem(at: destination, to: backup) }
        do {
            try fileManager.moveItem(at: temporary, to: destination)
            guard helperVersion(destination) != nil else {
                throw DevBerthError.unexpected("The installed DevBerth MCP helper failed version validation.")
            }
        } catch {
            try? fileManager.removeItem(at: destination)
            if hadExisting { try? fileManager.moveItem(at: backup, to: destination) }
            throw error
        }
        return await inspect()
    }

    func setUpGlobalCodex() async throws -> MCPSetupResult {
        _ = try await installOrRepair()
        let preview = try previewCodexConfiguration(scope: .global)
        if preview.changed { try applyCodexConfiguration(preview) }
        return MCPSetupResult(
            snapshot: await inspect(),
            configurationPreview: preview
        )
    }

    func uninstall() async throws -> MCPIntegrationSnapshot {
        let target = Self.stableHelperURL
        guard fileManager.fileExists(atPath: target.path) else { return await inspect() }
        var trashed: NSURL?
        try fileManager.trashItem(at: target, resultingItemURL: &trashed)
        return await inspect()
    }

    func previewCodexConfiguration(scope: CodexConfigurationScope) throws -> CodexConfigurationPreview {
        let target = configurationURL(scope: scope)
        let current: String
        if fileManager.fileExists(atPath: target.path) {
            let values = try target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw DevBerthError.permissionDenied("Codex configuration must be a regular non-symlink file.")
            }
            guard (values.fileSize ?? 0) <= 1_048_576 else {
                throw DevBerthError.unexpected("Codex configuration is larger than the 1 MiB safety limit.")
            }
            current = try String(contentsOf: target, encoding: .utf8)
        } else {
            current = ""
        }
        let command = Self.stableHelperURL.path
        let section = """
        [mcp_servers.devberth]
        command = \"\(Self.tomlString(command))\"
        args = [\"serve\", \"--stdio\"]
        startup_timeout_sec = 10
        tool_timeout_sec = 120
        """
        let proposed = try CodexTOMLEditor.replacingDevBerthSection(in: current, with: section)
        return CodexConfigurationPreview(targetURL: target, previousText: current, proposedText: proposed)
    }

    func applyCodexConfiguration(_ preview: CodexConfigurationPreview) throws {
        let directory = preview.targetURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".config.toml-\(UUID().uuidString)")
        let backup = directory.appendingPathComponent(
            "config.toml.backup-\(Self.backupTimestamp())-\(UUID().uuidString.prefix(8))"
        )
        defer { try? fileManager.removeItem(at: temporary) }
        try Data(preview.proposedText.utf8).write(to: temporary, options: .atomic)
        _ = try CodexTOMLEditor.replacingDevBerthSection(in: preview.proposedText, with: CodexTOMLEditor.devBerthSection(in: preview.proposedText))

        let hadExisting = fileManager.fileExists(atPath: preview.targetURL.path)
        if hadExisting { try fileManager.copyItem(at: preview.targetURL, to: backup) }
        do {
            if hadExisting { try fileManager.removeItem(at: preview.targetURL) }
            try fileManager.moveItem(at: temporary, to: preview.targetURL)
            let verified = try String(contentsOf: preview.targetURL, encoding: .utf8)
            guard verified == preview.proposedText else {
                throw DevBerthError.unexpected("Codex configuration verification failed after the atomic write.")
            }
        } catch {
            try? fileManager.removeItem(at: preview.targetURL)
            if hadExisting { try? fileManager.copyItem(at: backup, to: preview.targetURL) }
            throw error
        }
    }

    func openCodexConfiguration(scope: CodexConfigurationScope) throws {
        let url = configurationURL(scope: scope)
        guard fileManager.fileExists(atPath: url.path) else {
            throw DevBerthError.unexpected("No Codex configuration exists at \(url.path).")
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func configurationURL(scope: CodexConfigurationScope) -> URL {
        switch scope {
        case .global:
            return fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml")
        case let .project(root):
            return root.standardizedFileURL.appendingPathComponent(".codex/config.toml")
        }
    }

    private func bundledHelperURL() -> URL? {
        let environment = ProcessInfo.processInfo.environment["DEVBERTH_MCP_BUNDLED_PATH"].map(URL.init(fileURLWithPath:))
        let candidates = [
            environment,
            bundle.url(forAuxiliaryExecutable: "devberth-mcp"),
            bundle.privateFrameworksURL?.appendingPathComponent("devberth-mcp"),
            bundle.resourceURL?.appendingPathComponent("devberth-mcp"),
            bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("devberth-mcp")
        ].compactMap { $0 }
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private func helperVersion(_ url: URL) -> String? {
        let process = Process()
        process.executableURL = url
        process.arguments = ["--version"]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              stdout.fileHandleForReading.readDataToEndOfFile().isEmpty else { return nil }
        let output = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return output.split(separator: " ").last.map(String.init)
    }

    private static func tomlString(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func backupTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

enum CodexTOMLEditor {
    static func replacingDevBerthSection(in source: String, with replacement: String) throws -> String {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var matchingRanges: [Range<Int>] = []
        var start: Int?
        for (index, line) in lines.enumerated() {
            guard let table = tableName(in: line) else { continue }
            if let active = start, !table.hasPrefix("mcp_servers.devberth.") {
                matchingRanges.append(active..<index)
                start = nil
            }
            if table == "mcp_servers.devberth" {
                guard start == nil else {
                    throw DevBerthError.unexpected("Codex configuration contains duplicate [mcp_servers.devberth] tables.")
                }
                start = index
            }
        }
        if let start { matchingRanges.append(start..<lines.count) }
        guard matchingRanges.count <= 1 else {
            throw DevBerthError.unexpected("Codex configuration contains duplicate [mcp_servers.devberth] tables.")
        }

        var retained = lines
        if let range = matchingRanges.first { retained.removeSubrange(range) }
        while retained.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { retained.removeLast() }
        if !retained.isEmpty { retained.append("") }
        retained.append(contentsOf: replacement.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
        return retained.joined(separator: "\n") + "\n"
    }

    static func devBerthSection(in source: String) throws -> String {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.firstIndex(where: { tableName(in: $0) == "mcp_servers.devberth" }) else {
            throw DevBerthError.unexpected("The proposed Codex configuration is missing the DevBerth table.")
        }
        let end = lines[(first + 1)...].firstIndex(where: {
            guard let table = tableName(in: $0) else { return false }
            return !table.hasPrefix("mcp_servers.devberth.")
        }) ?? lines.endIndex
        return lines[first..<end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tableName(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), !trimmed.hasPrefix("[["), let closing = trimmed.firstIndex(of: "]") else { return nil }
        let suffix = trimmed[trimmed.index(after: closing)...].trimmingCharacters(in: .whitespaces)
        guard suffix.isEmpty || suffix.hasPrefix("#") else { return nil }
        return String(trimmed[trimmed.index(after: trimmed.startIndex)..<closing]).trimmingCharacters(in: .whitespaces)
    }
}
