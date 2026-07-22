import Foundation
import OSLog

enum PerformanceOperation: Sendable {
    case runtimeScan
    case listenerDiscovery
    case processEnrichment
    case dockerRefresh
    case projectInference
    case runtimeDiff
    case swiftDataWrite
    case healthCheckBatch
    case logProcessing
    case swiftUIStatePublish
    case mcpRequest
    case lifecycleOperation
}

struct PerformanceInterval: @unchecked Sendable {
    fileprivate let operation: PerformanceOperation
    fileprivate let state: OSSignpostIntervalState
}

enum DevBerthPerformance {
    private static let signposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? ProductIdentity.currentBundleIdentifier,
        category: "Performance"
    )

    static func begin(_ operation: PerformanceOperation) -> PerformanceInterval? {
        guard signposter.isEnabled else { return nil }
        let state: OSSignpostIntervalState
        switch operation {
        case .runtimeScan:
            state = signposter.beginInterval("Full Runtime Scan")
        case .listenerDiscovery:
            state = signposter.beginInterval("Listener Discovery")
        case .processEnrichment:
            state = signposter.beginInterval("Process Enrichment")
        case .dockerRefresh:
            state = signposter.beginInterval("Docker Refresh")
        case .projectInference:
            state = signposter.beginInterval("Project Inference")
        case .runtimeDiff:
            state = signposter.beginInterval("Runtime Diff")
        case .swiftDataWrite:
            state = signposter.beginInterval("SwiftData Write")
        case .healthCheckBatch:
            state = signposter.beginInterval("Health Check Batch")
        case .logProcessing:
            state = signposter.beginInterval("Log Processing")
        case .swiftUIStatePublish:
            state = signposter.beginInterval("SwiftUI State Publish")
        case .mcpRequest:
            state = signposter.beginInterval("MCP Request")
        case .lifecycleOperation:
            state = signposter.beginInterval("Lifecycle Operation")
        }
        return PerformanceInterval(operation: operation, state: state)
    }

    static func end(_ interval: PerformanceInterval?) {
        guard let interval else { return }
        switch interval.operation {
        case .runtimeScan:
            signposter.endInterval("Full Runtime Scan", interval.state)
        case .listenerDiscovery:
            signposter.endInterval("Listener Discovery", interval.state)
        case .processEnrichment:
            signposter.endInterval("Process Enrichment", interval.state)
        case .dockerRefresh:
            signposter.endInterval("Docker Refresh", interval.state)
        case .projectInference:
            signposter.endInterval("Project Inference", interval.state)
        case .runtimeDiff:
            signposter.endInterval("Runtime Diff", interval.state)
        case .swiftDataWrite:
            signposter.endInterval("SwiftData Write", interval.state)
        case .healthCheckBatch:
            signposter.endInterval("Health Check Batch", interval.state)
        case .logProcessing:
            signposter.endInterval("Log Processing", interval.state)
        case .swiftUIStatePublish:
            signposter.endInterval("SwiftUI State Publish", interval.state)
        case .mcpRequest:
            signposter.endInterval("MCP Request", interval.state)
        case .lifecycleOperation:
            signposter.endInterval("Lifecycle Operation", interval.state)
        }
    }
}

enum RuntimeMonitoringMode: String, CaseIterable, Sendable {
    case transition
    case active
    case background
    case idle
}

struct PerformanceWarning: Identifiable, Equatable, Sendable {
    let id: UUID
    let observedAt: Date
    let message: String
}

struct PerformanceDiagnosticsSnapshot: Equatable, Sendable {
    let monitoringMode: RuntimeMonitoringMode
    let pollingIntervalSeconds: Double
    let lastScanDurationSeconds: Double?
    let averageScanDurationSeconds: Double?
    let maximumScanDurationSeconds: Double?
    let scanCount: Int
    let coalescedScanCount: Int
    let cachedProcessCount: Int
    let processCacheHitRate: Double?
    let lastDockerRefreshDurationSeconds: Double?
    let activeHealthCheckCount: Int
    let activeBackgroundTaskCount: Int
    let recentWarnings: [PerformanceWarning]

    static let empty = PerformanceDiagnosticsSnapshot(
        monitoringMode: .active,
        pollingIntervalSeconds: 2,
        lastScanDurationSeconds: nil,
        averageScanDurationSeconds: nil,
        maximumScanDurationSeconds: nil,
        scanCount: 0,
        coalescedScanCount: 0,
        cachedProcessCount: 0,
        processCacheHitRate: nil,
        lastDockerRefreshDurationSeconds: nil,
        activeHealthCheckCount: 0,
        activeBackgroundTaskCount: 0,
        recentWarnings: []
    )
}

actor PerformanceDiagnostics {
    static let shared = PerformanceDiagnostics()

    private var monitoringMode = RuntimeMonitoringMode.active
    private var pollingIntervalSeconds = 2.0
    private var lastScanDurationSeconds: Double?
    private var totalScanDurationSeconds = 0.0
    private var maximumScanDurationSeconds: Double?
    private var scanCount = 0
    private var coalescedScanCount = 0
    private var cachedProcessCount = 0
    private var processCacheHits = 0
    private var processCacheMisses = 0
    private var lastDockerRefreshDurationSeconds: Double?
    private var activeHealthCheckCount = 0
    private var activeBackgroundTaskCount = 0
    private var recentWarnings: [PerformanceWarning] = []

    func setMonitoring(mode: RuntimeMonitoringMode, intervalSeconds: Double) {
        monitoringMode = mode
        pollingIntervalSeconds = intervalSeconds
    }

    func recordScan(durationSeconds: Double) {
        let duration = max(0, durationSeconds)
        scanCount += 1
        lastScanDurationSeconds = duration
        totalScanDurationSeconds += duration
        maximumScanDurationSeconds = max(maximumScanDurationSeconds ?? 0, duration)
        if duration > pollingIntervalSeconds {
            recordWarning("Runtime scan exceeded the current polling interval.")
        }
    }

    func recordCoalescedScan() {
        coalescedScanCount += 1
    }

    func recordProcessCache(count: Int, hits: Int, misses: Int) {
        cachedProcessCount = max(0, count)
        processCacheHits += max(0, hits)
        processCacheMisses += max(0, misses)
    }

    func recordDockerRefresh(durationSeconds: Double) {
        lastDockerRefreshDurationSeconds = max(0, durationSeconds)
    }

    func healthCheckStarted() {
        activeHealthCheckCount += 1
    }

    func healthCheckFinished() {
        activeHealthCheckCount = max(0, activeHealthCheckCount - 1)
    }

    func backgroundTaskStarted() {
        activeBackgroundTaskCount += 1
    }

    func backgroundTaskFinished() {
        activeBackgroundTaskCount = max(0, activeBackgroundTaskCount - 1)
    }

    func snapshot() -> PerformanceDiagnosticsSnapshot {
        let cacheRequests = processCacheHits + processCacheMisses
        return PerformanceDiagnosticsSnapshot(
            monitoringMode: monitoringMode,
            pollingIntervalSeconds: pollingIntervalSeconds,
            lastScanDurationSeconds: lastScanDurationSeconds,
            averageScanDurationSeconds: scanCount == 0 ? nil : totalScanDurationSeconds / Double(scanCount),
            maximumScanDurationSeconds: maximumScanDurationSeconds,
            scanCount: scanCount,
            coalescedScanCount: coalescedScanCount,
            cachedProcessCount: cachedProcessCount,
            processCacheHitRate: cacheRequests == 0 ? nil : Double(processCacheHits) / Double(cacheRequests),
            lastDockerRefreshDurationSeconds: lastDockerRefreshDurationSeconds,
            activeHealthCheckCount: activeHealthCheckCount,
            activeBackgroundTaskCount: activeBackgroundTaskCount,
            recentWarnings: recentWarnings
        )
    }

    private func recordWarning(_ message: String) {
        recentWarnings.append(PerformanceWarning(id: UUID(), observedAt: Date(), message: message))
        if recentWarnings.count > 20 {
            recentWarnings.removeFirst(recentWarnings.count - 20)
        }
    }
}
