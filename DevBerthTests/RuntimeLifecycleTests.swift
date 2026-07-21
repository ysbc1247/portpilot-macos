import SwiftData
import XCTest
@testable import DevBerth

final class RuntimeLifecycleTests: XCTestCase {
    func testTrackerSeparatesProcessListenerReadinessAndHealthStates() async throws {
        let recorder = RecordingRuntimeLifecycleRecorder()
        let clock = AdvancingRuntimeClock()
        let tracker = RuntimeLifecycleTracker(recorder: recorder, clock: { clock() })
        let profile = lifecycleProfile()
        let fingerprint = makeProcess(pid: 700).fingerprint
        let handle = ManagedRuntimeHandle(
            id: UUID(),
            managedServiceID: profile.id,
            leaderFingerprint: fingerprint,
            processGroupID: 700,
            processPolicy: .controlledProcessGroup,
            launchedAt: clock()
        )

        await tracker.transition(.launchRequested(profile, trigger: .userAction))
        await tracker.transition(.processSpawned(handle, profile))
        await tracker.transition(.waitingForPorts(serviceID: profile.id, ports: [49_900]))
        await tracker.transition(.listenersReady(serviceID: profile.id, listenerIDs: ["tcp:49900"]))
        let readyStream = await tracker.snapshots()
        var readyIterator = readyStream.makeAsyncIterator()
        let readyValue = await readyIterator.next()
        let readySnapshot = try XCTUnwrap(readyValue)
        XCTAssertEqual(readySnapshot.statuses[profile.id]?.lifecycleState, .waitingForReadiness)
        XCTAssertEqual(readySnapshot.statuses[profile.id]?.healthState, .ready)
        XCTAssertTrue(readySnapshot.statuses[profile.id]?.processRunning == true)
        XCTAssertFalse(readySnapshot.statuses[profile.id]?.isHealthy == true)

        await tracker.transition(.waitingForHealth(serviceID: profile.id, description: "Checking HTTP"))
        await tracker.transition(.healthPassed(serviceID: profile.id, description: "HTTP passed"))
        let healthyStream = await tracker.snapshots()
        var healthyIterator = healthyStream.makeAsyncIterator()
        let healthyValue = await healthyIterator.next()
        let healthySnapshot = try XCTUnwrap(healthyValue)
        XCTAssertEqual(healthySnapshot.statuses[profile.id]?.lifecycleState, .running)
        XCTAssertEqual(healthySnapshot.statuses[profile.id]?.healthState, .healthy)

        let runtimes = await recorder.runtimes()
        let events = await recorder.events()
        XCTAssertEqual(runtimes.last?.id, handle.id)
        XCTAssertEqual(runtimes.last?.healthState, .healthy)
        XCTAssertTrue(events.contains { $0.category == .processSpawned })
        XCTAssertTrue(events.contains { $0.category == .ready })
        XCTAssertTrue(events.contains { $0.category == .healthChanged })
    }

    func testFailureCreatesDeterministicIncidentFromOrderedEvidence() async throws {
        let recorder = RecordingRuntimeLifecycleRecorder()
        let clock = AdvancingRuntimeClock()
        let tracker = RuntimeLifecycleTracker(recorder: recorder, clock: { clock() })
        let profile = lifecycleProfile()

        await tracker.transition(.launchRequested(profile, trigger: .userAction))
        await tracker.transition(.waitingForPorts(serviceID: profile.id, ports: [49_900]))
        await tracker.transition(.launchFailed(
            profile,
            reason: "Expected listener did not open before the timeout."
        ))

        let incidents = await recorder.incidents()
        let incident = try XCTUnwrap(incidents.last)
        XCTAssertEqual(incident.title, "Service failed to start.")
        XCTAssertTrue(incident.cause.contains("Expected listener"))
        XCTAssertGreaterThanOrEqual(incident.steps.count, 2)
        XCTAssertEqual(incident.steps.map(\.timestamp), incident.steps.map(\.timestamp).sorted())
        XCTAssertEqual(Set(incident.steps.map(\.eventID)), Set(incident.relatedEventIDs))
    }

    func testObservedListenerLifecycleStoresSafeStructuredEvidence() async {
        let recorder = RecordingRuntimeLifecycleRecorder()
        let tracker = RuntimeLifecycleTracker(recorder: recorder)
        let listener = makeListener(port: 49_906, pid: 906)

        await tracker.transition(.listenerObserved(listener, change: .discovered))

        let event = await recorder.events().last
        XCTAssertEqual(event?.category, .listenerChanged)
        XCTAssertEqual(event?.source, .monitor)
        XCTAssertEqual(event?.trigger, .observation)
        XCTAssertEqual(event?.details["change"], "discovered")
        XCTAssertEqual(event?.details["port"], "49906")
        XCTAssertEqual(event?.listenerID, listener.id)
        XCTAssertEqual(event?.processFingerprint, listener.process.fingerprint)
        XCTAssertNil(event?.details["commandLine"])
        XCTAssertNil(event?.details["environment"])
    }

    func testRestartPolicyAndCrashLoopLimiterAreDeterministic() {
        let success = RuntimeExitResult(
            exitedAt: Date(),
            exitCode: 0,
            signal: nil,
            reason: nil
        )
        let failure = RuntimeExitResult(
            exitedAt: Date(),
            exitCode: 1,
            signal: nil,
            reason: nil
        )
        XCTAssertFalse(RestartPolicyEvaluator.shouldRestart(policy: .never, result: failure, intentional: false))
        XCTAssertFalse(RestartPolicyEvaluator.shouldRestart(policy: .onFailure, result: success, intentional: false))
        XCTAssertTrue(RestartPolicyEvaluator.shouldRestart(policy: .onFailure, result: failure, intentional: false))
        XCTAssertTrue(RestartPolicyEvaluator.shouldRestart(policy: .always, result: success, intentional: false))
        XCTAssertFalse(RestartPolicyEvaluator.shouldRestart(policy: .always, result: failure, intentional: true))
        XCTAssertEqual((1...4).map { RestartPolicyEvaluator.delaySeconds(forAttempt: $0) }, [1, 2, 4, 8])

        var limiter = AutomaticRestartLimiter(maximumAttempts: 3, windowSeconds: 60)
        let start = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(limiter.registerAttempt(at: start), 1)
        XCTAssertEqual(limiter.registerAttempt(at: start.addingTimeInterval(1)), 2)
        XCTAssertEqual(limiter.registerAttempt(at: start.addingTimeInterval(2)), 3)
        XCTAssertNil(limiter.registerAttempt(at: start.addingTimeInterval(3)))
        XCTAssertEqual(limiter.registerAttempt(at: start.addingTimeInterval(63)), 1)
    }

    @MainActor
    func testV5PersistsLifecycleContextAndPrunesBaseAndSidecarTogether() async throws {
        let schema = Schema(DevBerthSchemaV5.models)
        let configuration = ModelConfiguration(
            "RuntimeLifecyclePersistence",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(
            for: schema,
            migrationPlan: DevBerthMigrationPlan.self,
            configurations: [configuration]
        )
        let context = ModelContext(container)
        let serviceID = UUID()
        for index in 0..<121 {
            let event = LifecycleEvent(
                timestamp: Date(timeIntervalSince1970: Double(index)),
                managedServiceID: serviceID,
                category: .healthChanged,
                outcome: index.isMultiple(of: 2) ? .succeeded : .failed,
                severity: index.isMultiple(of: 2) ? .info : .warning,
                source: .health,
                trigger: .automatic,
                summary: "Health sample \(index)",
                listenerID: "tcp:\(49_000 + index)",
                durationSeconds: 0.01
            )
            context.insert(try LifecycleEventRecord(event: event))
            context.insert(try LifecycleEventContextRecord(event: event))
        }
        try context.save()
        let store = SwiftDataStore(modelContainer: container)

        try await store.pruneLifecycleHistory(retaining: 100)

        let verification = ModelContext(container)
        let events = try verification.fetch(FetchDescriptor<LifecycleEventRecord>())
        let contexts = try verification.fetch(FetchDescriptor<LifecycleEventContextRecord>())
        XCTAssertEqual(events.count, 100)
        XCTAssertEqual(contexts.count, 100)
        XCTAssertEqual(Set(events.map(\.id)), Set(contexts.map(\.lifecycleEventID)))
    }

    @MainActor
    func testGenuineV4StoreMigratesToV5WithoutLosingVerifiedProfile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevBerth-V4-to-V5-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("migration.store")
        let profile = lifecycleProfile()

        do {
            let schema = Schema(DevBerthSchemaV4.models)
            let configuration = ModelConfiguration("V4Fixture", schema: schema, url: storeURL)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            context.insert(LaunchProfileRecord(
                id: profile.id,
                name: profile.name,
                command: profile.command,
                workingDirectory: profile.workingDirectory
            ))
            context.insert(try ManagedServiceValidationRecord(result: successfulLifecycleValidation(for: profile)))
            try context.save()
        }

        let schema = Schema(DevBerthSchemaV5.models)
        let configuration = ModelConfiguration("V5Migration", schema: schema, url: storeURL)
        let container = try ModelContainer(
            for: schema,
            migrationPlan: DevBerthMigrationPlan.self,
            configurations: [configuration]
        )
        let context = ModelContext(container)
        XCTAssertEqual(try context.fetch(FetchDescriptor<LaunchProfileRecord>()).map(\.id), [profile.id])
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<ManagedServiceValidationRecord>()).map(\.managedServiceID),
            [profile.id]
        )
        XCTAssertTrue(try context.fetch(FetchDescriptor<LifecycleEventContextRecord>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<RuntimeIncidentSummaryRecord>()).isEmpty)
    }

    @MainActor
    func testGenuineV5StoreMigratesToV6WithEmptyServiceChecks() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevBerth-V5-to-V6-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("migration.store")
        let serviceID = UUID()

        do {
            let schema = Schema(DevBerthSchemaV5.models)
            let configuration = ModelConfiguration("V5Fixture", schema: schema, url: storeURL)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            context.insert(LaunchProfileRecord(
                id: serviceID,
                name: "V5 service",
                command: "/usr/bin/true",
                workingDirectory: "/tmp"
            ))
            try context.save()
        }

        let schema = Schema(DevBerthSchemaV6.models)
        let configuration = ModelConfiguration("V6Migration", schema: schema, url: storeURL)
        let container = try ModelContainer(
            for: schema,
            migrationPlan: DevBerthMigrationPlan.self,
            configurations: [configuration]
        )
        let context = ModelContext(container)
        XCTAssertEqual(try context.fetch(FetchDescriptor<LaunchProfileRecord>()).map(\.id), [serviceID])
        XCTAssertTrue(try context.fetch(FetchDescriptor<ManagedServiceCheckRecord>()).isEmpty)
    }
}

private actor RecordingRuntimeLifecycleRecorder: RuntimeLifecycleRecording {
    private var recordedRuntimes: [RuntimeInstance] = []
    private var recordedEvents: [LifecycleEvent] = []
    private var recordedIncidents: [RuntimeIncidentSummary] = []

    func record(_ runtime: RuntimeInstance) async throws { recordedRuntimes.append(runtime) }
    func record(_ event: LifecycleEvent) async throws { recordedEvents.append(event) }
    func record(_ incident: RuntimeIncidentSummary) async throws { recordedIncidents.append(incident) }
    func runtimes() -> [RuntimeInstance] { recordedRuntimes }
    func events() -> [LifecycleEvent] { recordedEvents }
    func incidents() -> [RuntimeIncidentSummary] { recordedIncidents }
}

private final class AdvancingRuntimeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_760_000_000)

    func callAsFunction() -> Date {
        lock.withLock {
            defer { value = value.addingTimeInterval(1) }
            return value
        }
    }
}

private func lifecycleProfile() -> ManagedServiceConfiguration {
    ManagedServiceConfiguration(
        name: "Lifecycle API",
        launchMechanism: .executable,
        command: "/usr/bin/python3",
        arguments: ["-m", "http.server", "49900"],
        workingDirectory: "/tmp",
        expectedPorts: [
            .init(id: UUID(), port: 49_900, protocolKind: .tcp, required: true)
        ],
        isReviewed: true
    )
}

private func successfulLifecycleValidation(
    for profile: ManagedServiceConfiguration
) -> ManagedServiceValidationResult {
    ManagedServiceValidationResult(
        id: UUID(),
        managedServiceID: profile.id,
        configurationDigest: ManagedServiceConfigurationDigest.make(for: profile),
        status: .succeeded,
        summary: "Validation passed.",
        evidence: [],
        startedAt: Date(timeIntervalSince1970: 1_760_000_000),
        completedAt: Date(timeIntervalSince1970: 1_760_000_010)
    )
}
