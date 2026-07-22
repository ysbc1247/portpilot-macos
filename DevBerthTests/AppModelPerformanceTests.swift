import Combine
import SwiftData
import XCTest
@testable import DevBerth

@MainActor
final class AppModelPerformanceTests: XCTestCase {
    func testUnchangedScansDoNotRepublishOrPersistLifecycleTransitions() async throws {
        let discoverer = TimestampOnlyDiscovery()
        let lifecycle = CountingLifecycleObserver()
        let model = AppModel(
            discoverer: discoverer,
            runtimeLifecycle: lifecycle,
            processResourceReader: FixedResourceReader(),
            dockerService: EmptyDockerService()
        )
        model.refreshInterval = 0.5
        let publications = LockedCounter()
        let observation = model.objectWillChange.sink { publications.increment() }
        model.startMonitoring()

        try await waitUntil { await discoverer.callCount() >= 2 }
        try await Task.sleep(for: .milliseconds(100))
        publications.reset()
        let transitionBaseline = await lifecycle.listenerTransitionCount()

        try await Task.sleep(for: .milliseconds(1_100))

        let finalTransitionCount = await lifecycle.listenerTransitionCount()
        let finalDiscoveryCount = await discoverer.callCount()
        XCTAssertEqual(publications.value(), 0)
        XCTAssertEqual(finalTransitionCount, transitionBaseline)
        XCTAssertGreaterThanOrEqual(finalDiscoveryCount, 3)
        model.pauseMonitoring()
        observation.cancel()
    }

    func testControlPlaneReadsTheAuthoritativeAppModelSnapshotWithoutScanning() async throws {
        let schema = Schema(DevBerthSchemaV7.models)
        let configuration = ModelConfiguration("SharedMonitoringPipeline", schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: schema,
            migrationPlan: DevBerthMigrationPlan.self,
            configurations: [configuration]
        )
        let discoverer = TimestampOnlyDiscovery()
        let model = AppModel(
            discoverer: discoverer,
            processResourceReader: FixedResourceReader(),
            dockerService: EmptyDockerService()
        )
        model.refreshInterval = 0.5
        model.startMonitoring()
        try await waitUntil { await discoverer.callCount() >= 1 }
        model.pauseMonitoring()
        try await Task.sleep(for: .milliseconds(100))
        let callsBeforeControlRead = await discoverer.callCount()
        let plane = ApplicationControlPlane(model: model, container: container, developmentMode: false)

        let snapshot = try plane.runtimeSnapshot()
        let callsAfterControlRead = await discoverer.callCount()

        XCTAssertTrue(plane.model === model)
        XCTAssertEqual(snapshot["counts"]?["active_listeners"]?.intValue, 1)
        XCTAssertEqual(callsAfterControlRead, callsBeforeControlRead)
    }

    func testBackgroundResourceSamplesDoNotRepublishHiddenRuntimeUI() async throws {
        let resources = ChangingResourceReader()
        let model = AppModel(
            discoverer: TimestampOnlyDiscovery(),
            processResourceReader: resources,
            dockerService: EmptyDockerService()
        )
        model.refreshInterval = 0.5
        let publications = LockedCounter()
        let observation = model.objectWillChange.sink { publications.increment() }
        model.startMonitoring()

        try await waitUntil { await resources.callCount() >= 1 }
        publications.reset()
        try await waitUntil { await resources.callCount() >= 2 }
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(publications.value(), 0)
        model.pauseMonitoring()
        observation.cancel()
    }

    func testVisibleRuntimePublishesMeaningfulResourceSamples() async throws {
        let resources = ChangingResourceReader()
        let model = AppModel(
            discoverer: TimestampOnlyDiscovery(),
            processResourceReader: resources,
            dockerService: EmptyDockerService()
        )
        model.refreshInterval = 0.5
        model.setMonitoringSurface(.mainWindow, visible: true)
        let publications = LockedCounter()
        let observation = model.objectWillChange.sink { publications.increment() }
        model.startMonitoring()

        try await waitUntil { await resources.callCount() >= 1 }
        publications.reset()
        try await waitUntil { await resources.callCount() >= 2 }
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertGreaterThan(publications.value(), 0)
        model.pauseMonitoring()
        observation.cancel()
    }

    private func waitUntil(
        timeout: Duration = .seconds(3),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for the monitoring condition.")
    }
}

private actor TimestampOnlyDiscovery: PortDiscovering {
    private var calls = 0

    func discover() async throws -> [ObservedListener] {
        calls += 1
        var listener = makeListener()
        listener.lastDetectedAt = Date()
        return [listener]
    }

    func callCount() -> Int { calls }
}

private actor CountingLifecycleObserver: RuntimeLifecycleObserving {
    private var listenerTransitions = 0

    func transition(_ update: RuntimeLifecycleUpdate) async {
        if case .listenerObserved = update { listenerTransitions += 1 }
    }

    func snapshots() async -> AsyncStream<RuntimeLifecycleSnapshot> {
        AsyncStream { continuation in continuation.finish() }
    }

    func listenerTransitionCount() -> Int { listenerTransitions }
}

private struct FixedResourceReader: ProcessResourceUsageReading {
    func read(pids: Set<Int32>) async throws -> [Int32: ProcessResourceUsage] {
        Dictionary(uniqueKeysWithValues: pids.map {
            ($0, ProcessResourceUsage(
                cpuPercent: 1,
                residentMemoryBytes: 8_388_608,
                capturedAt: Date(timeIntervalSince1970: 100)
            ))
        })
    }
}

private actor ChangingResourceReader: ProcessResourceUsageReading {
    private var calls = 0

    func read(pids: Set<Int32>) async throws -> [Int32: ProcessResourceUsage] {
        calls += 1
        let cpuPercent = Double(calls * 5)
        return Dictionary(uniqueKeysWithValues: pids.map {
            ($0, ProcessResourceUsage(
                cpuPercent: cpuPercent,
                residentMemoryBytes: UInt64(calls) * 8_388_608,
                capturedAt: Date()
            ))
        })
    }

    func callCount() -> Int { calls }
}

private struct EmptyDockerService: DockerServing {
    func availability() async -> DockerAvailability { .notInstalled }
    func runningContainers() async throws -> [DockerContainer] { [] }
    func stop(containerID: String) async throws {}
    func restart(containerID: String) async throws {}
    func recentLogs(containerID: String, lines: Int) async throws -> String { "" }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() { lock.withLock { count += 1 } }
    func reset() { lock.withLock { count = 0 } }
    func value() -> Int { lock.withLock { count } }
}
