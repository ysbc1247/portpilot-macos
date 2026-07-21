import SwiftData
import XCTest
@testable import DevBerth

final class EventBatchingTests: XCTestCase {
    func testListenerLifecycleBurstUsesOneRecorderBatch() async {
        let recorder = BatchLifecycleRecorder()
        let tracker = RuntimeLifecycleTracker(recorder: recorder)
        let updates = (0..<24).map { index in
            RuntimeLifecycleUpdate.listenerObserved(
                makeListener(port: UInt16(49_000 + index), pid: Int32(9_000 + index)),
                change: .discovered
            )
        }

        await tracker.transition(updates)

        let batchSizes = await recorder.batchSizes()
        let singleCount = await recorder.singleEventCount()
        XCTAssertEqual(batchSizes, [24])
        XCTAssertEqual(singleCount, 0)
    }

    @MainActor
    func testSwiftDataBatchPersistsLifecycleAndHistoryWithOneCallPerKind() async throws {
        let schema = Schema(DevBerthSchemaV6.models)
        let configuration = ModelConfiguration("EventBatching", schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: schema,
            migrationPlan: DevBerthMigrationPlan.self,
            configurations: [configuration]
        )
        let store = SwiftDataStore(modelContainer: container)
        let lifecycle = (0..<40).map { index in
            LifecycleEvent(
                timestamp: Date(timeIntervalSince1970: Double(index)),
                category: .listenerChanged,
                outcome: .observed,
                source: .monitor,
                trigger: .observation,
                summary: "Fixture event \(index)"
            )
        }
        let history = (0..<40).map { index in
            HistoryEvent(
                id: UUID(),
                timestamp: Date(timeIntervalSince1970: Double(index)),
                port: UInt16(49_000 + index),
                processFingerprint: nil,
                processName: "fixture",
                projectID: nil,
                profileID: nil,
                type: .portDetected,
                result: .observed,
                errorDetails: nil,
                durationSeconds: nil
            )
        }

        try await store.record(lifecycle)
        try await store.record(history)

        let context = ModelContext(container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LifecycleEventRecord>()), 40)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LifecycleEventContextRecord>()), 40)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ProcessHistoryEventRecord>()), 40)
    }
}

private actor BatchLifecycleRecorder: RuntimeLifecycleRecording {
    private var singles = 0
    private var batches: [Int] = []

    func record(_ runtime: RuntimeInstance) async throws {}
    func record(_ event: LifecycleEvent) async throws { singles += 1 }
    func record(_ events: [LifecycleEvent]) async throws { batches.append(events.count) }
    func record(_ incident: RuntimeIncidentSummary) async throws {}

    func batchSizes() -> [Int] { batches }
    func singleEventCount() -> Int { singles }
}
