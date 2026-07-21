import Foundation

protocol ProcessLineageProviding: Sendable {
    func lineage(for process: ObservedProcess) async -> [ProcessLineageNode]
}

struct SystemProcessLineageProvider: ProcessLineageProviding, Sendable {
    private let inspector: any ProcessInspecting
    private let maximumDepth: Int

    init(inspector: any ProcessInspecting, maximumDepth: Int = 12) {
        self.inspector = inspector
        self.maximumDepth = min(max(maximumDepth, 1), 32)
    }

    func lineage(for process: ObservedProcess) async -> [ProcessLineageNode] {
        var nodes = [ProcessLineageNode(
            fingerprint: process.fingerprint,
            name: process.name,
            commandLine: process.commandLine,
            currentDirectory: process.currentDirectory
        )]
        var parentPID = process.fingerprint.parentPID
        var visited: Set<Int32> = [process.fingerprint.pid]

        while nodes.count < maximumDepth,
              let pid = parentPID,
              pid > 0,
              visited.insert(pid).inserted {
            guard let inspection = try? await inspector.inspect(pid: pid) else { break }
            let executableName = inspection.fingerprint.executablePath.map {
                URL(fileURLWithPath: $0).lastPathComponent
            }
            let commandName = inspection.commandLine.split(whereSeparator: \.isWhitespace).first.map {
                URL(fileURLWithPath: String($0)).lastPathComponent
            }
            nodes.append(ProcessLineageNode(
                fingerprint: inspection.fingerprint,
                name: executableName ?? commandName ?? "PID \(pid)",
                commandLine: inspection.commandLine,
                currentDirectory: inspection.currentDirectory
            ))
            parentPID = inspection.fingerprint.parentPID
        }
        return nodes
    }
}
