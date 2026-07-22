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
    private struct StreamKey: Hashable {
        let profileID: UUID
        let stream: LogStream
    }

    private var entriesByProfile: [UUID: [ServiceLogEntry]] = [:]
    private var redactionsByProfile: [UUID: [String]] = [:]
    private var pendingRedactionSuffixes: [StreamKey: String] = [:]
    private var pendingLines: [StreamKey: String] = [:]
    private var revisionsByProfile: [UUID: UInt64] = [:]
    private let maximumEntries: Int
    private let maximumPersistedBytes: Int
    private let logDirectory: URL
    private let persistsToDisk: Bool

    init(
        maximumEntries: Int = 2_000,
        maximumPersistedBytes: Int = 2_000_000,
        persistsToDisk: Bool = true,
        logDirectory: URL? = nil
    ) {
        self.maximumEntries = max(100, maximumEntries)
        self.maximumPersistedBytes = max(64_000, maximumPersistedBytes)
        self.persistsToDisk = persistsToDisk
        if let logDirectory {
            self.logDirectory = logDirectory
        } else {
            let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.logDirectory = applicationSupport
                .appendingPathComponent(ProductIdentity.currentSupportDirectoryName, isDirectory: true)
                .appendingPathComponent("ServiceLogs", isDirectory: true)
        }
        if persistsToDisk {
            try? FileManager.default.createDirectory(at: self.logDirectory, withIntermediateDirectories: true)
        }
    }

    func setSecrets(_ secrets: [String], for profileID: UUID) {
        redactionsByProfile[profileID] = secrets.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
    }

    func append(profileID: UUID, stream: LogStream, data: Data) {
        let interval = DevBerthPerformance.begin(.logProcessing)
        defer { DevBerthPerformance.end(interval) }
        guard !data.isEmpty else { return }
        let key = StreamKey(profileID: profileID, stream: stream)
        let decoded = (pendingRedactionSuffixes.removeValue(forKey: key) ?? "")
            + String(decoding: data, as: UTF8.self)
        let secrets = redactionsByProfile[profileID] ?? []
        let heldCount = longestSecretPrefixSuffix(in: decoded, secrets: secrets)
        let stable = heldCount == 0 ? decoded : String(decoded.dropLast(heldCount))
        if heldCount > 0 { pendingRedactionSuffixes[key] = String(decoded.suffix(heldCount)) }
        let redacted = secrets.reduce(stable) { value, secret in
            value.replacingOccurrences(of: secret, with: "••••")
        }
        commitStableText(redacted, key: key)
    }

    func finalize(profileID: UUID) {
        let keys = Set(pendingRedactionSuffixes.keys.filter { $0.profileID == profileID })
            .union(pendingLines.keys.filter { $0.profileID == profileID })
        let secrets = redactionsByProfile[profileID] ?? []
        for key in keys {
            if let suffix = pendingRedactionSuffixes.removeValue(forKey: key) {
                let redacted = secrets.reduce(suffix) { value, secret in
                    value.replacingOccurrences(of: secret, with: "••••")
                }
                commitStableText(redacted, key: key)
            }
            flushPendingLine(for: key)
        }
    }

    func entries(for profileID: UUID) -> [ServiceLogEntry] {
        if let entries = entriesByProfile[profileID] { return entries }
        guard persistsToDisk else { return [] }
        let url = fileURL(profileID)
        guard let data = try? Data(contentsOf: url) else { return [] }
        let loaded = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).suffix(maximumEntries).map {
            ServiceLogEntry(id: UUID(), profileID: profileID, timestamp: Date.distantPast, stream: .internalMessage, message: String($0))
        }
        entriesByProfile[profileID] = loaded
        revisionsByProfile[profileID, default: 0] += 1
        return loaded
    }

    func revision(for profileID: UUID) -> UInt64 {
        revisionsByProfile[profileID, default: 0]
    }

    func clear(profileID: UUID) {
        entriesByProfile[profileID] = []
        revisionsByProfile[profileID, default: 0] += 1
        pendingRedactionSuffixes = pendingRedactionSuffixes.filter { $0.key.profileID != profileID }
        pendingLines = pendingLines.filter { $0.key.profileID != profileID }
        if persistsToDisk { try? Data().write(to: fileURL(profileID), options: .atomic) }
    }

    func persistedFileURL(for profileID: UUID) -> URL { fileURL(profileID) }

    private func fileURL(_ profileID: UUID) -> URL {
        logDirectory.appendingPathComponent("\(profileID.uuidString).log")
    }

    private func commitStableText(_ text: String, key: StreamKey) {
        guard !text.isEmpty else { return }
        let combined = (pendingLines.removeValue(forKey: key) ?? "") + text
        var components = combined.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if !combined.hasSuffix("\n"), let last = components.popLast() {
            pendingLines[key] = last
        } else if components.last == "" {
            components.removeLast()
        }
        appendCompleteLines(components, key: key)
    }

    private func flushPendingLine(for key: StreamKey) {
        guard let line = pendingLines.removeValue(forKey: key), !line.isEmpty else { return }
        appendCompleteLines([line], key: key)
    }

    private func appendCompleteLines(_ lines: [String], key: StreamKey) {
        let nonEmpty = lines.filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty else { return }
        var entries = entriesByProfile[key.profileID] ?? []
        for line in nonEmpty {
            entries.append(ServiceLogEntry(
                id: UUID(), profileID: key.profileID, timestamp: Date(), stream: key.stream, message: line
            ))
        }
        if entries.count > maximumEntries { entries.removeFirst(entries.count - maximumEntries) }
        entriesByProfile[key.profileID] = entries
        revisionsByProfile[key.profileID, default: 0] += 1
        persist(profileID: key.profileID, text: nonEmpty.joined(separator: "\n") + "\n")
    }

    private func persist(profileID: UUID, text: String) {
        guard persistsToDisk else { return }
        let url = fileURL(profileID)
        let appended = Data(text.utf8)
        do {
            let currentSize = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue ?? 0
            if currentSize + appended.count <= maximumPersistedBytes {
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: appended)
                try handle.close()
                return
            }

            var rotated = (try? Data(contentsOf: url)) ?? Data()
            rotated.append(appended)
            rotated = Data(rotated.suffix(maximumPersistedBytes / 2))
            if let newline = rotated.firstIndex(of: 10) {
                rotated.removeSubrange(rotated.startIndex...newline)
            }
            try rotated.write(to: url, options: .atomic)
        } catch {
            DevBerthLogger.persistence.error("Could not persist service log: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func longestSecretPrefixSuffix(in text: String, secrets: [String]) -> Int {
        var longest = 0
        for secret in secrets where secret.count > 1 {
            let maximum = min(text.count, secret.count - 1)
            guard maximum > longest else { continue }
            for length in stride(from: maximum, through: longest + 1, by: -1) {
                if text.suffix(length) == secret.prefix(length) {
                    longest = length
                    break
                }
            }
        }
        return longest
    }
}

final class ServiceLogIngress: @unchecked Sendable {
    private struct Key: Hashable {
        let profileID: UUID
        let stream: LogStream
    }

    private let logs: ServiceLogBuffer
    private let flushDelay: Duration
    private let lock = NSLock()
    private var pending: [Key: Data] = [:]
    private var flushScheduled = false
    private var scheduledBatchCount = 0

    init(logs: ServiceLogBuffer, flushDelay: Duration = .milliseconds(50)) {
        self.logs = logs
        self.flushDelay = flushDelay
    }

    func enqueue(profileID: UUID, stream: LogStream, data: Data) {
        guard !data.isEmpty else { return }
        let shouldSchedule = lock.withLock { () -> Bool in
            let key = Key(profileID: profileID, stream: stream)
            pending[key, default: Data()].append(data)
            guard !flushScheduled else { return false }
            flushScheduled = true
            scheduledBatchCount += 1
            return true
        }
        guard shouldSchedule else { return }
        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: flushDelay)
            await flushAll()
        }
    }

    func flush(profileID: UUID) async {
        let batches = lock.withLock { takePending(profileID: profileID) }
        await append(batches)
    }

    func batchCount() -> Int {
        lock.withLock { scheduledBatchCount }
    }

    private func flushAll() async {
        let batches = lock.withLock { () -> [(Key, Data)] in
            flushScheduled = false
            return takePending(profileID: nil)
        }
        await append(batches)
    }

    private func takePending(profileID: UUID?) -> [(Key, Data)] {
        let keys = pending.keys.filter { profileID == nil || $0.profileID == profileID }
        return keys.compactMap { key in
            pending.removeValue(forKey: key).map { (key, $0) }
        }
    }

    private func append(_ batches: [(Key, Data)]) async {
        for (key, data) in batches {
            await logs.append(profileID: key.profileID, stream: key.stream, data: data)
        }
    }
}
