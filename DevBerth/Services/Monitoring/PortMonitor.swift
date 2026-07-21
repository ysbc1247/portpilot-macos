import Foundation

struct MonitoringUpdate: Sendable {
    let snapshot: RuntimeSnapshot
    let diff: RuntimeDiff
    let error: DevBerthError?
}

struct MonitoringConfiguration: Equatable, Sendable {
    var transitionIntervalSeconds: Double
    var activeIntervalSeconds: Double
    var backgroundIntervalSeconds: Double
    var idleIntervalSeconds: Double
    var transitionDurationSeconds: Double
    var idleAfterSeconds: Double

    init(
        transitionIntervalSeconds: Double = 0.75,
        activeIntervalSeconds: Double = 2,
        backgroundIntervalSeconds: Double = 10,
        idleIntervalSeconds: Double = 30,
        transitionDurationSeconds: Double = 15,
        idleAfterSeconds: Double = 180
    ) {
        self.transitionIntervalSeconds = max(0.05, transitionIntervalSeconds)
        self.activeIntervalSeconds = max(0.05, activeIntervalSeconds)
        self.backgroundIntervalSeconds = max(0.05, backgroundIntervalSeconds)
        self.idleIntervalSeconds = max(0.05, idleIntervalSeconds)
        self.transitionDurationSeconds = max(0, transitionDurationSeconds)
        self.idleAfterSeconds = max(0, idleAfterSeconds)
    }

    mutating func setActiveInterval(_ seconds: Double) {
        activeIntervalSeconds = max(0.5, seconds)
        transitionIntervalSeconds = min(0.75, activeIntervalSeconds)
        backgroundIntervalSeconds = max(10, activeIntervalSeconds * 5)
        idleIntervalSeconds = max(30, activeIntervalSeconds * 15)
    }
}

enum MonitoringSurface: Hashable, Sendable {
    case mainWindow
    case menuBar
}

actor PortMonitor {
    private let discoverer: any PortDiscovering
    private let correlator: (any RuntimeListenerCorrelating)?
    private let diagnostics: PerformanceDiagnostics
    private var configuration: MonitoringConfiguration
    private var monitoringTask: Task<Void, Never>?
    private var stream: AsyncStream<MonitoringUpdate>?
    private var streamContinuation: AsyncStream<MonitoringUpdate>.Continuation?
    private var delayTask: Task<Void, Never>?
    private var delayContinuation: CheckedContinuation<Void, Never>?
    private var delayID: UUID?
    private var visibleSurfaces = Set<MonitoringSurface>()
    private var previous: [ObservedListener] = []
    private var lastSemanticChangeAt = Date()
    private var transitionUntil = Date()
    private var scanInFlight = false
    private var refreshPending = false
    private var suspended = false

    init(
        discoverer: any PortDiscovering,
        correlator: (any RuntimeListenerCorrelating)? = nil,
        configuration: MonitoringConfiguration = MonitoringConfiguration(),
        diagnostics: PerformanceDiagnostics = .shared
    ) {
        self.discoverer = discoverer
        self.correlator = correlator
        self.configuration = configuration
        self.diagnostics = diagnostics
        transitionUntil = Date().addingTimeInterval(configuration.transitionDurationSeconds)
    }

    func updates(every intervalSeconds: Double) -> AsyncStream<MonitoringUpdate> {
        if abs(configuration.activeIntervalSeconds - intervalSeconds) > 0.001 {
            configuration.setActiveInterval(intervalSeconds)
        }
        if let stream, monitoringTask != nil { return stream }

        let pair = AsyncStream<MonitoringUpdate>.makeStream(bufferingPolicy: .bufferingNewest(1))
        stream = pair.stream
        streamContinuation = pair.continuation
        monitoringTask = Task { [weak self] in
            guard let self else { return }
            await self.run()
        }
        return pair.stream
    }

    func setActiveInterval(_ intervalSeconds: Double) {
        configuration.setActiveInterval(intervalSeconds)
        requestRefresh()
    }

    func setSurface(_ surface: MonitoringSurface, visible: Bool) {
        if visible {
            visibleSurfaces.insert(surface)
        } else {
            visibleSurfaces.remove(surface)
        }
        wakeDelay()
    }

    func setSuspended(_ value: Bool) {
        guard suspended != value else { return }
        suspended = value
        if !value {
            transitionUntil = Date().addingTimeInterval(configuration.transitionDurationSeconds)
            refreshPending = true
        }
        wakeDelay()
    }

    func requestRefresh() {
        transitionUntil = Date().addingTimeInterval(configuration.transitionDurationSeconds)
        if scanInFlight || refreshPending {
            Task { await diagnostics.recordCoalescedScan() }
        }
        refreshPending = true
        wakeDelay()
    }

    func stop() {
        monitoringTask?.cancel()
        monitoringTask = nil
        delayTask?.cancel()
        delayTask = nil
        delayID = nil
        delayContinuation?.resume()
        delayContinuation = nil
        streamContinuation?.finish()
        streamContinuation = nil
        stream = nil
        refreshPending = false
        scanInFlight = false
    }

    private func run() async {
        await diagnostics.backgroundTaskStarted()
        defer {
            monitoringTask = nil
            streamContinuation?.finish()
            streamContinuation = nil
            stream = nil
            Task { await diagnostics.backgroundTaskFinished() }
        }

        while !Task.isCancelled {
            if suspended {
                await wait(seconds: 86_400)
                continue
            }

            refreshPending = false
            scanInFlight = true
            let scanStartedAt = Date()
            let scanInterval = DevBerthPerformance.begin(.runtimeScan)
            let update = await scan()
            DevBerthPerformance.end(scanInterval)
            scanInFlight = false
            await diagnostics.recordScan(
                durationSeconds: Date().timeIntervalSince(scanStartedAt)
            )
            if !update.diff.added.isEmpty || !update.diff.updated.isEmpty || !update.diff.removed.isEmpty {
                lastSemanticChangeAt = update.snapshot.capturedAt
                transitionUntil = update.snapshot.capturedAt.addingTimeInterval(configuration.transitionDurationSeconds)
            }
            streamContinuation?.yield(update)

            if refreshPending { continue }
            let schedule = currentSchedule(at: Date())
            await diagnostics.setMonitoring(
                mode: schedule.mode,
                intervalSeconds: schedule.interval
            )
            await wait(seconds: schedule.interval)
        }
    }

    private func scan() async -> MonitoringUpdate {
        do {
            var listeners = try await discoverer.discover()
            if let correlator {
                listeners = await correlator.correlate(listeners)
            }
            let snapshot = RuntimeSnapshot(listeners: listeners, capturedAt: Date())
            let diffInterval = DevBerthPerformance.begin(.runtimeDiff)
            let diff = RuntimeDiffer.diff(previous: previous, current: listeners)
            DevBerthPerformance.end(diffInterval)
            previous = listeners
            return MonitoringUpdate(snapshot: snapshot, diff: diff, error: nil)
        } catch let error as DevBerthError {
            return MonitoringUpdate(
                snapshot: RuntimeSnapshot(listeners: previous, capturedAt: Date()),
                diff: .empty,
                error: error
            )
        } catch {
            return MonitoringUpdate(
                snapshot: RuntimeSnapshot(listeners: previous, capturedAt: Date()),
                diff: .empty,
                error: .unexpected(error.localizedDescription)
            )
        }
    }

    private func currentSchedule(at now: Date) -> (mode: RuntimeMonitoringMode, interval: Double) {
        if now < transitionUntil {
            return (.transition, configuration.transitionIntervalSeconds)
        }
        if !visibleSurfaces.isEmpty {
            return (.active, configuration.activeIntervalSeconds)
        }
        if now.timeIntervalSince(lastSemanticChangeAt) >= configuration.idleAfterSeconds {
            return (.idle, configuration.idleIntervalSeconds)
        }
        return (.background, configuration.backgroundIntervalSeconds)
    }

    private func wait(seconds: Double) async {
        let waitID = UUID()
        await withCheckedContinuation { continuation in
            delayID = waitID
            delayContinuation = continuation
            delayTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(seconds))
                } catch {
                    return
                }
                await self?.completeDelay(waitID)
            }
        }
    }

    private func completeDelay(_ waitID: UUID) {
        guard delayID == waitID else { return }
        delayID = nil
        delayTask = nil
        delayContinuation?.resume()
        delayContinuation = nil
    }

    private func wakeDelay() {
        delayTask?.cancel()
        delayTask = nil
        delayID = nil
        delayContinuation?.resume()
        delayContinuation = nil
    }
}
