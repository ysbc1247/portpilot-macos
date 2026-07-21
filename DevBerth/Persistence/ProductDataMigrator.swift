import Foundation
import SQLite3

struct ProductDataMigrationResult: Equatable {
    let copiedStoreArtifacts: [String]
    let copiedLegacyLogs: Bool
    let copiedDefaultKeys: [String]
}

struct ProductDataMigrator {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func migrateForCurrentUser(currentDefaults: UserDefaults = .standard) throws -> (storeURL: URL, result: ProductDataMigrationResult) {
        guard let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw DevBerthError.unexpected("The user Application Support directory is unavailable.")
        }
        let fileResult = try migrateFiles(in: applicationSupport)
        let legacyDefaults = currentDefaults.persistentDomain(forName: ProductIdentity.legacyBundleIdentifier) ?? [:]
        let copiedKeys = Self.migrateDefaults(
            legacyDomain: legacyDefaults,
            currentDefaults: currentDefaults
        )
        currentDefaults.set(ProductIdentity.defaultsMigrationVersion, forKey: ProductIdentity.defaultsMigrationMarker)
        return (
            storeURL: applicationSupport.appendingPathComponent(ProductIdentity.currentStoreFilename),
            result: ProductDataMigrationResult(
                copiedStoreArtifacts: fileResult.copiedStoreArtifacts,
                copiedLegacyLogs: fileResult.copiedLegacyLogs,
                copiedDefaultKeys: copiedKeys
            )
        )
    }

    func migrateFiles(in applicationSupport: URL) throws -> ProductDataMigrationResult {
        try fileManager.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
        let copiedStoreArtifacts = try copyLegacyStoreIfNeeded(in: applicationSupport)
        let copiedLegacyLogs = try copyLegacyLogsIfNeeded(in: applicationSupport)
        return ProductDataMigrationResult(
            copiedStoreArtifacts: copiedStoreArtifacts,
            copiedLegacyLogs: copiedLegacyLogs,
            copiedDefaultKeys: []
        )
    }

    static func migrateDefaults(
        legacyDomain: [String: Any],
        currentDefaults: UserDefaults,
        keys: Set<String> = ProductIdentity.knownNonSecretDefaultKeys
    ) -> [String] {
        guard currentDefaults.integer(forKey: ProductIdentity.defaultsMigrationMarker) < ProductIdentity.defaultsMigrationVersion else {
            return []
        }
        var copied: [String] = []
        for key in keys.sorted() where currentDefaults.object(forKey: key) == nil {
            guard let value = legacyDomain[key] else { continue }
            currentDefaults.set(value, forKey: key)
            copied.append(key)
        }
        return copied
    }

    private func copyLegacyStoreIfNeeded(in directory: URL) throws -> [String] {
        let legacyStore = directory.appendingPathComponent(ProductIdentity.legacyStoreFilename)
        let currentStore = directory.appendingPathComponent(ProductIdentity.currentStoreFilename)
        guard fileManager.fileExists(atPath: legacyStore.path), !fileManager.fileExists(atPath: currentStore.path) else {
            return []
        }

        for suffix in ["-wal", "-shm"] {
            let companion = URL(fileURLWithPath: currentStore.path + suffix)
            if fileManager.fileExists(atPath: companion.path) {
                throw DevBerthError.unexpected(
                    "The DevBerth data migration found an unexpected destination file: \(companion.path)"
                )
            }
        }

        let stagingStore = directory.appendingPathComponent(
            ".\(ProductIdentity.currentStoreFilename).migration-\(UUID().uuidString)"
        )
        do {
            try snapshotSQLiteStore(from: legacyStore, to: stagingStore)
            try fileManager.moveItem(at: stagingStore, to: currentStore)
            return [ProductIdentity.currentStoreFilename]
        } catch {
            try? fileManager.removeItem(at: stagingStore)
            try? fileManager.removeItem(at: URL(fileURLWithPath: stagingStore.path + "-wal"))
            try? fileManager.removeItem(at: URL(fileURLWithPath: stagingStore.path + "-shm"))
            throw DevBerthError.unexpected("The legacy data store could not be copied safely: \(error.localizedDescription)")
        }
    }

    private func snapshotSQLiteStore(from source: URL, to destination: URL) throws {
        var sourceDatabase: OpaquePointer?
        var destinationDatabase: OpaquePointer?
        let sourceStatus = sqlite3_open_v2(source.path, &sourceDatabase, SQLITE_OPEN_READONLY, nil)
        guard sourceStatus == SQLITE_OK, let sourceDatabase else {
            let details = Self.sqliteMessage(database: sourceDatabase, fallbackStatus: sourceStatus)
            if let sourceDatabase { sqlite3_close(sourceDatabase) }
            throw DevBerthError.unexpected("The legacy SQLite store could not be opened: \(details)")
        }
        defer { sqlite3_close(sourceDatabase) }

        let destinationStatus = sqlite3_open_v2(
            destination.path,
            &destinationDatabase,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
            nil
        )
        guard destinationStatus == SQLITE_OK, let destinationDatabase else {
            let details = Self.sqliteMessage(database: destinationDatabase, fallbackStatus: destinationStatus)
            if let destinationDatabase { sqlite3_close(destinationDatabase) }
            throw DevBerthError.unexpected("The migration snapshot could not be created: \(details)")
        }
        defer { sqlite3_close(destinationDatabase) }

        sqlite3_busy_timeout(sourceDatabase, 5_000)
        sqlite3_busy_timeout(destinationDatabase, 5_000)
        guard let backup = sqlite3_backup_init(destinationDatabase, "main", sourceDatabase, "main") else {
            throw DevBerthError.unexpected(
                "The migration snapshot could not start: \(Self.sqliteMessage(database: destinationDatabase))"
            )
        }

        var stepStatus = SQLITE_OK
        var busyRetries = 0
        backupLoop: while true {
            stepStatus = sqlite3_backup_step(backup, -1)
            switch stepStatus {
            case SQLITE_DONE:
                break backupLoop
            case SQLITE_OK:
                continue
            case SQLITE_BUSY, SQLITE_LOCKED:
                busyRetries += 1
                guard busyRetries <= 100 else { break backupLoop }
                Thread.sleep(forTimeInterval: 0.05)
            default:
                break backupLoop
            }
        }

        let finishStatus = sqlite3_backup_finish(backup)
        guard stepStatus == SQLITE_DONE, finishStatus == SQLITE_OK else {
            throw DevBerthError.unexpected(
                "The migration snapshot did not complete: \(Self.sqliteMessage(database: destinationDatabase, fallbackStatus: stepStatus))"
            )
        }
    }

    private static func sqliteMessage(database: OpaquePointer?, fallbackStatus: Int32 = SQLITE_ERROR) -> String {
        guard let database else { return "SQLite status \(fallbackStatus)" }
        return String(cString: sqlite3_errmsg(database))
    }

    private func copyLegacyLogsIfNeeded(in directory: URL) throws -> Bool {
        let legacyDirectory = directory
            .appendingPathComponent(ProductIdentity.legacySupportDirectoryName, isDirectory: true)
            .appendingPathComponent("ServiceLogs", isDirectory: true)
        let currentDirectory = directory
            .appendingPathComponent(ProductIdentity.currentSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("ServiceLogs", isDirectory: true)
        guard fileManager.fileExists(atPath: legacyDirectory.path), !fileManager.fileExists(atPath: currentDirectory.path) else {
            return false
        }
        do {
            try fileManager.createDirectory(at: currentDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: legacyDirectory, to: currentDirectory)
            return true
        } catch {
            if fileManager.fileExists(atPath: currentDirectory.path) {
                try? fileManager.removeItem(at: currentDirectory)
            }
            throw DevBerthError.unexpected("Legacy service logs could not be copied safely: \(error.localizedDescription)")
        }
    }
}
