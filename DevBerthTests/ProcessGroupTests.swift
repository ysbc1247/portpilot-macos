import Darwin
import XCTest
@testable import DevBerth

final class ProcessGroupTests: XCTestCase {
    func testTopologyFindsNestedAndEscapedDescendants() {
        let topology = SystemProcessGroupInspector.parseTopology(
            "100 100 1 S\n101 100 100 S\n102 102 101 S\n103 100 1 Z\nmalformed\n"
        )

        XCTAssertEqual(topology.count, 4)
        XCTAssertEqual(SystemProcessGroupInspector.descendantPIDs(of: 100, in: topology), [101, 102])
    }

    func testInspectorClassifiesLeaderListenerOwnerAndEscapedDescendant() async throws {
        let leader = groupFingerprint(pid: 100, parentPID: 1)
        let listenerOwner = groupFingerprint(pid: 101, parentPID: 100)
        let escaped = groupFingerprint(pid: 102, parentPID: 101)
        let unrelatedMember = groupFingerprint(pid: 103, parentPID: 1)
        let runner = MockCommandRunner { executable, _ in
            XCTAssertEqual(executable.path, "/bin/ps")
            return .init(
                stdout: Data("100 100 1 S\n101 100 100 S\n102 102 101 S\n103 100 1 Z\n".utf8),
                stderr: Data(),
                exitCode: 0
            )
        }
        let inspector = SystemProcessGroupInspector(
            runner: runner,
            processInspector: MappedProcessInspector(fingerprints: [
                100: leader,
                101: listenerOwner,
                102: escaped,
                103: unrelatedMember
            ]),
            clock: { Date(timeIntervalSince1970: 1_730_000_100) }
        )
        let runtime = ManagedRuntimeHandle(
            id: UUID(),
            managedServiceID: UUID(),
            leaderFingerprint: leader,
            processGroupID: 100,
            processPolicy: .controlledProcessGroup,
            launchedAt: leader.detectedAt
        )

        let snapshot = try await inspector.snapshot(for: runtime, listenerOwnerPIDs: [101])
        let roles = Dictionary(uniqueKeysWithValues: snapshot.members.map { ($0.fingerprint.pid, $0.role) })
        XCTAssertEqual(roles[100], .leader)
        XCTAssertEqual(roles[101], .listenerOwner)
        XCTAssertEqual(roles[102], .escapedDescendant)
        XCTAssertEqual(roles[103], .groupMember)
        XCTAssertEqual(snapshot.controlledMembers.map { $0.fingerprint.pid }, [100, 101, 103])
        XCTAssertEqual(snapshot.liveControlledMembers.map { $0.fingerprint.pid }, [100, 101])
        XCTAssertEqual(snapshot.escapedDescendants.map { $0.fingerprint.pid }, [102])
    }

    func testManagedLauncherSignalsVerifiedControlledGroupAndNotEscapedDescendant() async throws {
        let serviceID = UUID()
        let leader = groupFingerprint(pid: 100, parentPID: 1)
        let child = groupFingerprint(pid: 101, parentPID: 100)
        let escaped = groupFingerprint(pid: 102, parentPID: 101)
        let runtimeID = UUID()
        let launchSnapshot = groupSnapshot(
            runtimeID: runtimeID,
            serviceID: serviceID,
            leader: leader,
            members: [
                groupMember(leader, groupID: 100, role: .leader, controlled: true),
                groupMember(child, groupID: 100, role: .descendant, controlled: true),
                groupMember(escaped, groupID: 102, role: .escapedDescendant, controlled: false)
            ]
        )
        let stopSnapshot = groupSnapshot(
            runtimeID: runtimeID,
            serviceID: serviceID,
            leader: leader,
            members: [
                groupMember(child, groupID: 100, role: .listenerOwner, controlled: true),
                groupMember(escaped, groupID: 102, role: .escapedDescendant, controlled: false)
            ]
        )
        let groupOperator = RecordingProcessGroupOperator(processGroupID: 100)
        let launcher = ManagedProcessLauncher(
            secrets: EmptySecretStore(),
            logs: ServiceLogBuffer(persistsToDisk: false),
            runner: successfulGroupRunner(),
            spawner: FixedControlledSpawner(pid: 100, processGroupID: 100),
            processInspector: MappedProcessInspector(fingerprints: [100: leader]),
            fingerprintVerifier: MatchingKnownFingerprintVerifier(fingerprints: [101: child]),
            groupInspector: SequencedProcessGroupInspector(snapshots: [launchSnapshot, stopSnapshot]),
            groupOperator: groupOperator,
            listenerDiscoverer: EmptyPortDiscoverer()
        )
        let profile = managedFixtureProfile(id: serviceID)

        try await launcher.launch(profile)
        try await launcher.stop(profileID: serviceID, timeoutSeconds: 1)

        XCTAssertEqual(groupOperator.signals(), [.init(signal: SIGTERM, target: .group(100))])
        XCTAssertFalse(groupOperator.signals().contains { $0.target == .process(102) })
    }

    func testManagedLauncherRefusesUnknownReplacementGroupMember() async throws {
        let serviceID = UUID()
        let leader = groupFingerprint(pid: 200, parentPID: 1)
        let replacement = groupFingerprint(pid: 299, parentPID: 1)
        let launchSnapshot = groupSnapshot(
            serviceID: serviceID,
            leader: leader,
            members: [groupMember(leader, groupID: 200, role: .leader, controlled: true)]
        )
        let replacedSnapshot = groupSnapshot(
            serviceID: serviceID,
            leader: leader,
            members: [groupMember(replacement, groupID: 200, role: .groupMember, controlled: true)]
        )
        let groupOperator = RecordingProcessGroupOperator(processGroupID: 200)
        let launcher = ManagedProcessLauncher(
            secrets: EmptySecretStore(),
            logs: ServiceLogBuffer(persistsToDisk: false),
            runner: successfulGroupRunner(),
            spawner: FixedControlledSpawner(pid: 200, processGroupID: 200),
            processInspector: MappedProcessInspector(fingerprints: [200: leader]),
            fingerprintVerifier: MatchingKnownFingerprintVerifier(fingerprints: [:]),
            groupInspector: SequencedProcessGroupInspector(snapshots: [launchSnapshot, replacedSnapshot]),
            groupOperator: groupOperator,
            listenerDiscoverer: EmptyPortDiscoverer()
        )

        try await launcher.launch(managedFixtureProfile(id: serviceID))
        do {
            try await launcher.stop(profileID: serviceID, timeoutSeconds: 1)
            XCTFail("Expected the unanchored replacement group to be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("no previously captured descendant"))
        }
        XCTAssertTrue(groupOperator.signals().isEmpty)
    }

    func testRootOnlyPolicySignalsOnlyRevalidatedLeader() async throws {
        let serviceID = UUID()
        let leader = groupFingerprint(pid: 300, parentPID: 1)
        let snapshot = groupSnapshot(
            serviceID: serviceID,
            leader: leader,
            members: [groupMember(leader, groupID: 300, role: .leader, controlled: true)]
        )
        let groupOperator = RecordingProcessGroupOperator(processGroupID: 300)
        let launcher = ManagedProcessLauncher(
            secrets: EmptySecretStore(),
            logs: ServiceLogBuffer(persistsToDisk: false),
            runner: successfulGroupRunner(),
            spawner: FixedControlledSpawner(pid: 300, processGroupID: 300),
            processInspector: MappedProcessInspector(fingerprints: [300: leader]),
            fingerprintVerifier: SequencedMatchingVerifier(results: [.matched(actual: leader), .notFound]),
            groupInspector: SequencedProcessGroupInspector(snapshots: [snapshot, snapshot]),
            groupOperator: groupOperator,
            listenerDiscoverer: EmptyPortDiscoverer()
        )
        var profile = managedFixtureProfile(id: serviceID)
        profile.processPolicy = .rootProcessOnly

        try await launcher.launch(profile)
        try await launcher.stop(profileID: serviceID, timeoutSeconds: 1)

        XCTAssertEqual(groupOperator.signals(), [.init(signal: SIGTERM, target: .process(300))])
    }

    func testManagedLauncherWaitsForPostSpawnFingerprintStability() async throws {
        let serviceID = UUID()
        let transient = groupFingerprint(pid: 400, parentPID: 1)
        let stable = ProcessFingerprint(
            pid: transient.pid,
            uid: transient.uid,
            executablePath: "/opt/devberth-fixture/python3",
            executableFileIdentity: .init(deviceID: 2, inode: 400),
            startTime: transient.startTime,
            commandLineDigest: ProcessFingerprint.digest(commandLine: "/opt/devberth-fixture/python3 fixture.py"),
            parentPID: transient.parentPID,
            detectedAt: transient.detectedAt
        )
        let inspector = SequencedProcessInspector(
            fingerprints: [transient, transient] + Array(repeating: stable, count: 9)
        )
        let snapshot = groupSnapshot(
            serviceID: serviceID,
            leader: stable,
            members: [groupMember(stable, groupID: 400, role: .leader, controlled: true)]
        )
        let launcher = ManagedProcessLauncher(
            secrets: EmptySecretStore(),
            logs: ServiceLogBuffer(persistsToDisk: false),
            runner: successfulGroupRunner(),
            spawner: FixedControlledSpawner(pid: 400, processGroupID: 400),
            processInspector: inspector,
            fingerprintVerifier: MatchingKnownFingerprintVerifier(fingerprints: [400: stable]),
            groupInspector: SequencedProcessGroupInspector(snapshots: [snapshot]),
            groupOperator: RecordingProcessGroupOperator(processGroupID: 400),
            listenerDiscoverer: EmptyPortDiscoverer()
        )

        try await launcher.launch(managedFixtureProfile(id: serviceID))

        let runtimeHandle = await launcher.runtimeHandle(profileID: serviceID)
        let handle = try XCTUnwrap(runtimeHandle)
        XCTAssertEqual(handle.leaderFingerprint.executablePath, stable.executablePath)
        XCTAssertEqual(handle.leaderFingerprint.commandLineDigest, stable.commandLineDigest)
        let inspectionCount = await inspector.inspectionCount()
        XCTAssertGreaterThanOrEqual(inspectionCount, 11)
    }
}

private struct MappedProcessInspector: ProcessInspecting {
    let fingerprints: [Int32: ProcessFingerprint]

    func inspect(pid: Int32) async throws -> ProcessInspection? {
        fingerprints[pid].map {
            ProcessInspection(fingerprint: $0, commandLine: "fixture \(pid)", currentDirectory: "/tmp")
        }
    }
}

private actor SequencedProcessInspector: ProcessInspecting {
    private var fingerprints: [ProcessFingerprint]
    private var count = 0

    init(fingerprints: [ProcessFingerprint]) {
        precondition(!fingerprints.isEmpty)
        self.fingerprints = fingerprints
    }

    func inspect(pid: Int32) async throws -> ProcessInspection? {
        count += 1
        let fingerprint = fingerprints.count > 1 ? fingerprints.removeFirst() : fingerprints[0]
        return ProcessInspection(
            fingerprint: fingerprint,
            commandLine: "fixture \(pid)",
            currentDirectory: "/tmp"
        )
    }

    func inspectionCount() -> Int { count }
}

private actor SequencedProcessGroupInspector: ProcessGroupInspecting {
    private var snapshots: [ProcessGroupSnapshot]

    init(snapshots: [ProcessGroupSnapshot]) {
        precondition(!snapshots.isEmpty)
        self.snapshots = snapshots
    }

    func snapshot(
        for runtime: ManagedRuntimeHandle,
        listenerOwnerPIDs: Set<Int32>
    ) async throws -> ProcessGroupSnapshot {
        guard snapshots.count > 1 else { return snapshots[0] }
        return snapshots.removeFirst()
    }
}

private struct MatchingKnownFingerprintVerifier: ProcessFingerprintVerifying {
    let fingerprints: [Int32: ProcessFingerprint]

    func verify(_ expected: ProcessFingerprint) async throws -> ProcessFingerprintVerification {
        guard let actual = fingerprints[expected.pid] else { return .notFound }
        return ProcessFingerprintVerifier.differences(expected: expected, actual: actual).isEmpty
            ? .matched(actual: actual)
            : .mismatched(actual: actual, differences: ProcessFingerprintVerifier.differences(expected: expected, actual: actual))
    }
}

private actor SequencedMatchingVerifier: ProcessFingerprintVerifying {
    private var results: [ProcessFingerprintVerification]

    init(results: [ProcessFingerprintVerification]) {
        self.results = results
    }

    func verify(_ expected: ProcessFingerprint) async throws -> ProcessFingerprintVerification {
        guard results.count > 1 else { return results[0] }
        return results.removeFirst()
    }
}

private struct FixedControlledSpawner: ControlledProcessSpawning {
    let pid: Int32
    let processGroupID: Int32

    func spawn(_ request: ControlledProcessLaunchRequest) throws -> SpawnedManagedProcess {
        SpawnedManagedProcess(
            pid: pid,
            processGroupID: processGroupID,
            standardOutput: Pipe().fileHandleForReading,
            standardError: Pipe().fileHandleForReading
        )
    }
}

private final class RecordingProcessGroupOperator: ProcessGroupOperating, @unchecked Sendable {
    enum Target: Equatable { case group(Int32), process(Int32) }
    struct Signal: Equatable {
        let signal: Int32
        let target: Target
    }

    private let lock = NSLock()
    private let assignedProcessGroupID: Int32
    private var recordedSignals: [Signal] = []
    private var groupAlive = true

    init(processGroupID: Int32) {
        assignedProcessGroupID = processGroupID
    }

    func processGroupID(for pid: Int32) -> Int32? { assignedProcessGroupID }
    func processGroupExists(_ processGroupID: Int32) -> Bool { lock.withLock { groupAlive } }

    func send(signal: Int32, toProcessGroup processGroupID: Int32) throws {
        lock.withLock {
            recordedSignals.append(.init(signal: signal, target: .group(processGroupID)))
            groupAlive = false
        }
    }

    func send(signal: Int32, toProcess pid: Int32) throws {
        lock.withLock {
            recordedSignals.append(.init(signal: signal, target: .process(pid)))
        }
    }

    func signals() -> [Signal] { lock.withLock { recordedSignals } }
}

private struct EmptySecretStore: SecretStoring {
    func save(value: String, reference: UUID) async throws {}
    func value(for reference: UUID) async throws -> String? { nil }
    func delete(reference: UUID) async throws {}
}

private struct EmptyPortDiscoverer: PortDiscovering {
    func discover() async throws -> [ObservedListener] { [] }
}

private func groupFingerprint(pid: Int32, parentPID: Int32) -> ProcessFingerprint {
    let detectedAt = Date(timeIntervalSince1970: 1_730_000_000)
    let command = "/usr/bin/python3 fixture.py --pid \(pid)"
    return ProcessFingerprint(
        pid: pid,
        uid: 501,
        executablePath: "/usr/bin/python3",
        executableFileIdentity: .init(deviceID: 1, inode: UInt64(pid)),
        startTime: detectedAt.addingTimeInterval(-1),
        commandLineDigest: ProcessFingerprint.digest(commandLine: command),
        parentPID: parentPID,
        detectedAt: detectedAt
    )
}

private func groupMember(
    _ fingerprint: ProcessFingerprint,
    groupID: Int32,
    role: ProcessGroupMemberRole,
    controlled: Bool
) -> ProcessGroupMemberSnapshot {
    .init(fingerprint: fingerprint, processGroupID: groupID, role: role, isInControlledGroup: controlled)
}

private func groupSnapshot(
    runtimeID: UUID = UUID(),
    serviceID: UUID,
    leader: ProcessFingerprint,
    members: [ProcessGroupMemberSnapshot]
) -> ProcessGroupSnapshot {
    ProcessGroupSnapshot(
        runtimeID: runtimeID,
        managedServiceID: serviceID,
        processGroupID: leader.pid,
        leaderFingerprint: leader,
        members: members,
        capturedAt: leader.detectedAt
    )
}

private func managedFixtureProfile(id: UUID) -> ManagedServiceConfiguration {
    ManagedServiceConfiguration(
        id: id,
        name: "Managed fixture",
        command: "/usr/bin/true",
        workingDirectory: "/tmp",
        expectedPorts: []
    )
}

private func successfulGroupRunner() -> MockCommandRunner {
    MockCommandRunner { _, _ in
        .init(stdout: Data(), stderr: Data(), exitCode: 0)
    }
}
