import XCTest
@testable import DevBerth

final class LaunchCoordinatorTests: XCTestCase {
    func testConflictPreventsLaunch() async {
        let launcher = RecordingManagedLauncher()
        let coordinator = LaunchCoordinator(
            discoverer: FixedDiscovery(listeners: [makeListener(port: 3000)]),
            processLauncher: launcher,
            healthChecker: PassingHealthChecker()
        )
        let profile = ManagedServiceConfiguration(
            name: "Web", command: "/usr/bin/true", workingDirectory: "/tmp",
            expectedPorts: [.init(id: UUID(), port: 3000, protocolKind: .tcp, required: true)]
        )
        do {
            try await coordinator.launch(profile)
            XCTFail("Expected port conflict")
        } catch let error as DevBerthError {
            guard case .portConflict(3000) = error else { return XCTFail("Wrong error: \(error)") }
        } catch { XCTFail("Wrong error: \(error)") }
        let launches = await launcher.launches
        XCTAssertEqual(launches, 0)
    }

    func testExpectedPortAllowsSuccessfulLaunch() async throws {
        let launcher = RecordingManagedLauncher()
        let listener = makeListener(port: 45678)
        let discovery = SequencedDiscovery(snapshots: [[], [listener]])
        let coordinator = LaunchCoordinator(discoverer: discovery, processLauncher: launcher, healthChecker: PassingHealthChecker())
        let profile = ManagedServiceConfiguration(
            name: "Fixture", command: "/usr/bin/true", workingDirectory: "/tmp",
            expectedPorts: [.init(id: UUID(), port: 45678, protocolKind: .tcp, required: true)],
            startupTimeoutSeconds: 1
        )
        try await coordinator.launch(profile)
        let launches = await launcher.launches
        XCTAssertEqual(launches, 1)
    }

    func testBackgroundHealthMonitoringRecordsDegradationRecoveryAndStopsAfterExit() async throws {
        let launcher = RecordingManagedLauncher()
        let health = SequencedHealthChecker(outcomes: [true, false, true, true])
        let lifecycle = RecordingLifecycleObserver()
        let coordinator = LaunchCoordinator(
            discoverer: FixedDiscovery(listeners: []),
            processLauncher: launcher,
            healthChecker: health,
            lifecycle: lifecycle
        )
        let profile = ManagedServiceConfiguration(
            name: "Health fixture",
            command: "/usr/bin/true",
            workingDirectory: "/tmp",
            healthCheck: HealthCheckConfiguration(
                url: try XCTUnwrap(URL(string: "http://127.0.0.1:49905/health")),
                expectedStatus: 200,
                intervalSeconds: 0.05
            )
        )

        try await coordinator.launch(profile)
        for _ in 0..<30 {
            if await lifecycle.healthStates().count >= 3 { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        let states = await lifecycle.healthStates()
        XCTAssertEqual(Array(states.prefix(3)), [true, false, true])
        await coordinator.runtimeDidExit(profileID: profile.id)
        let callsAfterExit = await health.callCount()
        try await Task.sleep(for: .milliseconds(400))
        let finalCallCount = await health.callCount()
        XCTAssertEqual(finalCallCount, callsAfterExit)
    }
}

private struct FixedDiscovery: PortDiscovering {
    let listeners: [ObservedListener]
    func discover() async throws -> [ObservedListener] { listeners }
}

private actor SequencedDiscovery: PortDiscovering {
    var snapshots: [[ObservedListener]]
    init(snapshots: [[ObservedListener]]) { self.snapshots = snapshots }
    func discover() async throws -> [ObservedListener] {
        guard snapshots.count > 1 else { return snapshots.first ?? [] }
        return snapshots.removeFirst()
    }
}

private actor RecordingManagedLauncher: ManagedProcessLaunching {
    private(set) var launches = 0
    func launch(_ profile: ManagedServiceConfiguration) async throws { launches += 1 }
    func stop(profileID: UUID, timeoutSeconds: Double) async throws {}
}

private struct PassingHealthChecker: HealthChecking {
    func waitUntilHealthy(configuration: HealthCheckConfiguration, timeoutSeconds: Double) async throws {}
}

private actor SequencedHealthChecker: HealthChecking {
    private var outcomes: [Bool]
    private var calls = 0

    init(outcomes: [Bool]) {
        self.outcomes = outcomes
    }

    func waitUntilHealthy(
        configuration: HealthCheckConfiguration,
        timeoutSeconds: Double
    ) async throws {
        calls += 1
        let succeeded = outcomes.isEmpty ? true : outcomes.removeFirst()
        if !succeeded { throw DevBerthError.healthCheckTimedOut(configuration.url) }
    }

    func callCount() -> Int { calls }
}

private actor RecordingLifecycleObserver: RuntimeLifecycleObserving {
    private var recordedHealthStates: [Bool] = []

    func transition(_ update: RuntimeLifecycleUpdate) async {
        switch update {
        case .healthPassed:
            recordedHealthStates.append(true)
        case .healthDegraded:
            recordedHealthStates.append(false)
        default:
            break
        }
    }

    func snapshots() async -> AsyncStream<RuntimeLifecycleSnapshot> {
        AsyncStream { continuation in continuation.finish() }
    }

    func healthStates() -> [Bool] { recordedHealthStates }
}
