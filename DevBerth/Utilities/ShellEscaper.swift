import Foundation

enum ShellEscaper {
    static func quote(_ argument: String) -> String {
        guard !argument.isEmpty else { return "''" }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    static func command(executable: String, arguments: [String]) -> String {
        ([executable] + arguments).map(quote).joined(separator: " ")
    }
}

struct ExecutableResolver: @unchecked Sendable {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func resolve(
        _ command: String,
        environment: [String: String],
        workingDirectory: String,
        additionalSearchDirectories: [String] = []
    ) -> URL? {
        if command.hasPrefix("/") {
            return fileManager.isExecutableFile(atPath: command) ? URL(fileURLWithPath: command) : nil
        }
        if command.hasPrefix("./") {
            let path = URL(fileURLWithPath: workingDirectory).appendingPathComponent(String(command.dropFirst(2))).path
            return fileManager.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        let environmentPath = environment["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
        let standardDirectories = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        var seen = Set<String>()
        let searchDirectories = environmentPath.split(separator: ":").map(String.init)
            + additionalSearchDirectories
            + standardDirectories
        return searchDirectories
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .map { URL(fileURLWithPath: $0).appendingPathComponent(command) }
            .first { fileManager.isExecutableFile(atPath: $0.path) }
    }
}
