import XCTest
@testable import DevBerth

final class WorkspaceSessionTests: XCTestCase {
    func testCaptureStoresRunningStoppedPortsHealthAndLifecycleEvidence() async throws {
        let projectID = UUID()
        let web = service(name: "Web", projectID: projectID, port: 3000)
        let worker = service(name: "Worker", projectID: projectID)
        let recorder = SessionMockRecorder()
        let coordinator = makeCoordinator(recorder: recorder)
        let state = WorkspaceSessionCurrentState(
            runningServiceIDs: [web.id],
            healthStates: [web.id: .healthy],
            listeners: [managedListener(serviceID: web.id, port: 4310)],
            selectedProjectRootPaths: ["/tmp"]
        )

        let session = try await coordinator.capture(
            name: "Development",
            projectIDs: [projectID],
            services: [worker, web],
            currentState: state,
            notes: " Current state "
        )

        XCTAssertEqual(session.notes, "Current state")
        let webSnapshot = try XCTUnwrap(session.serviceSnapshots.first { $0.managedServiceID == web.id })
        let workerSnapshot = try XCTUnwrap(session.serviceSnapshots.first { $0.managedServiceID == worker.id })
        XCTAssertEqual(webSnapshot.expectedState, .running)
        XCTAssertEqual(webSnapshot.expectedListeners.map(\.port), [4310])
        XCTAssertEqual(webSnapshot.previousHealthState, .healthy)
        XCTAssertEqual(workerSnapshot.expectedState, .stopped)
        let recordedSessionCount = await recorder.sessionCount()
        let capturedCategories = await recorder.lifecycleCategories()
        XCTAssertEqual(recordedSessionCount, 1)
        XCTAssertEqual(capturedCategories, [.sessionCapture])
    }

    func testPreviewReportsEveryUnsafePreflightConditionWithoutLaunching() async throws {
        let missingID = UUID()
        let secretID = UUID()
        let unsafe = ManagedServiceConfiguration(
            name: "Unsafe API",
            command: "definitely-missing-command",
            workingDirectory: "/definitely/missing/session-root",
            secretReferences: ["API_TOKEN": secretID],
            expectedPorts: [.init(id: UUID(), port: 4777, protocolKind: .tcp, required: true)]
        )
        let session = WorkspaceSession(
            name: "Unsafe",
            projectIDs: [],
            serviceSnapshots: [
                snapshot(unsafe, digest: "captured-old-digest"),
                WorkspaceSessionServiceSnapshot(
                    managedServiceID: missingID,
                    expectedState: .running,
                    expectedListeners: [],
                    dependencyServiceIDs: [],
                    previousHealthState: .unknown,
                    configurationDigest: "missing"
                )
            ]
        )
        let discoverer = SessionMockDiscoverer(listeners: [makeListener(port: 4777, pid: 900)])
        let launcher = SessionMockLauncher()
        let coordinator = WorkspaceSessionCoordinator(
            launcher: launcher,
            trustStore: SessionMockTrustStore(),
            secrets: SessionMockSecretStore(),
            listenerDiscoverer: discoverer
        )

        let plan = try await coordinator.preview(session: session, services: [unsafe], runningServiceIDs: [])
        let kinds = Set(plan.issues.map(\.kind))
        XCTAssertTrue(kinds.isSuperset(of: [
            .configurationDrift, .missingWorkingDirectory, .missingExecutable,
            .missingSecret, .occupiedPort, .unverifiedDefinition, .missingService
        ]))
        XCTAssertFalse(plan.blockingIssues.isEmpty)
        let unsafeLaunchAttempts = await launcher.launchAttempts()
        XCTAssertTrue(unsafeLaunchAttempts.isEmpty)
    }

    func testDryRunRecordsPlanAndNeverMutatesRuntimeEvenWhenBlocked() async throws {
        let unavailable = ManagedServiceConfiguration(
            name: "Unavailable",
            command: "missing",
            workingDirectory: "/missing"
        )
        let session = WorkspaceSession(
            name: "Dry run",
            projectIDs: [],
            serviceSnapshots: [snapshot(unavailable)]
        )
        let launcher = SessionMockLauncher()
        let recorder = SessionMockRecorder()
        let coordinator = WorkspaceSessionCoordinator(
            launcher: launcher,
            trustStore: SessionMockTrustStore(),
            secrets: SessionMockSecretStore(),
            listenerDiscoverer: SessionMockDiscoverer(),
            recorder: recorder,
            lifecycleRecorder: recorder
        )

        let execution = try await coordinator.restore(
            session: session,
            services: [unavailable],
            runningServiceIDs: [],
            options: SessionRestoreOptions(dryRun: true)
        )

        XCTAssertEqual(execution.result.outcome, .dryRun)
        XCTAssertTrue(execution.result.startedServiceIDs.isEmpty)
        XCTAssertFalse(execution.plan.blockingIssues.isEmpty)
        let dryRunLaunchAttempts = await launcher.launchAttempts()
        let restoreOutcomes = await recorder.restoreOutcomes()
        let dryRunCategories = await recorder.lifecycleCategories()
        XCTAssertTrue(dryRunLaunchAttempts.isEmpty)
        XCTAssertEqual(restoreOutcomes, [.dryRun])
        XCTAssertEqual(dryRunCategories, [.sessionRestore, .sessionRestore])
    }

    func testRestoreParallelizesIndependentServicesThenWaitsForDependencyLayer() async throws {
        let database = service(name: "Database")
        let cache = service(name: "Cache")
        let api = service(name: "API", dependencies: [database.id])
        let services = [api, cache, database]
        let session = WorkspaceSession(
            name: "Stack",
            projectIDs: [],
            serviceSnapshots: services.map { snapshot($0) }
        )
        let launcher = SessionMockLauncher(delayNanoseconds: 30_000_000)
        let coordinator = makeCoordinator(launcher: launcher, verifiedServices: services)

        let execution = try await coordinator.restore(
            session: session,
            services: services,
            runningServiceIDs: [],
            options: SessionRestoreOptions()
        )

        XCTAssertEqual(execution.result.outcome, .succeeded)
        XCTAssertEqual(Set(execution.result.startedServiceIDs), Set(services.map(\.id)))
        let activity = await launcher.activity()
        XCTAssertGreaterThanOrEqual(activity.maximumConcurrentLaunches, 2)
        let apiBegin = try XCTUnwrap(activity.events.firstIndex(of: "begin:API"))
        let databaseEnd = try XCTUnwrap(activity.events.firstIndex(of: "end:Database"))
        XCTAssertGreaterThan(apiBegin, databaseEnd)
    }

    func testFailedDependencyLayerPreventsDependentLaunchAndRollsBackSuccessfulSibling() async throws {
        let database = service(name: "Database")
        let cache = service(name: "Cache")
        let api = service(name: "API", dependencies: [database.id])
        let services = [database, cache, api]
        let launcher = SessionMockLauncher(
            failingLaunchIDs: [database.id],
            delayNanoseconds: 10_000_000
        )
        let recorder = SessionMockRecorder()
        let coordinator = makeCoordinator(launcher: launcher, verifiedServices: services, recorder: recorder)
        let session = WorkspaceSession(
            name: "Failure",
            projectIDs: [],
            serviceSnapshots: services.map { snapshot($0) }
        )

        let execution = try await coordinator.restore(
            session: session,
            services: services,
            runningServiceIDs: [],
            options: SessionRestoreOptions()
        )

        XCTAssertEqual(execution.result.outcome, .failed)
        XCTAssertEqual(execution.result.startedServiceIDs, [cache.id])
        XCTAssertEqual(execution.result.rolledBackServiceIDs, [cache.id])
        let launchAttempts = await launcher.launchAttempts()
        let stopAttempts = await launcher.stopAttempts()
        XCTAssertFalse(launchAttempts.contains(api.id))
        XCTAssertEqual(stopAttempts, [cache.id])
        let categories = await recorder.lifecycleCategories()
        XCTAssertTrue(categories.contains(.sessionRollback))
    }

    func testPartialRollbackIsReportedWhenStartedServiceCannotStop() async throws {
        let first = service(name: "First")
        let failing = service(name: "Failing")
        let services = [first, failing]
        let launcher = SessionMockLauncher(
            failingLaunchIDs: [failing.id],
            failingStopIDs: [first.id]
        )
        let coordinator = makeCoordinator(launcher: launcher, verifiedServices: services)
        let session = WorkspaceSession(
            name: "Rollback",
            projectIDs: [],
            serviceSnapshots: services.map { snapshot($0) }
        )

        let execution = try await coordinator.restore(
            session: session,
            services: services,
            runningServiceIDs: [],
            options: SessionRestoreOptions()
        )

        XCTAssertEqual(execution.result.outcome, .failed)
        XCTAssertEqual(execution.result.startedServiceIDs, [first.id])
        XCTAssertTrue(execution.result.rolledBackServiceIDs.isEmpty)
        XCTAssertTrue(execution.result.errors.contains { $0.contains("Rollback could not stop First") })
    }

    func testDecliningExpectedStoppedMutationDoesNotRollBackSuccessfulStarts() async throws {
        let starting = service(name: "Starting")
        let leftRunning = service(name: "Left Running")
        let launcher = SessionMockLauncher()
        let coordinator = makeCoordinator(launcher: launcher, verifiedServices: [starting])
        let session = WorkspaceSession(
            name: "Selective",
            projectIDs: [],
            serviceSnapshots: [
                snapshot(starting),
                WorkspaceSessionServiceSnapshot(
                    managedServiceID: leftRunning.id,
                    expectedState: .stopped,
                    expectedListeners: [],
                    dependencyServiceIDs: [],
                    previousHealthState: .healthy,
                    configurationDigest: ManagedServiceConfigurationDigest.make(for: leftRunning)
                )
            ]
        )
        let preview = try await coordinator.preview(
            session: session,
            services: [starting, leftRunning],
            runningServiceIDs: [leftRunning.id]
        )

        let execution = try await coordinator.restore(
            session: session,
            services: [starting, leftRunning],
            runningServiceIDs: [leftRunning.id],
            options: SessionRestoreOptions(
                applyExpectedStoppedState: false,
                confirmedIssueIDs: Set(preview.confirmationIssues.map(\.id))
            )
        )

        XCTAssertEqual(execution.result.outcome, .partiallySucceeded)
        XCTAssertEqual(execution.result.startedServiceIDs, [starting.id])
        XCTAssertTrue(execution.result.rolledBackServiceIDs.isEmpty)
        let stopAttempts = await launcher.stopAttempts()
        XCTAssertTrue(stopAttempts.isEmpty)
    }

    func testPreviewBlocksDependencyCycle() async throws {
        let firstID = UUID()
        let secondID = UUID()
        let first = service(id: firstID, name: "First", dependencies: [secondID])
        let second = service(id: secondID, name: "Second", dependencies: [firstID])
        let services = [first, second]
        let coordinator = makeCoordinator(verifiedServices: services)
        let session = WorkspaceSession(
            name: "Cycle",
            projectIDs: [],
            serviceSnapshots: services.map { snapshot($0) }
        )

        let plan = try await coordinator.preview(session: session, services: services, runningServiceIDs: [])

        XCTAssertTrue(plan.blockingIssues.contains { $0.kind == .dependencyCycle })
        XCTAssertTrue(plan.orderedStartLayers.isEmpty)
    }

    func testBlockedRestoreRecordsFailureWithoutMutatingRuntime() async throws {
        let unverified = service(name: "Unverified")
        let launcher = SessionMockLauncher()
        let recorder = SessionMockRecorder()
        let coordinator = makeCoordinator(launcher: launcher, recorder: recorder)
        let session = WorkspaceSession(
            name: "Blocked",
            projectIDs: [],
            serviceSnapshots: [snapshot(unverified)]
        )

        do {
            _ = try await coordinator.restore(
                session: session,
                services: [unverified],
                runningServiceIDs: [],
                options: SessionRestoreOptions()
            )
            XCTFail("Expected an unverified definition to block restore")
        } catch let error as WorkspaceSessionRestoreError {
            guard case .blocked = error else { return XCTFail("Expected blocked restore") }
        }

        let outcomes = await recorder.restoreOutcomes()
        let launchAttempts = await launcher.launchAttempts()
        let stopAttempts = await launcher.stopAttempts()
        XCTAssertEqual(outcomes, [.failed])
        XCTAssertTrue(launchAttempts.isEmpty)
        XCTAssertTrue(stopAttempts.isEmpty)
    }

    func testComparisonShowsAddedMissingPortsHealthDriftAndProjectScopedUnexpectedListener() async {
        let projectID = UUID()
        let saved = service(name: "Saved", projectID: projectID, port: 3000)
        let added = service(name: "Added", projectID: projectID)
        let missingID = UUID()
        let session = WorkspaceSession(
            name: "Compare",
            projectIDs: [projectID],
            serviceSnapshots: [
                WorkspaceSessionServiceSnapshot(
                    managedServiceID: saved.id,
                    expectedState: .running,
                    expectedListeners: saved.expectedPorts,
                    dependencyServiceIDs: [],
                    previousHealthState: .healthy,
                    configurationDigest: "old-digest"
                ),
                WorkspaceSessionServiceSnapshot(
                    managedServiceID: missingID,
                    expectedState: .stopped,
                    expectedListeners: [],
                    dependencyServiceIDs: [],
                    previousHealthState: .stopped,
                    configurationDigest: "missing"
                )
            ]
        )
        let current = WorkspaceSessionCurrentState(
            runningServiceIDs: [saved.id],
            healthStates: [saved.id: .degraded],
            listeners: [
                managedListener(serviceID: saved.id, port: 4000),
                projectListener(rootPath: "/tmp/workspace", port: 4555),
                projectListener(rootPath: "/tmp/unrelated", port: 4666)
            ],
            selectedProjectRootPaths: ["/tmp/workspace"]
        )
        let coordinator = makeCoordinator()

        let comparison = await coordinator.compare(
            session: session,
            services: [saved, added],
            currentState: current
        )

        XCTAssertEqual(comparison.addedServiceIDs, [added.id])
        XCTAssertEqual(comparison.missingServiceIDs, [missingID])
        XCTAssertEqual(comparison.configurationDriftServiceIDs, [saved.id])
        XCTAssertEqual(comparison.portChanges.first?.currentPorts, Set([UInt16(4000)]))
        XCTAssertEqual(comparison.healthChanges.first?.current, .degraded)
        XCTAssertEqual(comparison.unexpectedListeners.map(\.port), [4555])
    }

    func testPersistenceRecordsRoundTripSessionSnapshotsAndRestoreResult() throws {
        let service = service(name: "Round Trip", port: 8443)
        let session = WorkspaceSession(
            name: "Persisted",
            projectIDs: [UUID()],
            serviceSnapshots: [snapshot(service)],
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            notes: "Evidence"
        )
        let sessionRecord = try WorkspaceSessionRecord(session: session)
        let snapshotRecord = try WorkspaceSessionServiceRecord(
            sessionID: session.id,
            snapshot: try XCTUnwrap(session.serviceSnapshots.first)
        )
        let result = SessionRestoreResult(
            id: UUID(),
            sessionID: session.id,
            startedAt: session.capturedAt,
            finishedAt: session.capturedAt.addingTimeInterval(2),
            outcome: .succeeded,
            startedServiceIDs: [service.id],
            rolledBackServiceIDs: [],
            errors: []
        )
        let resultRecord = try SessionRestoreRecord(result: result)

        XCTAssertEqual(sessionRecord.session(serviceRecords: [snapshotRecord]), session)
        XCTAssertEqual(resultRecord.result, result)
    }

    func testCorruptedSessionSnapshotRefusesPartialRestoreMaterialization() throws {
        let service = service(name: "Corrupt")
        let session = WorkspaceSession(
            name: "Corrupt",
            projectIDs: [],
            serviceSnapshots: [snapshot(service)]
        )
        let sessionRecord = try WorkspaceSessionRecord(session: session)
        let snapshotRecord = try WorkspaceSessionServiceRecord(
            sessionID: session.id,
            snapshot: try XCTUnwrap(session.serviceSnapshots.first)
        )
        snapshotRecord.previousHealthStateRawValue = "not-a-health-state"

        XCTAssertNil(sessionRecord.session(serviceRecords: [snapshotRecord]))
    }

    private func makeCoordinator(
        launcher: SessionMockLauncher = SessionMockLauncher(),
        verifiedServices: [ManagedServiceConfiguration] = [],
        recorder: SessionMockRecorder? = nil
    ) -> WorkspaceSessionCoordinator {
        WorkspaceSessionCoordinator(
            launcher: launcher,
            trustStore: SessionMockTrustStore(verifiedServices: verifiedServices),
            secrets: SessionMockSecretStore(),
            listenerDiscoverer: SessionMockDiscoverer(),
            recorder: recorder,
            lifecycleRecorder: recorder
        )
    }

    private func service(
        id: UUID = UUID(),
        name: String,
        projectID: UUID? = nil,
        port: UInt16? = nil,
        dependencies: [UUID] = []
    ) -> ManagedServiceConfiguration {
        ManagedServiceConfiguration(
            id: id,
            name: name,
            projectID: projectID,
            command: "/usr/bin/true",
            workingDirectory: "/tmp",
            expectedPorts: port.map {
                [.init(id: UUID(), port: $0, protocolKind: .tcp, required: true)]
            } ?? [],
            healthCheck: port == nil ? HealthCheckConfiguration(
                url: URL(string: "http://127.0.0.1/health")!,
                expectedStatus: 200,
                intervalSeconds: 1
            ) : nil,
            dependencyServiceIDs: dependencies
        )
    }

    private func snapshot(
        _ service: ManagedServiceConfiguration,
        digest: String? = nil
    ) -> WorkspaceSessionServiceSnapshot {
        WorkspaceSessionServiceSnapshot(
            managedServiceID: service.id,
            expectedState: .running,
            expectedListeners: service.expectedPorts,
            dependencyServiceIDs: service.dependencyServiceIDs,
            previousHealthState: .healthy,
            configurationDigest: digest ?? ManagedServiceConfigurationDigest.make(for: service)
        )
    }

    private func managedListener(serviceID: UUID, port: UInt16) -> ObservedListener {
        observedListener(serviceID: serviceID, rootPath: nil, port: port)
    }

    private func projectListener(rootPath: String, port: UInt16) -> ObservedListener {
        observedListener(serviceID: nil, rootPath: rootPath, port: port)
    }

    private func observedListener(serviceID: UUID?, rootPath: String?, port: UInt16) -> ObservedListener {
        let process = ObservedProcess(
            fingerprint: ProcessFingerprint(
                pid: Int32(port),
                uid: 501,
                executablePath: "/usr/bin/true",
                startTime: Date(timeIntervalSince1970: 1_700_000_000),
                commandLineDigest: ProcessFingerprint.digest(commandLine: "true"),
                parentPID: 1,
                detectedAt: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            name: "fixture",
            commandLine: "true",
            owner: "developer",
            currentDirectory: rootPath,
            parentName: "zsh",
            runtime: .unknown,
            project: rootPath.map { .init(name: "Fixture", rootPath: $0, evidence: ".git") },
            isSystemProcess: false,
            docker: nil,
            launchedByDevBerth: serviceID != nil,
            managedServiceID: serviceID
        )
        return ObservedListener(
            protocolKind: .tcp,
            address: "127.0.0.1",
            port: port,
            process: process,
            firstDetectedAt: Date(),
            lastDetectedAt: Date()
        )
    }
}

private actor SessionMockLauncher: LaunchProfileServing {
    struct Activity {
        let events: [String]
        let maximumConcurrentLaunches: Int
    }

    private let failingLaunchIDs: Set<UUID>
    private let failingStopIDs: Set<UUID>
    private let delayNanoseconds: UInt64
    private var launches: [UUID] = []
    private var stops: [UUID] = []
    private var events: [String] = []
    private var activeLaunches = 0
    private var maximumConcurrentLaunches = 0

    init(
        failingLaunchIDs: Set<UUID> = [],
        failingStopIDs: Set<UUID> = [],
        delayNanoseconds: UInt64 = 0
    ) {
        self.failingLaunchIDs = failingLaunchIDs
        self.failingStopIDs = failingStopIDs
        self.delayNanoseconds = delayNanoseconds
    }

    func launch(_ profile: ManagedServiceConfiguration) async throws {
        launches.append(profile.id)
        events.append("begin:\(profile.name)")
        activeLaunches += 1
        defer { activeLaunches -= 1 }
        maximumConcurrentLaunches = max(maximumConcurrentLaunches, activeLaunches)
        if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
        if failingLaunchIDs.contains(profile.id) {
            events.append("fail:\(profile.name)")
            throw DevBerthError.unexpected("fixture launch failure")
        }
        events.append("end:\(profile.name)")
    }

    func stop(profileID: UUID, timeoutSeconds: Double) async throws {
        stops.append(profileID)
        if failingStopIDs.contains(profileID) {
            throw DevBerthError.unexpected("fixture stop failure")
        }
    }

    func launchAttempts() -> [UUID] { launches }
    func stopAttempts() -> [UUID] { stops }
    func activity() -> Activity { Activity(events: events, maximumConcurrentLaunches: maximumConcurrentLaunches) }
}

private actor SessionMockTrustStore: RestartTrustStoring {
    private var validations: [UUID: ManagedServiceValidationResult] = [:]

    init(verifiedServices: [ManagedServiceConfiguration] = []) {
        for service in verifiedServices {
            validations[service.id] = ManagedServiceValidationResult(
                id: UUID(),
                managedServiceID: service.id,
                configurationDigest: ManagedServiceConfigurationDigest.make(for: service),
                status: .succeeded,
                summary: "Verified",
                evidence: [],
                startedAt: Date(),
                completedAt: Date()
            )
        }
    }

    func record(_ validation: ManagedServiceValidationResult) async throws {
        validations[validation.managedServiceID] = validation
    }

    func record(_ assessment: RestartTrustAssessment) async throws {}

    func latestValidation(for managedServiceID: UUID) async throws -> ManagedServiceValidationResult? {
        validations[managedServiceID]
    }
}

private actor SessionMockSecretStore: SecretStoring {
    private var values: [UUID: String] = [:]

    func save(value: String, reference: UUID) async throws { values[reference] = value }
    func value(for reference: UUID) async throws -> String? { values[reference] }
    func delete(reference: UUID) async throws { values[reference] = nil }
}

private actor SessionMockDiscoverer: PortDiscovering {
    private let listeners: [ObservedListener]

    init(listeners: [ObservedListener] = []) { self.listeners = listeners }
    func discover() async throws -> [ObservedListener] { listeners }
}

private actor SessionMockRecorder: WorkspaceSessionRecording, RuntimeLifecycleRecording {
    private var sessions: [WorkspaceSession] = []
    private var results: [SessionRestoreResult] = []
    private var events: [LifecycleEvent] = []

    func record(_ session: WorkspaceSession) async throws { sessions.append(session) }
    func record(_ result: SessionRestoreResult) async throws { results.append(result) }
    func record(_ runtime: RuntimeInstance) async throws {}
    func record(_ event: LifecycleEvent) async throws { events.append(event) }
    func record(_ incident: RuntimeIncidentSummary) async throws {}

    func sessionCount() -> Int { sessions.count }
    func restoreOutcomes() -> [SessionRestoreOutcome] { results.map(\.outcome) }
    func lifecycleCategories() -> [LifecycleEventCategory] { events.map(\.category) }
}
