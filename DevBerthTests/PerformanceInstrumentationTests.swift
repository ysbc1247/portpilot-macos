import XCTest
@testable import DevBerth

final class PerformanceInstrumentationTests: XCTestCase {
    func testDiagnosticsAggregateMetricsAndBoundWarnings() async {
        let diagnostics = PerformanceDiagnostics()
        await diagnostics.setMonitoring(mode: .background, intervalSeconds: 0.5)
        for _ in 0..<25 {
            await diagnostics.recordScan(durationSeconds: 1)
        }
        await diagnostics.recordCoalescedScan()
        await diagnostics.recordProcessCache(count: 7, hits: 8, misses: 2)
        await diagnostics.recordDockerRefresh(durationSeconds: 0.25)
        await diagnostics.healthCheckStarted()
        await diagnostics.backgroundTaskStarted()

        let snapshot = await diagnostics.snapshot()

        XCTAssertEqual(snapshot.monitoringMode, .background)
        XCTAssertEqual(snapshot.pollingIntervalSeconds, 0.5)
        XCTAssertEqual(snapshot.lastScanDurationSeconds, 1)
        XCTAssertEqual(snapshot.averageScanDurationSeconds, 1)
        XCTAssertEqual(snapshot.maximumScanDurationSeconds, 1)
        XCTAssertEqual(snapshot.scanCount, 25)
        XCTAssertEqual(snapshot.coalescedScanCount, 1)
        XCTAssertEqual(snapshot.cachedProcessCount, 7)
        XCTAssertEqual(snapshot.processCacheHitRate, 0.8)
        XCTAssertEqual(snapshot.lastDockerRefreshDurationSeconds, 0.25)
        XCTAssertEqual(snapshot.activeHealthCheckCount, 1)
        XCTAssertEqual(snapshot.activeBackgroundTaskCount, 1)
        XCTAssertEqual(snapshot.recentWarnings.count, 20)

        await diagnostics.healthCheckFinished()
        await diagnostics.backgroundTaskFinished()
        let finished = await diagnostics.snapshot()
        XCTAssertEqual(finished.activeHealthCheckCount, 0)
        XCTAssertEqual(finished.activeBackgroundTaskCount, 0)
    }
}
