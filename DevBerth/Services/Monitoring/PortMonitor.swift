import Foundation

struct MonitoringUpdate: Sendable {
    let snapshot: RuntimeSnapshot
    let diff: RuntimeDiff
    let error: DevBerthError?
}

actor PortMonitor {
    private let discoverer: any PortDiscovering
    private var monitoringTask: Task<Void, Never>?

    init(discoverer: any PortDiscovering) {
        self.discoverer = discoverer
    }

    func updates(every intervalSeconds: Double) -> AsyncStream<MonitoringUpdate> {
        monitoringTask?.cancel()
        let (stream, continuation) = AsyncStream<MonitoringUpdate>.makeStream(bufferingPolicy: .bufferingNewest(1))
        monitoringTask = Task { [discoverer] in
            await PerformanceDiagnostics.shared.backgroundTaskStarted()
            await PerformanceDiagnostics.shared.setMonitoring(mode: .active, intervalSeconds: intervalSeconds)
            var previous: [ObservedListener] = []
            while !Task.isCancelled {
                let scanStartedAt = Date()
                let scanInterval = DevBerthPerformance.begin(.runtimeScan)
                do {
                    let listeners = try await discoverer.discover()
                    let snapshot = RuntimeSnapshot(listeners: listeners, capturedAt: Date())
                    let diffInterval = DevBerthPerformance.begin(.runtimeDiff)
                    let diff = RuntimeDiffer.diff(previous: previous, current: listeners)
                    DevBerthPerformance.end(diffInterval)
                    continuation.yield(MonitoringUpdate(
                        snapshot: snapshot,
                        diff: diff,
                        error: nil
                    ))
                    previous = listeners
                } catch let error as DevBerthError {
                    continuation.yield(MonitoringUpdate(
                        snapshot: RuntimeSnapshot(listeners: previous, capturedAt: Date()),
                        diff: .empty,
                        error: error
                    ))
                } catch {
                    continuation.yield(MonitoringUpdate(
                        snapshot: RuntimeSnapshot(listeners: previous, capturedAt: Date()),
                        diff: .empty,
                        error: .unexpected(error.localizedDescription)
                    ))
                }
                DevBerthPerformance.end(scanInterval)
                await PerformanceDiagnostics.shared.recordScan(
                    durationSeconds: Date().timeIntervalSince(scanStartedAt)
                )
                do {
                    try await Task.sleep(for: .seconds(max(0.5, intervalSeconds)))
                } catch {
                    break
                }
            }
            await PerformanceDiagnostics.shared.backgroundTaskFinished()
            continuation.finish()
        }
        return stream
    }

    func stop() {
        monitoringTask?.cancel()
        monitoringTask = nil
    }
}
