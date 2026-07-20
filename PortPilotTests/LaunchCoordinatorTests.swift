import XCTest
@testable import PortPilot

final class LaunchCoordinatorTests: XCTestCase {
    func testConflictPreventsLaunch() async {
        let launcher = RecordingManagedLauncher()
        let coordinator = LaunchCoordinator(
            discoverer: FixedDiscovery(listeners: [makeListener(port: 3000)]),
            processLauncher: launcher,
            healthChecker: PassingHealthChecker()
        )
        let profile = LaunchProfileConfiguration(
            name: "Web", command: "/usr/bin/true", workingDirectory: "/tmp",
            expectedPorts: [.init(id: UUID(), port: 3000, protocolKind: .tcp, required: true)]
        )
        do {
            try await coordinator.launch(profile)
            XCTFail("Expected port conflict")
        } catch let error as PortPilotError {
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
        let profile = LaunchProfileConfiguration(
            name: "Fixture", command: "/usr/bin/true", workingDirectory: "/tmp",
            expectedPorts: [.init(id: UUID(), port: 45678, protocolKind: .tcp, required: true)],
            startupTimeoutSeconds: 1
        )
        try await coordinator.launch(profile)
        let launches = await launcher.launches
        XCTAssertEqual(launches, 1)
    }
}

private struct FixedDiscovery: PortDiscovering {
    let listeners: [NetworkListener]
    func discover() async throws -> [NetworkListener] { listeners }
}

private actor SequencedDiscovery: PortDiscovering {
    var snapshots: [[NetworkListener]]
    init(snapshots: [[NetworkListener]]) { self.snapshots = snapshots }
    func discover() async throws -> [NetworkListener] {
        guard snapshots.count > 1 else { return snapshots.first ?? [] }
        return snapshots.removeFirst()
    }
}

private actor RecordingManagedLauncher: ManagedProcessLaunching {
    private(set) var launches = 0
    func launch(_ profile: LaunchProfileConfiguration) async throws { launches += 1 }
    func stop(profileID: UUID, timeoutSeconds: Double) async throws {}
}

private struct PassingHealthChecker: HealthChecking {
    func waitUntilHealthy(configuration: HealthCheckConfiguration, timeoutSeconds: Double) async throws {}
}
