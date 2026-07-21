import SwiftData
import XCTest
@testable import DevBerth

final class ProductDataMigrationTests: XCTestCase {
    @MainActor
    func testCopiedLegacyV1StoreOpensAtCurrentURLAndPreservesRecords() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacyStore = root.appendingPathComponent(ProductIdentity.legacyStoreFilename)
        let currentStore = root.appendingPathComponent(ProductIdentity.currentStoreFilename)
        let projectID = UUID()
        let profileID = UUID()

        try createLegacyV1Fixture(at: legacyStore, projectID: projectID, profileID: profileID)
        let retainedLegacyArtifacts = ["", "-wal", "-shm"].filter {
            FileManager.default.fileExists(atPath: legacyStore.path + $0)
        }

        let result = try ProductDataMigrator().migrateFiles(in: root)
        XCTAssertEqual(result.copiedStoreArtifacts, [ProductIdentity.currentStoreFilename])
        for suffix in retainedLegacyArtifacts {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: legacyStore.path + suffix),
                "Every legacy SQLite artifact must remain available for rollback."
            )
        }

        let schema = Schema(DevBerthSchemaV4.models)
        let configuration = ModelConfiguration("DevBerthMigrationFixture", schema: schema, url: currentStore)
        let container = try ModelContainer(
            for: schema,
            migrationPlan: DevBerthMigrationPlan.self,
            configurations: [configuration]
        )
        let context = ModelContext(container)
        let projects = try context.fetch(FetchDescriptor<ProjectRecord>())
        let profiles = try context.fetch(FetchDescriptor<LaunchProfileRecord>())
        let expectedPorts = try context.fetch(FetchDescriptor<ExpectedPortRecord>())
        let history = try context.fetch(FetchDescriptor<ProcessHistoryEventRecord>())
        let preferences = try context.fetch(FetchDescriptor<UserPreferenceRecord>())
        let runtimeInstances = try context.fetch(FetchDescriptor<RuntimeInstanceRecord>())

        XCTAssertEqual(projects.map(\.id), [projectID])
        XCTAssertEqual(projects.map(\.name), ["Legacy Project"])
        XCTAssertEqual(profiles.map(\.id), [profileID])
        XCTAssertEqual(profiles.map(\.name), ["Legacy API"])
        XCTAssertEqual(expectedPorts.map(\.port), [4317])
        XCTAssertEqual(history.map(\.processName), ["legacy-api"])
        XCTAssertEqual(preferences.map(\.key), ["sidebar.selection"])
        XCTAssertTrue(runtimeInstances.isEmpty)
    }

    func testCopiesLegacyLogsWithoutRemovingRollbackSource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let legacyLogs = root
            .appendingPathComponent(ProductIdentity.legacySupportDirectoryName, isDirectory: true)
            .appendingPathComponent("ServiceLogs", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyLogs, withIntermediateDirectories: true)
        try Data("redacted log".utf8).write(to: legacyLogs.appendingPathComponent("fixture.log"))

        let result = try ProductDataMigrator().migrateFiles(in: root)

        XCTAssertTrue(result.copiedStoreArtifacts.isEmpty)
        XCTAssertTrue(result.copiedLegacyLogs)
        XCTAssertEqual(
            try String(
                contentsOf: root
                    .appendingPathComponent(ProductIdentity.currentSupportDirectoryName)
                    .appendingPathComponent("ServiceLogs/fixture.log"),
                encoding: .utf8
            ),
            "redacted log"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyLogs.appendingPathComponent("fixture.log").path))
    }

    func testCorruptLegacyStoreRollsBackPartialDestination() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacyStore = root.appendingPathComponent(ProductIdentity.legacyStoreFilename)
        let currentStore = root.appendingPathComponent(ProductIdentity.currentStoreFilename)
        try Data("not a SQLite database".utf8).write(to: legacyStore)

        XCTAssertThrowsError(try ProductDataMigrator().migrateFiles(in: root))

        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyStore.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: currentStore.path))
        let remainingNames = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(remainingNames.contains { $0.hasPrefix(".\(ProductIdentity.currentStoreFilename).migration-") })
    }

    func testDoesNotOverwriteCurrentStoreOrLogs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: root.appendingPathComponent(ProductIdentity.legacyStoreFilename))
        try Data("current".utf8).write(to: root.appendingPathComponent(ProductIdentity.currentStoreFilename))
        let currentLogs = root
            .appendingPathComponent(ProductIdentity.currentSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("ServiceLogs", isDirectory: true)
        try FileManager.default.createDirectory(at: currentLogs, withIntermediateDirectories: true)
        try Data("current log".utf8).write(to: currentLogs.appendingPathComponent("fixture.log"))

        let result = try ProductDataMigrator().migrateFiles(in: root)

        XCTAssertTrue(result.copiedStoreArtifacts.isEmpty)
        XCTAssertFalse(result.copiedLegacyLogs)
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent(ProductIdentity.currentStoreFilename), encoding: .utf8),
            "current"
        )
        XCTAssertEqual(try String(contentsOf: currentLogs.appendingPathComponent("fixture.log"), encoding: .utf8), "current log")
    }

    func testDefaultsMigrationCopiesOnlyKnownUnsetValuesOnce() throws {
        let suite = "DevBerthTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(10.0, forKey: "refreshInterval")

        let copied = ProductDataMigrator.migrateDefaults(
            legacyDomain: [
                "refreshInterval": 5.0,
                "historyRetentionDays": 45,
                "secret": "must not migrate"
            ],
            currentDefaults: defaults
        )
        defaults.set(ProductIdentity.defaultsMigrationVersion, forKey: ProductIdentity.defaultsMigrationMarker)

        XCTAssertEqual(copied, ["historyRetentionDays"])
        XCTAssertEqual(defaults.double(forKey: "refreshInterval"), 10.0)
        XCTAssertEqual(defaults.integer(forKey: "historyRetentionDays"), 45)
        XCTAssertNil(defaults.object(forKey: "secret"))
        XCTAssertTrue(ProductDataMigrator.migrateDefaults(
            legacyDomain: ["notifyConfiguredPorts": true],
            currentDefaults: defaults
        ).isEmpty)
    }

    @MainActor
    private func createLegacyV1Fixture(at storeURL: URL, projectID: UUID, profileID: UUID) throws {
        let schema = Schema(DevBerthSchemaV1.models)
        let configuration = ModelConfiguration("PortPilotV1Fixture", schema: schema, url: storeURL)
        let container = try ModelContainer(
            for: schema,
            migrationPlan: DevBerthV1FixturePlan.self,
            configurations: [configuration]
        )
        let context = ModelContext(container)
        let project = ProjectRecord(id: projectID, name: "Legacy Project", folderPath: "/tmp/legacy-project")
        let profile = LaunchProfileRecord(
            id: profileID,
            name: "Legacy API",
            command: "/usr/bin/python3",
            workingDirectory: "/tmp/legacy-project"
        )
        profile.projectID = projectID
        context.insert(project)
        context.insert(profile)
        context.insert(ExpectedPortRecord(profileID: profileID, port: 4317, protocolKind: .tcp))
        context.insert(ProcessHistoryEventRecord(event: HistoryEvent(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            port: 4317,
            processFingerprint: nil,
            processName: "legacy-api",
            projectID: projectID,
            profileID: profileID,
            type: .portDetected,
            result: .observed,
            errorDetails: nil,
            durationSeconds: nil
        )))
        context.insert(UserPreferenceRecord(key: "sidebar.selection", encodedValue: Data("ports".utf8)))
        try context.save()
    }
}

private enum DevBerthV1FixturePlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [DevBerthSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}
