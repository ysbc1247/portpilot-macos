import SwiftData
import XCTest
@testable import DevBerth

final class PerformanceSoakTests: XCTestCase {
    func testBoundedDiskLogRotationUnderLoad() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevBerth-Log-Soak-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profileID = UUID()
        let maximumBytes = 64_000
        let logs = ServiceLogBuffer(
            maximumEntries: 2_000,
            maximumPersistedBytes: maximumBytes,
            persistsToDisk: true,
            logDirectory: directory
        )
        await logs.setSecrets(["fixture-secret"], for: profileID)

        for index in 0..<5_000 {
            await logs.append(
                profileID: profileID,
                stream: .standardOutput,
                data: Data("\(index) fixture-secret \(String(repeating: "x", count: 480))\n".utf8)
            )
        }
        await logs.finalize(profileID: profileID)

        let url = await logs.persistedFileURL(for: profileID)
        let data = try Data(contentsOf: url)
        XCTAssertLessThanOrEqual(data.count, maximumBytes)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("fixture-secret"))
        let entries = await logs.entries(for: profileID)
        XCTAssertEqual(entries.count, 2_000)
    }

    @MainActor
    func testBoundedRuntimePersistenceAndLogSoak() async throws {
        let iterations = 250
        let schema = Schema(DevBerthSchemaV6.models)
        let configuration = ModelConfiguration("PerformanceSoak", schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: schema,
            migrationPlan: DevBerthMigrationPlan.self,
            configurations: [configuration]
        )
        let store = SwiftDataStore(modelContainer: container)
        let logs = ServiceLogBuffer(maximumEntries: 2_000, persistsToDisk: false)
        let profiles = [UUID(), UUID(), UUID()]
        let started = ContinuousClock.now
        var previous: [ObservedListener] = []

        for cycle in 0..<iterations {
            let listeners = (0..<25).map { offset in
                makeListener(
                    port: UInt16(45_000 + offset),
                    pid: Int32(20_000 + ((cycle + offset) % 40))
                )
            }
            let diff = RuntimeDiffer.diff(previous: previous, current: listeners)
            previous = listeners
            XCTAssertLessThanOrEqual(diff.added.count + diff.updated.count + diff.removed.count, 50)

            let events = listeners.map { listener in
                LifecycleEvent(
                    timestamp: Date(),
                    category: .listenerChanged,
                    outcome: .observed,
                    source: .monitor,
                    trigger: .observation,
                    summary: "Soak fixture :\(listener.port)",
                    processFingerprint: listener.process.fingerprint,
                    listenerID: listener.id
                )
            }
            try await store.record(events)

            for (index, profileID) in profiles.enumerated() {
                await logs.append(
                    profileID: profileID,
                    stream: .standardOutput,
                    data: Data("cycle=\(cycle) profile=\(index) value=fixture-secret\n".utf8)
                )
            }

            _ = SystemProcessResourceUsageReader.parse(
                listeners.map { "\($0.process.fingerprint.pid) 1.5 12288" }.joined(separator: "\n"),
                capturedAt: Date()
            )
            for listener in listeners {
                _ = RuntimePresentation.ownershipTitle(for: listener, resolved: nil)
            }
        }

        let elapsed = ContinuousClock.now - started
        let elapsedSeconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        let context = ModelContext(container)
        let lifecycleCount = try context.fetchCount(FetchDescriptor<LifecycleEventRecord>())
        XCTAssertLessThanOrEqual(lifecycleCount, 5_000)
        for profileID in profiles {
            let entries = await logs.entries(for: profileID)
            XCTAssertLessThanOrEqual(entries.count, 2_000)
        }
        let elapsedText = String(format: "%.3f", elapsedSeconds)
        print("SOAK_RESULT iterations=\(iterations) elapsed_seconds=\(elapsedText) lifecycle_rows=\(lifecycleCount) log_rows_per_profile<=2000")
    }
}
