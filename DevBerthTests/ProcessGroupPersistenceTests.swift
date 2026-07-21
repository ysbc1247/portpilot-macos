import SwiftData
import XCTest
@testable import DevBerth

final class ProcessGroupPersistenceTests: XCTestCase {
    @MainActor
    func testV3PersistsFullFingerprintPolicyAndProcessGroupSnapshot() throws {
        let schema = Schema(DevBerthSchemaV3.models)
        let configuration = ModelConfiguration("ProcessGroupPersistenceTests", schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: schema,
            migrationPlan: DevBerthMigrationPlan.self,
            configurations: [configuration]
        )
        let context = ModelContext(container)
        let serviceID = UUID()
        let runtimeID = UUID()
        let detectedAt = Date(timeIntervalSince1970: 1_720_000_000)
        let leader = persistedFingerprint(pid: 4242, parentPID: 1, detectedAt: detectedAt)
        let child = persistedFingerprint(pid: 4243, parentPID: 4242, detectedAt: detectedAt)
        let escaped = persistedFingerprint(pid: 4244, parentPID: 4242, detectedAt: detectedAt)
        let snapshot = ProcessGroupSnapshot(
            runtimeID: runtimeID,
            managedServiceID: serviceID,
            processGroupID: 4242,
            leaderFingerprint: leader,
            members: [
                .init(fingerprint: leader, processGroupID: 4242, role: .leader, isInControlledGroup: true),
                .init(fingerprint: child, processGroupID: 4242, role: .listenerOwner, isInControlledGroup: true),
                .init(fingerprint: escaped, processGroupID: 4244, role: .escapedDescendant, isInControlledGroup: false)
            ],
            capturedAt: detectedAt
        )

        context.insert(ProcessFingerprintRecord(
            fingerprint: leader,
            runtimeID: runtimeID,
            managedServiceID: serviceID,
            role: .leader
        ))
        context.insert(ManagedServiceProcessPolicyRecord(
            managedServiceID: serviceID,
            policy: .controlledProcessGroup,
            updatedAt: detectedAt
        ))
        context.insert(try ProcessGroupSnapshotRecord(snapshot: snapshot))
        try context.save()

        let fingerprintRecord = try XCTUnwrap(context.fetch(FetchDescriptor<ProcessFingerprintRecord>()).first)
        XCTAssertEqual(fingerprintRecord.processPID, 4242)
        XCTAssertEqual(fingerprintRecord.uid, 501)
        XCTAssertEqual(fingerprintRecord.executableDeviceID, "7")
        XCTAssertEqual(fingerprintRecord.executableInode, "4242")
        XCTAssertEqual(fingerprintRecord.commandLineDigest, leader.commandLineDigest)
        XCTAssertEqual(fingerprintRecord.parentPID, 1)
        XCTAssertEqual(fingerprintRecord.detectedAt, detectedAt)

        let policy = try XCTUnwrap(context.fetch(FetchDescriptor<ManagedServiceProcessPolicyRecord>()).first)
        XCTAssertTrue(policy.createsDedicatedProcessGroup)
        XCTAssertEqual(policy.terminationScopeRawValue, ManagedProcessTerminationScope.controlledProcessGroup.rawValue)

        let snapshotRecord = try XCTUnwrap(context.fetch(FetchDescriptor<ProcessGroupSnapshotRecord>()).first)
        let members = try JSONDecoder().decode([ProcessGroupMemberSnapshot].self, from: snapshotRecord.membersData)
        XCTAssertEqual(members.count, 3)
        XCTAssertEqual(members.filter(\.isInControlledGroup).count, 2)
        XCTAssertEqual(members.filter { $0.role == .escapedDescendant }.map { $0.fingerprint.pid }, [4244])
    }

    @MainActor
    func testGenuineV2StoreMigratesToV3WithoutChangingExistingRuntime() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevBerth-V2-to-V3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("migration.store")
        let runtimeID = UUID()
        let serviceID = UUID()
        let detectedAt = Date(timeIntervalSince1970: 1_720_000_100)

        try createV2Store(
            at: storeURL,
            runtimeID: runtimeID,
            serviceID: serviceID,
            detectedAt: detectedAt
        )

        let schema = Schema(DevBerthSchemaV3.models)
        let configuration = ModelConfiguration("V3Migration", schema: schema, url: storeURL)
        let container = try ModelContainer(
            for: schema,
            migrationPlan: DevBerthMigrationPlan.self,
            configurations: [configuration]
        )
        let context = ModelContext(container)
        XCTAssertEqual(try context.fetch(FetchDescriptor<RuntimeInstanceRecord>()).map(\.id), [runtimeID])
        XCTAssertTrue(try context.fetch(FetchDescriptor<ProcessFingerprintRecord>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<ManagedServiceProcessPolicyRecord>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<ProcessGroupSnapshotRecord>()).isEmpty)
    }

    @MainActor
    private func createV2Store(
        at storeURL: URL,
        runtimeID: UUID,
        serviceID: UUID,
        detectedAt: Date
    ) throws {
        let schema = Schema(DevBerthSchemaV2.models)
        let configuration = ModelConfiguration("V2Fixture", schema: schema, url: storeURL)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        context.insert(try RuntimeInstanceRecord(runtime: RuntimeInstance(
            id: runtimeID,
            managedServiceID: serviceID,
            processFingerprint: persistedFingerprint(pid: 4343, parentPID: 1, detectedAt: detectedAt),
            startedAt: detectedAt,
            lifecycleState: .running,
            healthState: .ready
        )))
        try context.save()
    }
}

private func persistedFingerprint(pid: Int32, parentPID: Int32, detectedAt: Date) -> ProcessFingerprint {
    let command = "/usr/local/bin/fixture --pid \(pid)"
    return ProcessFingerprint(
        pid: pid,
        uid: 501,
        executablePath: "/usr/local/bin/fixture",
        executableFileIdentity: .init(deviceID: 7, inode: UInt64(pid)),
        startTime: detectedAt.addingTimeInterval(-1),
        commandLineDigest: ProcessFingerprint.digest(commandLine: command),
        parentPID: parentPID,
        detectedAt: detectedAt
    )
}
