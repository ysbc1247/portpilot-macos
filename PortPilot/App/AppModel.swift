import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var listeners: [NetworkListener] = []
    @Published private(set) var recentChanges: [NetworkListener] = []
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var isRefreshing = false
    @Published var isMonitoring = true
    @Published var searchText = ""
    @Published var presentedError: PortPilotError?
    @Published var selectedListenerID: String?
    @Published private(set) var processesBeingControlled = Set<Int32>()

    private let monitor: PortMonitor
    private let processController: any ProcessControlling
    private let historyRecorder: (any HistoryRecording)?
    private var monitoringTask: Task<Void, Never>?
    var refreshInterval: Double = 2

    init(
        discoverer: (any PortDiscovering)? = nil,
        processController: (any ProcessControlling)? = nil,
        historyRecorder: (any HistoryRecording)? = nil
    ) {
        let runner = FoundationCommandRunner()
        let service = discoverer ?? LocalPortDiscovery(runner: FoundationCommandRunner())
        self.monitor = PortMonitor(discoverer: service)
        self.processController = processController ?? SafeProcessController(
            runner: runner,
            verifier: ProcessIdentityVerifier(runner: runner)
        )
        self.historyRecorder = historyRecorder
    }

    var filteredListeners: [NetworkListener] {
        guard !searchText.isEmpty else { return listeners }
        return listeners.filter { listener in
            let text = [
                String(listener.port), listener.protocolKind.rawValue, listener.address,
                listener.process.name, listener.process.commandLine,
                listener.process.project?.name ?? ""
            ].joined(separator: " ")
            return text.localizedCaseInsensitiveContains(searchText)
        }
    }

    var selectedListener: NetworkListener? {
        listeners.first(where: { $0.id == selectedListenerID })
    }

    func startMonitoring() {
        monitoringTask?.cancel()
        isMonitoring = true
        isRefreshing = true
        monitoringTask = Task { [weak self] in
            guard let self else { return }
            let stream = await monitor.updates(every: refreshInterval)
            for await update in stream {
                guard !Task.isCancelled else { break }
                listeners = update.snapshot.listeners
                recentChanges = Array((update.diff.added + update.diff.removed).prefix(12))
                lastRefresh = update.snapshot.capturedAt
                isRefreshing = false
                if let error = update.error { presentedError = error }
                recordPortChanges(update.diff)
            }
        }
    }

    func pauseMonitoring() {
        isMonitoring = false
        isRefreshing = false
        monitoringTask?.cancel()
        monitoringTask = nil
        Task { await monitor.stop() }
    }

    func refreshNow() {
        startMonitoring()
    }

    func terminate(_ listener: NetworkListener, mode: TerminationMode) async {
        let pid = listener.process.identity.pid
        guard !processesBeingControlled.contains(pid) else { return }
        processesBeingControlled.insert(pid)
        defer { processesBeingControlled.remove(pid) }
        let startedAt = Date()
        let eventType: HistoryEventType = {
            switch mode {
            case .graceful: .gracefulStopRequested
            case .force: .forceStopRequested
            }
        }()
        do {
            let outcome = try await processController.terminate(listener.process, mode: mode)
            await record(HistoryEvent(
                id: UUID(), timestamp: startedAt, port: listener.port,
                processIdentity: listener.process.identity, processName: listener.process.name,
                projectID: nil, profileID: listener.process.launchProfileID, type: eventType,
                result: outcome.didExit ? .succeeded : .failed,
                errorDetails: outcome.didExit ? nil : "The process did not exit before the graceful shutdown timeout.",
                durationSeconds: outcome.durationSeconds
            ))
            if !outcome.didExit {
                presentedError = .unexpected("\(listener.process.name) did not exit before the timeout. You can force stop it after reviewing the risk.")
            }
            refreshNow()
        } catch let error as PortPilotError {
            presentedError = error
            await record(HistoryEvent(
                id: UUID(), timestamp: startedAt, port: listener.port,
                processIdentity: listener.process.identity, processName: listener.process.name,
                projectID: nil, profileID: listener.process.launchProfileID, type: eventType,
                result: .failed, errorDetails: error.localizedDescription,
                durationSeconds: Date().timeIntervalSince(startedAt)
            ))
        } catch {
            presentedError = .unexpected(error.localizedDescription)
        }
    }

    private func recordPortChanges(_ diff: RuntimeDiff) {
        for listener in diff.added {
            Task { await record(HistoryEvent(
                id: UUID(), timestamp: Date(), port: listener.port,
                processIdentity: listener.process.identity, processName: listener.process.name,
                projectID: nil, profileID: listener.process.launchProfileID,
                type: .portDetected, result: .observed, errorDetails: nil, durationSeconds: nil
            )) }
        }
        for listener in diff.removed {
            Task { await record(HistoryEvent(
                id: UUID(), timestamp: Date(), port: listener.port,
                processIdentity: listener.process.identity, processName: listener.process.name,
                projectID: nil, profileID: listener.process.launchProfileID,
                type: .portReleased, result: .observed, errorDetails: nil, durationSeconds: nil
            )) }
        }
    }

    private func record(_ event: HistoryEvent) async {
        guard let historyRecorder else { return }
        do { try await historyRecorder.record(event) }
        catch { presentedError = .unexpected("History could not be saved: \(error.localizedDescription)") }
    }
}
