import SwiftData
import XCTest
@testable import DevBerth

final class PersistenceTests: XCTestCase {
    @MainActor
    func testHistoryPersistsInMemory() async throws {
        let schema = Schema(DevBerthSchemaV1.models)
        let configuration = ModelConfiguration("Tests", schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, migrationPlan: DevBerthMigrationPlan.self, configurations: [configuration])
        let store = SwiftDataStore(modelContainer: container)
        let event = HistoryEvent(
            id: UUID(), timestamp: Date(), port: 3000, processIdentity: nil,
            processName: "Fixture", projectID: nil, profileID: nil,
            type: .portDetected, result: .observed, errorDetails: nil, durationSeconds: nil
        )
        try await store.record(event)
        let records = try ModelContext(container).fetch(FetchDescriptor<ProcessHistoryEventRecord>())
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].port, 3000)
    }

    func testMigrationPlanContainsInitialSchema() {
        XCTAssertEqual(DevBerthMigrationPlan.schemas.count, 1)
        XCTAssertEqual(DevBerthSchemaV1.versionIdentifier, Schema.Version(1, 0, 0))
    }
}
