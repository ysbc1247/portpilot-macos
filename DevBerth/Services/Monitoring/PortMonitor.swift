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
            var previous: [ObservedListener] = []
            while !Task.isCancelled {
                do {
                    let listeners = try await discoverer.discover()
                    let snapshot = RuntimeSnapshot(listeners: listeners, capturedAt: Date())
                    continuation.yield(MonitoringUpdate(
                        snapshot: snapshot,
                        diff: RuntimeDiffer.diff(previous: previous, current: listeners),
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
                do {
                    try await Task.sleep(for: .seconds(max(0.5, intervalSeconds)))
                } catch {
                    break
                }
            }
            continuation.finish()
        }
        return stream
    }

    func stop() {
        monitoringTask?.cancel()
        monitoringTask = nil
    }
}

