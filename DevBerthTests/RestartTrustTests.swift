import SwiftData
import XCTest
@testable import DevBerth

final class RestartTrustTests: XCTestCase {
    func testObservedProcessIsInferredOnlyAndWeakFingerprintIsNotRestartable() {
        let strong = makeListener(port: 8080, pid: 42)
        let weakProcess = ObservedProcess(
            fingerprint: ProcessFingerprint(
                pid: 43,
                executablePath: "/usr/bin/node",
                startTime: nil
            ),
            name: "node",
            commandLine: "node server.js",
            owner: "developer",
            currentDirectory: "/tmp",
            parentName: "zsh",
            runtime: .node,
            project: nil,
            isSystemProcess: false,
            docker: nil,
            launchedByDevBerth: false,
            managedServiceID: nil
        )
        let weak = ObservedListener(
            protocolKind: .tcp,
            address: "127.0.0.1",
            port: 8081,
            process: weakProcess,
            firstDetectedAt: Date(),
            lastDetectedAt: Date()
        )

        XCTAssertEqual(
            RestartTrustEvaluator.observedSummary(for: strong).state,
            .inferredRestartCandidate
        )
        XCTAssertEqual(
            RestartTrustEvaluator.observedSummary(for: weak).state,
            .notRestartable
        )
    }

    func testSecretLikePlaintextEnvironmentCannotBeRestartable() {
        let profile = restartTrustProfile(
            environment: ["MODE": "development", "DATABASE_URL": "must-not-appear"]
        )

        let summary = RestartTrustEvaluator.summary(for: profile, validation: nil)

        XCTAssertEqual(summary.state, .notRestartable)
        XCTAssertTrue(summary.reasons.joined().contains("DATABASE_URL"))
        XCTAssertFalse(summary.reasons.joined().contains("must-not-appear"))
    }

    func testReviewedDefinitionIsConditionalUntilExactDigestPassesValidation() {
        var profile = restartTrustProfile()
        let conditional = RestartTrustEvaluator.summary(for: profile, validation: nil)
        let validation = successfulValidation(for: profile)
        let verified = RestartTrustEvaluator.summary(for: profile, validation: validation)
        profile.arguments.append("--changed")
        let changed = RestartTrustEvaluator.summary(for: profile, validation: validation)

        XCTAssertEqual(conditional.state, .conditionallyRestartable)
        XCTAssertEqual(verified.state, .verifiedRestartable)
        XCTAssertEqual(changed.state, .conditionallyRestartable)
        XCTAssertTrue(changed.reasons.joined().contains("changed"))
    }

    func testConfigurationDigestIgnoresPresentationMetadataButIncludesLaunchDefinition() {
        var profile = restartTrustProfile()
        let original = ManagedServiceConfigurationDigest.make(for: profile)
        profile.name = "Renamed"
        profile.tags = ["favorite"]
        profile.isFavorite = true
        XCTAssertEqual(ManagedServiceConfigurationDigest.make(for: profile), original)

        profile.command = "/usr/bin/ruby"
        XCTAssertNotEqual(ManagedServiceConfigurationDigest.make(for: profile), original)
    }

    func testConfigurationDigestChangesWhenReviewedServiceChecksChange() throws {
        var profile = restartTrustProfile()
        let v4CompatibleDigest = ManagedServiceConfigurationDigest.make(for: profile)
        profile.serviceChecks = [ServiceCheckConfiguration(
            kind: .http(
                url: try XCTUnwrap(URL(string: "http://127.0.0.1:49904/health")),
                expectedStatus: 200,
                responseContains: "ready"
            ),
            failureMessage: "Readiness failed."
        )]
        let checkedDigest = ManagedServiceConfigurationDigest.make(for: profile)
        profile.serviceChecks[0].failureMessage = "New reviewed failure guidance."

        XCTAssertNotEqual(checkedDigest, v4CompatibleDigest)
        XCTAssertNotEqual(ManagedServiceConfigurationDigest.make(for: profile), checkedDigest)
    }

    func testValidationRunnerStartsChecksAndStopsIsolatedCandidate() async {
        let launcher = RecordingValidationLauncher()
        let clock = AdvancingValidationClock()
        let runner = ManagedServiceValidationRunner(
            launchService: launcher,
            clock: { clock() }
        )
        let profile = restartTrustProfile()

        let result = await runner.validate(profile)
        let actions = await launcher.actions()

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(actions, ["launch:\(profile.id)", "stop:\(profile.id)"])
        XCTAssertTrue(result.evidence.contains { $0.field == "process scope" && $0.isVerified })
        XCTAssertTrue(result.evidence.contains { $0.field == "required listener" && $0.isVerified })
    }

    func testValidationRunnerRejectsSensitivePlaintextBeforeLaunchWithoutRecordingValue() async {
        let launcher = RecordingValidationLauncher()
        let runner = ManagedServiceValidationRunner(launchService: launcher)
        let profile = restartTrustProfile(environment: ["API_TOKEN": "private-value"])

        let result = await runner.validate(profile)
        let actions = await launcher.actions()
        let recordedText = ([result.summary] + result.evidence.map(\.detail)).joined(separator: " ")

        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(actions.isEmpty)
        XCTAssertTrue(recordedText.contains("API_TOKEN"))
        XCTAssertFalse(recordedText.contains("private-value"))
    }

    @MainActor
    func testAppModelRefusesNormalLaunchUntilExactDefinitionIsVerified() async {
        let store = RecordingRestartTrustStore()
        let model = AppModel(
            discoverer: EmptyRestartTrustDiscoverer(),
            restartTrustStore: store
        )
        let profile = restartTrustProfile()

        await model.launchProfile(profile)

        XCTAssertFalse(model.runningProfileIDs.contains(profile.id))
        XCTAssertTrue(model.profileFailures[profile.id]?.contains("not verified restartable") == true)
        XCTAssertTrue(model.presentedError?.localizedDescription.contains("not verified restartable") == true)
    }

    @MainActor
    func testPresentationOnlyEditPreservesExistingExactValidationAssessment() async throws {
        let store = RecordingRestartTrustStore()
        let model = AppModel(
            discoverer: EmptyRestartTrustDiscoverer(),
            restartTrustStore: store
        )
        var profile = restartTrustProfile()
        let validation = successfulValidation(for: profile)
        try await store.record(validation)
        profile.name = "Renamed without launch drift"

        try await model.recordRestartTrust(for: profile, validation: nil)

        let assessment = await store.latestAssessment()
        XCTAssertEqual(assessment?.state, .verifiedRestartable)
        XCTAssertEqual(assessment?.evidenceIDs, [validation.id])
    }

    @MainActor
    func testManagedRestartRefusesWhenActiveRuntimeDefinitionDiffersFromCurrentVerifiedProfile() async throws {
        let store = RecordingRestartTrustStore()
        var currentProfile = restartTrustProfile()
        let activeDigest = ManagedServiceConfigurationDigest.make(for: currentProfile)
        currentProfile.arguments.append("--new-definition")
        try await store.record(successfulValidation(for: currentProfile))
        let listener = managedRestartListener(serviceID: currentProfile.id)
        let graph = managedRestartGraph(
            listener: listener,
            serviceID: currentProfile.id,
            activeDigest: activeDigest
        )
        let router = RecordingRestartLifecycleRouter()
        let model = AppModel(
            discoverer: EmptyRestartTrustDiscoverer(),
            restartTrustStore: store,
            ownershipResolver: FixedRestartOwnershipResolver(graph: graph),
            lifecycleRouter: router
        )

        await model.restartOwnedRuntime(listener, verifiedConfiguration: currentProfile)

        let routedActions = await router.actions()
        XCTAssertTrue(routedActions.isEmpty)
        XCTAssertTrue(model.presentedError?.localizedDescription.contains("different definition") == true)
    }

    @MainActor
    func testV4StoreUpsertsValidationAndTrustAssessment() async throws {
        let schema = Schema(DevBerthSchemaV4.models)
        let configuration = ModelConfiguration(
            "RestartTrustStoreTests",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(
            for: schema,
            migrationPlan: DevBerthMigrationPlan.self,
            configurations: [configuration]
        )
        let store = SwiftDataStore(modelContainer: container)
        let profile = restartTrustProfile()
        let first = successfulValidation(for: profile)
        let second = ManagedServiceValidationResult(
            id: UUID(),
            managedServiceID: profile.id,
            configurationDigest: first.configurationDigest,
            status: .succeeded,
            summary: "newest result",
            evidence: [],
            startedAt: first.startedAt.addingTimeInterval(10),
            completedAt: first.completedAt.addingTimeInterval(10)
        )
        let assessment = RestartTrustEvaluator.assessment(for: profile, validation: second)

        try await store.record(first)
        try await store.record(second)
        try await store.record(assessment)

        let fetched = try await store.latestValidation(for: profile.id)
        let context = ModelContext(container)
        let validations = try context.fetch(FetchDescriptor<ManagedServiceValidationRecord>())
        let assessments = try context.fetch(FetchDescriptor<ManagedServiceTrustRecord>())
        XCTAssertEqual(fetched?.id, second.id)
        XCTAssertEqual(validations.count, 1)
        XCTAssertEqual(assessments.count, 1)
        XCTAssertEqual(assessments[0].stateRawValue, RestartTrustState.verifiedRestartable.rawValue)
    }

    @MainActor
    func testGenuineV3StoreMigratesToV4WithoutInventingValidation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevBerth-V3-to-V4-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("migration.store")
        let profileID = UUID()

        try createV3TrustFixture(at: storeURL, profileID: profileID)

        let schema = Schema(DevBerthSchemaV4.models)
        let configuration = ModelConfiguration("V4Migration", schema: schema, url: storeURL)
        let container = try ModelContainer(
            for: schema,
            migrationPlan: DevBerthMigrationPlan.self,
            configurations: [configuration]
        )
        let context = ModelContext(container)
        XCTAssertEqual(try context.fetch(FetchDescriptor<LaunchProfileRecord>()).map(\.id), [profileID])
        XCTAssertTrue(try context.fetch(FetchDescriptor<ManagedServiceValidationRecord>()).isEmpty)
    }

    @MainActor
    private func createV3TrustFixture(at storeURL: URL, profileID: UUID) throws {
        let schema = Schema(DevBerthSchemaV3.models)
        let configuration = ModelConfiguration("V3TrustFixture", schema: schema, url: storeURL)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        context.insert(LaunchProfileRecord(
            id: profileID,
            name: "Existing service",
            command: "/usr/bin/python3",
            workingDirectory: "/tmp"
        ))
        try context.save()
    }
}

private actor EmptyRestartTrustDiscoverer: PortDiscovering {
    func discover() async throws -> [ObservedListener] { [] }
}

private actor RecordingRestartTrustStore: RestartTrustStoring {
    private var validations: [UUID: ManagedServiceValidationResult] = [:]
    private var assessment: RestartTrustAssessment?

    func record(_ validation: ManagedServiceValidationResult) async throws {
        validations[validation.managedServiceID] = validation
    }

    func record(_ assessment: RestartTrustAssessment) async throws {
        self.assessment = assessment
    }

    func latestValidation(for managedServiceID: UUID) async throws -> ManagedServiceValidationResult? {
        validations[managedServiceID]
    }

    func latestAssessment() -> RestartTrustAssessment? { assessment }
}

private struct FixedRestartOwnershipResolver: RuntimeOwnershipResolving {
    let graph: RuntimeOwnershipGraph
    func resolve(listener: ObservedListener) async -> RuntimeOwnershipGraph { graph }
}

private actor RecordingRestartLifecycleRouter: OwnerAwareLifecycleRouting {
    private var recordedActions: [LifecycleActionKind] = []

    func perform(
        _ action: LifecycleActionKind,
        on graph: RuntimeOwnershipGraph,
        forceConfirmed: Bool
    ) async throws -> OwnerAwareLifecycleResult {
        recordedActions.append(action)
        return .init(
            controllerKind: graph.recommendation.controllerKind,
            action: action,
            didStop: true,
            summary: "test",
            durationSeconds: 0
        )
    }

    func actions() -> [LifecycleActionKind] { recordedActions }
}

private actor RecordingValidationLauncher: LaunchProfileServing {
    private var recordedActions: [String] = []
    func launch(_ profile: ManagedServiceConfiguration) async throws {
        recordedActions.append("launch:\(profile.id)")
    }
    func stop(profileID: UUID, timeoutSeconds: Double) async throws {
        recordedActions.append("stop:\(profileID)")
    }
    func actions() -> [String] { recordedActions }
}

private final class AdvancingValidationClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_750_000_000)

    func callAsFunction() -> Date {
        lock.withLock {
            defer { value = value.addingTimeInterval(1) }
            return value
        }
    }
}

private func restartTrustProfile(
    environment: [String: String] = [:]
) -> ManagedServiceConfiguration {
    ManagedServiceConfiguration(
        name: "API",
        launchMechanism: .executable,
        command: "/usr/bin/python3",
        arguments: ["-m", "http.server", "49152"],
        workingDirectory: "/tmp",
        environment: environment,
        expectedPorts: [
            .init(id: UUID(), port: 49_152, protocolKind: .tcp, required: true)
        ],
        isReviewed: true
    )
}

private func successfulValidation(
    for profile: ManagedServiceConfiguration
) -> ManagedServiceValidationResult {
    ManagedServiceValidationResult(
        id: UUID(),
        managedServiceID: profile.id,
        configurationDigest: ManagedServiceConfigurationDigest.make(for: profile),
        status: .succeeded,
        summary: "Validation passed.",
        evidence: [],
        startedAt: Date(timeIntervalSince1970: 1_750_000_000),
        completedAt: Date(timeIntervalSince1970: 1_750_000_010)
    )
}

private func managedRestartListener(serviceID: UUID) -> ObservedListener {
    let base = makeListener(port: 49_152, pid: 912)
    let process = ObservedProcess(
        fingerprint: base.process.fingerprint,
        name: base.process.name,
        commandLine: base.process.commandLine,
        owner: base.process.owner,
        currentDirectory: base.process.currentDirectory,
        parentName: base.process.parentName,
        runtime: base.process.runtime,
        project: base.process.project,
        isSystemProcess: false,
        docker: nil,
        launchedByDevBerth: true,
        managedServiceID: serviceID
    )
    return ObservedListener(
        protocolKind: base.protocolKind,
        address: base.address,
        port: base.port,
        process: process,
        firstDetectedAt: base.firstDetectedAt,
        lastDetectedAt: base.lastDetectedAt
    )
}

private func managedRestartGraph(
    listener: ObservedListener,
    serviceID: UUID,
    activeDigest: String
) -> RuntimeOwnershipGraph {
    let conclusion = OwnershipConclusion(
        subject: .listener(id: listener.id),
        category: .applicationManagedProcess,
        value: "Managed API",
        confidence: .verified,
        evidence: [],
        detectionMethod: .managedRuntimeRegistry
    )
    return RuntimeOwnershipGraph(
        listenerID: listener.id,
        listener: listener,
        processGroupID: 912,
        processLineage: [],
        primaryConclusion: conclusion,
        additionalConclusions: [],
        managedRuntimeID: UUID(),
        managedServiceID: serviceID,
        managedConfigurationDigest: activeDigest,
        projectID: nil,
        workspaceSessionIDs: [],
        recommendation: .init(
            controllerKind: .managedProcess,
            title: "Managed restart",
            reason: "Test",
            supportedActions: [.inspect, .gracefulStop, .restart]
        ),
        resolvedAt: Date()
    )
}
