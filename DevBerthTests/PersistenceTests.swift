import SwiftData
import XCTest
@testable import DevBerth

final class PersistenceTests: XCTestCase {
    @MainActor
    func testHistoryPersistsInMemory() async throws {
        let schema = Schema(DevBerthSchemaV6.models)
        let configuration = ModelConfiguration("Tests", schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, migrationPlan: DevBerthMigrationPlan.self, configurations: [configuration])
        let store = SwiftDataStore(modelContainer: container)
        let event = HistoryEvent(
            id: UUID(), timestamp: Date(), port: 3000, processFingerprint: nil,
            processName: "Fixture", projectID: nil, profileID: nil,
            type: .portDetected, result: .observed, errorDetails: nil, durationSeconds: nil
        )
        try await store.record(event)
        let records = try ModelContext(container).fetch(FetchDescriptor<ProcessHistoryEventRecord>())
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].port, 3000)
    }

    @MainActor
    func testOwnershipEvidencePersistsAndRetainsOnlyNewestThousandRecords() async throws {
        let schema = Schema(DevBerthSchemaV4.models)
        let configuration = ModelConfiguration("OwnershipEvidenceTests", schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: schema,
            migrationPlan: DevBerthMigrationPlan.self,
            configurations: [configuration]
        )
        let context = ModelContext(container)
        let oldestID = UUID()
        for index in 0..<1_000 {
            let conclusion = OwnershipConclusion(
                id: index == 0 ? oldestID : UUID(),
                subject: .listener(id: "tcp:127.0.0.1:\(3_000 + index)"),
                category: .shellLaunchedProcess,
                value: "zsh",
                confidence: .stronglyInferred,
                evidence: [
                    .init(
                        field: "lineage",
                        value: "shell ancestor",
                        source: "test fixture",
                        isVerified: true
                    )
                ],
                detectionMethod: .processLineage,
                observedAt: Date(timeIntervalSince1970: Double(index))
            )
            context.insert(try OwnershipEvidenceRecord(conclusion: conclusion))
        }
        try context.save()

        let newestID = UUID()
        let newest = OwnershipConclusion(
            id: newestID,
            subject: .listener(id: "tcp:127.0.0.1:8080"),
            category: .dockerContainer,
            value: "demo-api",
            confidence: .verified,
            evidence: [
                .init(field: "container", value: "demo-api", source: "Docker metadata", isVerified: true)
            ],
            detectionMethod: .dockerMetadata,
            observedAt: Date(timeIntervalSince1970: 2_000)
        )

        let store = SwiftDataStore(modelContainer: container)
        try await store.record(newest)

        let records = try ModelContext(container).fetch(FetchDescriptor<OwnershipEvidenceRecord>())
        XCTAssertEqual(records.count, 1_000)
        XCTAssertTrue(records.contains(where: { $0.id == newestID }))
        XCTAssertFalse(records.contains(where: { $0.id == oldestID }))
        let persisted = try XCTUnwrap(records.first(where: { $0.id == newestID }))
        XCTAssertEqual(persisted.categoryRawValue, OwnershipCategory.dockerContainer.rawValue)
        XCTAssertEqual(persisted.confidenceRawValue, EvidenceConfidence.verified.rawValue)
        XCTAssertEqual(persisted.detectionMethodRawValue, OwnershipDetectionMethod.dockerMetadata.rawValue)
    }

    func testMigrationPlanContainsFrozenSchemasThroughCurrentV6() {
        XCTAssertEqual(DevBerthMigrationPlan.schemas.count, 6)
        XCTAssertEqual(DevBerthMigrationPlan.stages.count, 5)
        XCTAssertEqual(DevBerthSchemaV1.versionIdentifier, Schema.Version(1, 0, 0))
        XCTAssertEqual(DevBerthSchemaV2.versionIdentifier, Schema.Version(2, 0, 0))
        XCTAssertEqual(DevBerthSchemaV3.versionIdentifier, Schema.Version(3, 0, 0))
        XCTAssertEqual(DevBerthSchemaV4.versionIdentifier, Schema.Version(4, 0, 0))
        XCTAssertEqual(DevBerthSchemaV5.versionIdentifier, Schema.Version(5, 0, 0))
        XCTAssertEqual(DevBerthSchemaV6.versionIdentifier, Schema.Version(6, 0, 0))
    }
}
