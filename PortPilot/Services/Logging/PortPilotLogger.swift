import Foundation
import OSLog

enum PortPilotLogger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.ysbc.portpilot"
    static let discovery = Logger(subsystem: subsystem, category: "discovery")
    static let launching = Logger(subsystem: subsystem, category: "launching")
    static let processControl = Logger(subsystem: subsystem, category: "process-control")
    static let docker = Logger(subsystem: subsystem, category: "docker")
    static let persistence = Logger(subsystem: subsystem, category: "persistence")
}

enum LogStream: String, Codable, Sendable { case standardOutput, standardError, internalMessage }

struct ServiceLogEntry: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let profileID: UUID
    let timestamp: Date
    let stream: LogStream
    let message: String
}

actor ServiceLogBuffer {
    private var entriesByProfile: [UUID: [ServiceLogEntry]] = [:]
    private var redactionsByProfile: [UUID: [String]] = [:]
    private let maximumEntries: Int

    init(maximumEntries: Int = 2_000) {
        self.maximumEntries = max(100, maximumEntries)
    }

    func setSecrets(_ secrets: [String], for profileID: UUID) {
        redactionsByProfile[profileID] = secrets.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
    }

    func append(profileID: UUID, stream: LogStream, data: Data) {
        guard !data.isEmpty else { return }
        let decoded = String(decoding: data, as: UTF8.self)
        let secrets = redactionsByProfile[profileID] ?? []
        let redacted = secrets.reduce(decoded) { value, secret in
            value.replacingOccurrences(of: secret, with: "••••")
        }
        var entries = entriesByProfile[profileID] ?? []
        for line in redacted.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) where !line.isEmpty {
            entries.append(ServiceLogEntry(
                id: UUID(), profileID: profileID, timestamp: Date(), stream: stream, message: String(line)
            ))
        }
        if entries.count > maximumEntries { entries.removeFirst(entries.count - maximumEntries) }
        entriesByProfile[profileID] = entries
    }

    func entries(for profileID: UUID) -> [ServiceLogEntry] { entriesByProfile[profileID] ?? [] }
    func clear(profileID: UUID) { entriesByProfile[profileID] = [] }
}
