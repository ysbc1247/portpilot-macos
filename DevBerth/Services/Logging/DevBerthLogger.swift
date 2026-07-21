import Foundation
import OSLog

enum DevBerthLogger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? ProductIdentity.currentBundleIdentifier
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
    private let maximumPersistedBytes: Int
    private let logDirectory: URL

    init(maximumEntries: Int = 2_000, maximumPersistedBytes: Int = 2_000_000) {
        self.maximumEntries = max(100, maximumEntries)
        self.maximumPersistedBytes = max(64_000, maximumPersistedBytes)
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.logDirectory = applicationSupport
            .appendingPathComponent(ProductIdentity.currentSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("ServiceLogs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
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
        persist(profileID: profileID, text: redacted)
    }

    func entries(for profileID: UUID) -> [ServiceLogEntry] {
        if let entries = entriesByProfile[profileID] { return entries }
        let url = fileURL(profileID)
        guard let data = try? Data(contentsOf: url) else { return [] }
        let loaded = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).suffix(maximumEntries).map {
            ServiceLogEntry(id: UUID(), profileID: profileID, timestamp: Date.distantPast, stream: .internalMessage, message: String($0))
        }
        entriesByProfile[profileID] = loaded
        return loaded
    }

    func clear(profileID: UUID) {
        entriesByProfile[profileID] = []
        try? Data().write(to: fileURL(profileID), options: .atomic)
    }

    func persistedFileURL(for profileID: UUID) -> URL { fileURL(profileID) }

    private func fileURL(_ profileID: UUID) -> URL {
        logDirectory.appendingPathComponent("\(profileID.uuidString).log")
    }

    private func persist(profileID: UUID, text: String) {
        let url = fileURL(profileID)
        var existing = (try? Data(contentsOf: url)) ?? Data()
        existing.append(Data(text.utf8))
        if existing.count > maximumPersistedBytes {
            existing = Data(existing.suffix(maximumPersistedBytes))
            if let newline = existing.firstIndex(of: 10) { existing.removeSubrange(existing.startIndex...newline) }
        }
        do { try existing.write(to: url, options: .atomic) }
        catch { DevBerthLogger.persistence.error("Could not persist service log: \(error.localizedDescription, privacy: .public)") }
    }
}
