import XCTest
@testable import DevBerth

final class AdaptiveMonitoringTests: XCTestCase {
    func testRepeatedStartsAndRefreshRequestsNeverOverlapScans() async throws {
        let discoverer = CountingPortDiscoverer(delaySeconds: 0.08)
        let diagnostics = PerformanceDiagnostics()
        let monitor = PortMonitor(
            discoverer: discoverer,
            configuration: MonitoringConfiguration(
                transitionIntervalSeconds: 0.05,
                activeIntervalSeconds: 0.05,
                backgroundIntervalSeconds: 0.05,
                idleIntervalSeconds: 0.05,
                transitionDurationSeconds: 0,
                idleAfterSeconds: 0
            ),
            diagnostics: diagnostics
        )

        _ = await monitor.updates(every: 0.05)
        _ = await monitor.updates(every: 0.05)
        try await Task.sleep(for: .milliseconds(10))
        for _ in 0..<10 {
            await monitor.requestRefresh()
        }
        try await Task.sleep(for: .milliseconds(250))
        await monitor.stop()

        let stats = await discoverer.stats()
        let snapshot = await diagnostics.snapshot()
        XCTAssertEqual(stats.maximumConcurrentCalls, 1)
        XCTAssertGreaterThanOrEqual(stats.callCount, 2)
        XCTAssertLessThanOrEqual(stats.callCount, 4)
        XCTAssertGreaterThanOrEqual(snapshot.coalescedScanCount, 9)
    }

    func testVisibilityAndStableRuntimeSelectAdaptiveCadence() async throws {
        let discoverer = CountingPortDiscoverer(delaySeconds: 0.005)
        let diagnostics = PerformanceDiagnostics()
        let monitor = PortMonitor(
            discoverer: discoverer,
            configuration: MonitoringConfiguration(
                transitionIntervalSeconds: 0.05,
                activeIntervalSeconds: 0.06,
                backgroundIntervalSeconds: 0.12,
                idleIntervalSeconds: 0.2,
                transitionDurationSeconds: 0,
                idleAfterSeconds: 0
            ),
            diagnostics: diagnostics
        )

        _ = await monitor.updates(every: 0.06)
        try await Task.sleep(for: .milliseconds(30))
        var snapshot = await diagnostics.snapshot()
        XCTAssertEqual(snapshot.monitoringMode, .idle)
        XCTAssertEqual(snapshot.pollingIntervalSeconds, 0.2, accuracy: 0.001)

        await monitor.setSurface(.mainWindow, visible: true)
        try await Task.sleep(for: .milliseconds(30))
        snapshot = await diagnostics.snapshot()
        XCTAssertEqual(snapshot.monitoringMode, .active)
        XCTAssertEqual(snapshot.pollingIntervalSeconds, 0.06, accuracy: 0.001)
        await monitor.stop()
    }

    func testResourceUsageIgnoresTimestampAndSmallSamplingNoise() {
        let old: [Int32: ProcessResourceUsage] = [42: ProcessResourceUsage(
            cpuPercent: 4,
            residentMemoryBytes: 20_000_000,
            capturedAt: Date(timeIntervalSince1970: 100)
        )]
        let noisy: [Int32: ProcessResourceUsage] = [42: ProcessResourceUsage(
            cpuPercent: 4.9,
            residentMemoryBytes: 20_500_000,
            capturedAt: Date(timeIntervalSince1970: 200)
        )]
        let changed: [Int32: ProcessResourceUsage] = [42: ProcessResourceUsage(
            cpuPercent: 5.1,
            residentMemoryBytes: 20_500_000,
            capturedAt: Date(timeIntervalSince1970: 200)
        )]

        XCTAssertFalse(noisy.isMeaningfullyDifferent(from: old))
        XCTAssertTrue(changed.isMeaningfullyDifferent(from: old))
    }
}

private actor CountingPortDiscoverer: PortDiscovering {
    private let delaySeconds: Double
    private var activeCalls = 0
    private var maximumConcurrentCalls = 0
    private var callCount = 0

    init(delaySeconds: Double) {
        self.delaySeconds = delaySeconds
    }

    func discover() async throws -> [ObservedListener] {
        activeCalls += 1
        maximumConcurrentCalls = max(maximumConcurrentCalls, activeCalls)
        callCount += 1
        defer { activeCalls -= 1 }
        try await Task.sleep(for: .seconds(delaySeconds))
        var listener = makeListener()
        listener.lastDetectedAt = Date()
        return [listener]
    }

    func stats() -> (callCount: Int, maximumConcurrentCalls: Int) {
        (callCount, maximumConcurrentCalls)
    }
}
