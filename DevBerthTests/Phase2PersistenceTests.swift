import SwiftData
import XCTest
@testable import DevBerth

final class Phase2PersistenceTests: XCTestCase {
    @MainActor
    func testV2PersistsRuntimeOwnershipTrustSessionDiscoveryAndLifecycleSeparately() throws {
        let schema = Schema(DevBerthSchemaV2.models)
        let configuration = ModelConfiguration("Phase2PersistenceTests", schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: schema,
            migrationPlan: DevBerthMigrationPlan.self,
            configurations: [configuration]
        )
        let context = ModelContext(container)
        let serviceID = UUID()
        let runtimeID = UUID()
        let projectID = UUID()
        let sessionID = UUID()
        let ownershipID = UUID()
        let lifecycleID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_710_000_000)
        let commandLine = "/usr/local/bin/api serve"
        let fingerprint = ProcessFingerprint(
            pid: 4242,
            uid: 501,
            executablePath: "/usr/local/bin/api",
            executableFileIdentity: .init(deviceID: 1, inode: 4242),
            startTime: startedAt,
            commandLineDigest: ProcessFingerprint.digest(commandLine: commandLine),
            parentPID: 1,
            detectedAt: startedAt
        )
        let runtime = RuntimeInstance(
            id: runtimeID,
            managedServiceID: serviceID,
            processFingerprint: fingerprint,
            startedAt: startedAt,
            lifecycleState: .running,
            healthState: .healthy,
            listenerIDs: ["4242:TCP:127.0.0.1:8080"]
        )
        let ownership = OwnershipConclusion(
            id: ownershipID,
            subject: .runtime(id: runtimeID),
            category: .applicationManagedProcess,
            value: "Managed API",
            confidence: .verified,
            evidence: [
                .init(field: "runtimeID", value: runtimeID.uuidString, source: "managed runtime registry", isVerified: true)
            ],
            detectionMethod: .managedRuntimeRegistry,
            observedAt: startedAt
        )
        let trust = RestartTrustAssessment(
            id: UUID(),
            managedServiceID: serviceID,
            state: .verifiedRestartable,
            reasons: ["Reviewed launch definition"],
            evidenceIDs: [ownershipID],
            assessedAt: startedAt,
            lastValidatedAt: startedAt
        )
        let serviceSnapshot = WorkspaceSessionServiceSnapshot(
            managedServiceID: serviceID,
            expectedState: .running,
            expectedListeners: [
                .init(id: UUID(), port: 8080, protocolKind: .tcp, required: true)
            ],
            dependencyServiceIDs: [],
            previousHealthState: .healthy,
            configurationDigest: "sha256:fixture"
        )
        let session = WorkspaceSession(
            id: sessionID,
            name: "API workspace",
            projectIDs: [projectID],
            serviceSnapshots: [serviceSnapshot],
            capturedAt: startedAt,
            notes: "Fixture"
        )
        let restore = SessionRestoreResult(
            id: UUID(),
            sessionID: sessionID,
            startedAt: startedAt,
            finishedAt: startedAt.addingTimeInterval(3),
            outcome: .succeeded,
            startedServiceIDs: [serviceID],
            rolledBackServiceIDs: [],
            errors: []
        )
        let discovery = ProjectDiscoveryMetadata(
            id: UUID(),
            projectID: projectID,
            rootPath: "/tmp/api",
            adapterIdentifier: "package-json",
            projectType: "Node.js",
            evidence: [
                .init(path: "/tmp/api/package.json", detail: "npm script: dev", confidence: .stronglyInferred)
            ],
            confidence: .stronglyInferred,
            discoveredAt: startedAt,
            importedAt: nil
        )
        let lifecycle = LifecycleEvent(
            id: lifecycleID,
            timestamp: startedAt,
            runtimeID: runtimeID,
            managedServiceID: serviceID,
            projectID: projectID,
            sessionID: sessionID,
            category: .ready,
            outcome: .succeeded,
            summary: "Expected listener became ready.",
            details: ["port": "8080"]
        )

        context.insert(try RuntimeInstanceRecord(runtime: runtime))
        context.insert(try OwnershipEvidenceRecord(conclusion: ownership))
        context.insert(try ManagedServiceTrustRecord(assessment: trust))
        context.insert(try WorkspaceSessionRecord(session: session))
        context.insert(try WorkspaceSessionServiceRecord(sessionID: sessionID, snapshot: serviceSnapshot))
        context.insert(try SessionRestoreRecord(result: restore))
        context.insert(try ProjectDiscoveryRecord(metadata: discovery))
        context.insert(try LifecycleEventRecord(event: lifecycle))
        try context.save()

        XCTAssertEqual(try context.fetch(FetchDescriptor<RuntimeInstanceRecord>()).map(\.id), [runtimeID])
        XCTAssertEqual(try context.fetch(FetchDescriptor<OwnershipEvidenceRecord>()).map(\.id), [ownershipID])
        XCTAssertEqual(try context.fetch(FetchDescriptor<ManagedServiceTrustRecord>()).map(\.managedServiceID), [serviceID])
        XCTAssertEqual(try context.fetch(FetchDescriptor<WorkspaceSessionRecord>()).map(\.id), [sessionID])
        XCTAssertEqual(try context.fetch(FetchDescriptor<WorkspaceSessionServiceRecord>()).map(\.managedServiceID), [serviceID])
        XCTAssertEqual(try context.fetch(FetchDescriptor<SessionRestoreRecord>()).map(\.sessionID), [sessionID])
        XCTAssertEqual(try context.fetch(FetchDescriptor<ProjectDiscoveryRecord>()).map(\.projectID), [projectID])
        XCTAssertEqual(try context.fetch(FetchDescriptor<LifecycleEventRecord>()).map(\.id), [lifecycleID])
        XCTAssertTrue(try context.fetch(FetchDescriptor<LaunchProfileRecord>()).isEmpty)
    }

    func testEvidenceConfidenceHasExplicitOrdering() {
        XCTAssertLessThan(EvidenceConfidence.unknown, .weaklyInferred)
        XCTAssertLessThan(EvidenceConfidence.weaklyInferred, .stronglyInferred)
        XCTAssertLessThan(EvidenceConfidence.stronglyInferred, .verified)
    }
}
