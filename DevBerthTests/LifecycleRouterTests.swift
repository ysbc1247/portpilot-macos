import XCTest
@testable import DevBerth

final class LifecycleRouterTests: XCTestCase {
    func testExternalStopUsesGuardedFingerprintController() async throws {
        let processController = RecordingProcessController()
        let managedController = RecordingLaunchController()
        let dockerController = RecordingDockerController()
        let router = OwnerAwareLifecycleRouter(
            processController: processController,
            managedServiceController: managedController,
            dockerController: dockerController,
            runtimeRegistry: ManagedRuntimeRegistry()
        )
        let graph = lifecycleGraph(
            controller: .guardedExternalProcess,
            supportedActions: [.inspect, .gracefulStop, .forceStop]
        )

        let result = try await router.perform(.gracefulStop, on: graph, forceConfirmed: false)
        let processActions = await processController.actions()
        let managedStops = await managedController.stops()
        let dockerActions = await dockerController.actions()

        XCTAssertTrue(result.didStop)
        XCTAssertEqual(result.controllerKind, .guardedExternalProcess)
        XCTAssertEqual(processActions, ["graceful"])
        XCTAssertTrue(managedStops.isEmpty)
        XCTAssertTrue(dockerActions.isEmpty)
    }

    func testDockerStopAndRestartNeverUseHostPIDController() async throws {
        let processController = RecordingProcessController()
        let dockerController = RecordingDockerController()
        let router = OwnerAwareLifecycleRouter(
            processController: processController,
            managedServiceController: RecordingLaunchController(),
            dockerController: dockerController,
            runtimeRegistry: ManagedRuntimeRegistry()
        )
        let graph = lifecycleGraph(
            controller: .dockerContainer,
            supportedActions: [.inspect, .gracefulStop, .restart],
            docker: .init(
                containerID: "container-123",
                containerName: "demo-api",
                image: "demo/api:latest",
                composeProject: nil,
                composeService: nil,
                containerPort: 8080
            )
        )

        _ = try await router.perform(.gracefulStop, on: graph, forceConfirmed: false)
        let restarted = try await router.perform(.restart, on: graph, forceConfirmed: false)
        let dockerActions = await dockerController.actions()
        let processActions = await processController.actions()

        XCTAssertEqual(dockerActions, ["stop:container-123", "restart:container-123"])
        XCTAssertTrue(processActions.isEmpty)
        XCTAssertEqual(restarted.action, .restart)
        XCTAssertFalse(restarted.didStop)
    }

    func testComposeActionIsRefusedWithoutVerifiedProjectContext() async throws {
        let processController = RecordingProcessController()
        let dockerController = RecordingDockerController()
        let router = OwnerAwareLifecycleRouter(
            processController: processController,
            managedServiceController: RecordingLaunchController(),
            dockerController: dockerController,
            runtimeRegistry: ManagedRuntimeRegistry()
        )
        let graph = lifecycleGraph(
            controller: .dockerComposeService,
            supportedActions: [.inspect],
            category: .dockerComposeService
        )

        do {
            _ = try await router.perform(.gracefulStop, on: graph, forceConfirmed: false)
            XCTFail("Expected unverified Compose context to be refused")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("unavailable"))
        }
        let processActions = await processController.actions()
        let dockerActions = await dockerController.actions()
        XCTAssertTrue(processActions.isEmpty)
        XCTAssertTrue(dockerActions.isEmpty)
    }

    func testVerifiedComposeRestartRoutesToExactContextWithoutHostPIDSignal() async throws {
        let processController = RecordingProcessController()
        let dockerController = RecordingDockerController()
        let context = lifecycleComposeContext()
        let router = OwnerAwareLifecycleRouter(
            processController: processController,
            managedServiceController: RecordingLaunchController(),
            dockerController: dockerController,
            runtimeRegistry: ManagedRuntimeRegistry()
        )
        let graph = lifecycleGraph(
            controller: .dockerComposeService,
            supportedActions: [.inspect, .gracefulStop, .restart, .remove],
            category: .dockerComposeService,
            docker: .init(
                containerID: context.containerID,
                containerName: "demo-api-1",
                image: "demo/api:latest",
                composeProject: context.projectName,
                composeService: context.serviceName,
                containerPort: 3000,
                composeContext: context
            )
        )

        let result = try await router.perform(.restart, on: graph, forceConfirmed: false)
        let dockerActions = await dockerController.actions()
        let processActions = await processController.actions()

        XCTAssertEqual(dockerActions, ["compose-restart:demo/api:\(context.containerID)"])
        XCTAssertTrue(processActions.isEmpty)
        XCTAssertEqual(result.controllerKind, .dockerComposeService)
        XCTAssertFalse(result.didStop)
    }

    func testManagedStopUsesRegisteredServicePolicy() async throws {
        let registry = ManagedRuntimeRegistry()
        let managedController = RecordingLaunchController()
        let serviceID = UUID()
        let runtimeID = UUID()
        let leader = makeProcess(pid: 500).fingerprint
        let runtime = ManagedRuntimeHandle(
            id: runtimeID,
            managedServiceID: serviceID,
            leaderFingerprint: leader,
            processGroupID: 500,
            processPolicy: .controlledProcessGroup,
            launchedAt: leader.detectedAt
        )
        let snapshot = ProcessGroupSnapshot(
            runtimeID: runtimeID,
            managedServiceID: serviceID,
            processGroupID: 500,
            leaderFingerprint: leader,
            members: [.init(fingerprint: leader, processGroupID: 500, role: .leader, isInControlledGroup: true)]
        )
        let configuration = ManagedServiceConfiguration(
            id: serviceID,
            name: "Managed API",
            command: "/usr/bin/true",
            workingDirectory: "/tmp",
            shutdownTimeoutSeconds: 7
        )
        await registry.register(runtime: runtime, configuration: configuration, snapshot: snapshot)
        let router = OwnerAwareLifecycleRouter(
            processController: RecordingProcessController(),
            managedServiceController: managedController,
            dockerController: RecordingDockerController(),
            runtimeRegistry: registry
        )
        let graph = lifecycleGraph(
            controller: .managedProcess,
            supportedActions: [.inspect, .gracefulStop],
            category: .applicationManagedProcess,
            managedRuntimeID: runtimeID,
            managedServiceID: serviceID
        )

        let result = try await router.perform(.gracefulStop, on: graph, forceConfirmed: false)
        let stops = await managedController.stops()

        XCTAssertTrue(result.didStop)
        XCTAssertEqual(stops, [.init(serviceID: serviceID, timeout: 7)])
    }

    func testManagedStopRefusesStaleRuntimeRegistration() async throws {
        let registry = ManagedRuntimeRegistry()
        let managedController = RecordingLaunchController()
        let router = OwnerAwareLifecycleRouter(
            processController: RecordingProcessController(),
            managedServiceController: managedController,
            dockerController: RecordingDockerController(),
            runtimeRegistry: registry
        )
        let graph = lifecycleGraph(
            controller: .managedProcess,
            supportedActions: [.inspect, .gracefulStop],
            category: .applicationManagedProcess,
            managedRuntimeID: UUID(),
            managedServiceID: UUID()
        )

        await XCTAssertThrowsLifecycleError(
            try await router.perform(.gracefulStop, on: graph, forceConfirmed: false)
        )
        let stops = await managedController.stops()
        XCTAssertTrue(stops.isEmpty)
    }

    func testManagedRestartStopsRegisteredRuntimeAndLaunchesExactConfiguration() async throws {
        let registry = ManagedRuntimeRegistry()
        let managedController = RecordingLaunchController()
        let serviceID = UUID()
        let runtimeID = UUID()
        let leader = makeProcess(pid: 885).fingerprint
        let runtime = ManagedRuntimeHandle(
            id: runtimeID,
            managedServiceID: serviceID,
            leaderFingerprint: leader,
            processGroupID: 885,
            processPolicy: .controlledProcessGroup,
            launchedAt: leader.detectedAt
        )
        let snapshot = ProcessGroupSnapshot(
            runtimeID: runtimeID,
            managedServiceID: serviceID,
            processGroupID: 885,
            leaderFingerprint: leader,
            members: [.init(fingerprint: leader, processGroupID: 885, role: .leader, isInControlledGroup: true)]
        )
        let configuration = ManagedServiceConfiguration(
            id: serviceID,
            name: "Verified API",
            command: "/usr/bin/ruby",
            arguments: ["server.rb"],
            workingDirectory: "/tmp",
            shutdownTimeoutSeconds: 9
        )
        await registry.register(runtime: runtime, configuration: configuration, snapshot: snapshot)
        let router = OwnerAwareLifecycleRouter(
            processController: RecordingProcessController(),
            managedServiceController: managedController,
            dockerController: RecordingDockerController(),
            runtimeRegistry: registry
        )
        let graph = lifecycleGraph(
            controller: .managedProcess,
            supportedActions: [.inspect, .gracefulStop, .restart],
            category: .applicationManagedProcess,
            managedRuntimeID: runtimeID,
            managedServiceID: serviceID
        )

        let result = try await router.perform(.restart, on: graph, forceConfirmed: false)

        let stops = await managedController.stops()
        let launches = await managedController.launches()
        XCTAssertTrue(result.didStop)
        XCTAssertEqual(stops, [.init(serviceID: serviceID, timeout: 9)])
        XCTAssertEqual(launches, [configuration])
    }
}

private actor RecordingProcessController: ProcessControlling {
    private var recordedActions: [String] = []

    func terminate(_ target: ProcessActionTarget, mode: TerminationMode) async throws -> TerminationOutcome {
        switch mode {
        case .graceful: recordedActions.append("graceful")
        case let .force(confirmed): recordedActions.append("force:\(confirmed)")
        }
        return .init(pid: target.process.fingerprint.pid, mode: "test", completion: .exited, durationSeconds: 0.01)
    }

    func actions() -> [String] { recordedActions }
}

private actor RecordingLaunchController: LaunchProfileServing {
    struct Stop: Equatable {
        let serviceID: UUID
        let timeout: Double
    }
    private var recordedStops: [Stop] = []
    private var recordedLaunches: [ManagedServiceConfiguration] = []
    func launch(_ profile: ManagedServiceConfiguration) async throws {
        recordedLaunches.append(profile)
    }
    func stop(profileID: UUID, timeoutSeconds: Double) async throws {
        recordedStops.append(.init(serviceID: profileID, timeout: timeoutSeconds))
    }
    func stops() -> [Stop] { recordedStops }
    func launches() -> [ManagedServiceConfiguration] { recordedLaunches }
}

private actor RecordingDockerController: DockerServing {
    private var recordedActions: [String] = []
    func availability() async -> DockerAvailability { .available(version: "test") }
    func runningContainers() async throws -> [DockerContainer] { [] }
    func stop(containerID: String) async throws { recordedActions.append("stop:\(containerID)") }
    func restart(containerID: String) async throws { recordedActions.append("restart:\(containerID)") }
    func remove(containerID: String) async throws { recordedActions.append("remove:\(containerID)") }
    func stopComposeService(context: DockerComposeContext) async throws {
        recordedActions.append("compose-stop:\(context.projectName)/\(context.serviceName):\(context.containerID)")
    }
    func restartComposeService(context: DockerComposeContext) async throws {
        recordedActions.append("compose-restart:\(context.projectName)/\(context.serviceName):\(context.containerID)")
    }
    func removeComposeService(context: DockerComposeContext) async throws {
        recordedActions.append("compose-remove:\(context.projectName)/\(context.serviceName):\(context.containerID)")
    }
    func recentLogs(containerID: String, lines: Int) async throws -> String { "" }
    func actions() -> [String] { recordedActions }
}

private func lifecycleComposeContext() -> DockerComposeContext {
    let identity = ExecutableFileIdentity(deviceID: 1, inode: 2)
    return DockerComposeContext(
        containerID: String(repeating: "a", count: 64),
        projectName: "demo",
        serviceName: "api",
        workingDirectory: .init(path: "/Users/developer/demo", fileIdentity: identity, size: 0, modificationDate: nil),
        configurationFiles: [.init(path: "/Users/developer/demo/compose.yaml", fileIdentity: identity, size: 100, modificationDate: nil)],
        environmentFiles: [],
        configurationHash: "compose-hash",
        verifiedAt: Date(timeIntervalSince1970: 1_750_000_000)
    )
}

private func lifecycleGraph(
    controller: LifecycleControllerKind,
    supportedActions: Set<LifecycleActionKind>,
    category: OwnershipCategory = .standaloneHostProcess,
    docker: DockerAssociation? = nil,
    managedRuntimeID: UUID? = nil,
    managedServiceID: UUID? = nil
) -> RuntimeOwnershipGraph {
    let base = makeListener(port: 8080, pid: 42)
    let process = ObservedProcess(
        fingerprint: base.process.fingerprint,
        name: base.process.name,
        commandLine: base.process.commandLine,
        owner: base.process.owner,
        currentDirectory: base.process.currentDirectory,
        parentName: base.process.parentName,
        runtime: docker == nil ? base.process.runtime : .docker,
        project: base.process.project,
        isSystemProcess: base.process.isSystemProcess,
        docker: docker,
        launchedByDevBerth: managedServiceID != nil,
        managedServiceID: managedServiceID
    )
    let listener = ObservedListener(
        protocolKind: base.protocolKind,
        address: base.address,
        port: base.port,
        process: process,
        firstDetectedAt: base.firstDetectedAt,
        lastDetectedAt: base.lastDetectedAt
    )
    let conclusion = OwnershipConclusion(
        subject: .listener(id: listener.id),
        category: category,
        value: category.title,
        confidence: category == .applicationManagedProcess ? .verified : .stronglyInferred,
        evidence: [],
        detectionMethod: .processLineage
    )
    return RuntimeOwnershipGraph(
        listenerID: listener.id,
        listener: listener,
        processGroupID: 42,
        processLineage: [],
        primaryConclusion: conclusion,
        additionalConclusions: [],
        managedRuntimeID: managedRuntimeID,
        managedServiceID: managedServiceID,
        managedConfigurationDigest: nil,
        projectID: nil,
        workspaceSessionIDs: [],
        recommendation: .init(
            controllerKind: controller,
            title: "Test controller",
            reason: "Test routing reason.",
            supportedActions: supportedActions
        ),
        resolvedAt: Date(timeIntervalSince1970: 1_750_000_000)
    )
}

private func XCTAssertThrowsLifecycleError<T>(
    _ expression: @autoclosure () async throws -> T
) async {
    do {
        _ = try await expression()
        XCTFail("Expected lifecycle route to throw")
    } catch {
        XCTAssertTrue(error.localizedDescription.contains("unavailable"))
    }
}
