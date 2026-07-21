import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var listeners: [ObservedListener] = []
    @Published private(set) var recentChanges: [ObservedListener] = []
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var isRefreshing = false
    @Published var isMonitoring = true
    @Published var searchText = ""
    @Published var presentedError: DevBerthError?
    @Published var selectedListenerID: String?
    @Published private(set) var processesBeingControlled = Set<Int32>()
    @Published private(set) var runningProfileIDs = Set<UUID>()
    @Published private(set) var profileFailures: [UUID: String] = [:]
    @Published var requestedSection: AppSection?
    @Published var pendingLaunchConflict: PendingLaunchConflict?

    private let monitor: PortMonitor
    private let processController: any ProcessControlling
    private let historyRecorder: (any HistoryRecording)?
    private let launchService: any LaunchProfileServing
    private let projectOrchestrator: ProjectOrchestrator
    private let notifier: any PortNotifying
    private let dockerAssociations: DockerAssociationProvider
    private var notificationPorts = Set<UInt16>()
    let logBuffer: ServiceLogBuffer
    private var monitoringTask: Task<Void, Never>?
    var refreshInterval: Double = 2

    init(
        discoverer: (any PortDiscovering)? = nil,
        processController: (any ProcessControlling)? = nil,
        historyRecorder: (any HistoryRecording)? = nil
    ) {
        let runner = FoundationCommandRunner()
        let service = discoverer ?? LocalPortDiscovery(runner: runner)
        let logs = ServiceLogBuffer()
        let managedLauncher = ManagedProcessLauncher(secrets: KeychainSecretStore(), logs: logs)
        let coordinator = LaunchCoordinator(
            discoverer: service,
            processLauncher: managedLauncher,
            healthChecker: HTTPHealthChecker()
        )
        self.monitor = PortMonitor(discoverer: service)
        self.processController = processController ?? SafeProcessController(
            runner: runner,
            verifier: ProcessFingerprintVerifier(runner: runner)
        )
        self.historyRecorder = historyRecorder
        self.launchService = coordinator
        self.projectOrchestrator = ProjectOrchestrator(launcher: coordinator)
        self.logBuffer = logs
        self.notifier = LocalNotificationService()
        self.dockerAssociations = DockerAssociationProvider(
            client: DockerCLIClient(runner: runner)
        )
    }

    var filteredListeners: [ObservedListener] {
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

    var selectedListener: ObservedListener? {
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
                listeners = await dockerAssociations.correlate(update.snapshot.listeners)
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

    func navigate(to section: AppSection) {
        requestedSection = section
    }

    func setNotificationPorts(_ ports: [Int]) {
        notificationPorts = Set(ports.compactMap { UInt16(exactly: $0) })
    }

    func terminate(_ listener: ObservedListener, mode: TerminationMode) async {
        let pid = listener.process.fingerprint.pid
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
            let outcome = try await processController.terminate(ProcessActionTarget(listener: listener), mode: mode)
            await record(HistoryEvent(
                id: UUID(), timestamp: startedAt, port: listener.port,
                processFingerprint: listener.process.fingerprint, processName: listener.process.name,
                projectID: nil, profileID: listener.process.managedServiceID, type: eventType,
                result: outcome.didExit ? .succeeded : .failed,
                errorDetails: outcome.didExit ? nil : "The process did not exit before the graceful shutdown timeout.",
                durationSeconds: outcome.durationSeconds
            ))
            if !outcome.didExit {
                presentedError = .unexpected("\(listener.process.name) did not exit before the timeout. You can force stop it after reviewing the risk.")
            }
            refreshNow()
        } catch let error as DevBerthError {
            presentedError = error
            await record(HistoryEvent(
                id: UUID(), timestamp: startedAt, port: listener.port,
                processFingerprint: listener.process.fingerprint, processName: listener.process.name,
                projectID: nil, profileID: listener.process.managedServiceID, type: eventType,
                result: .failed, errorDetails: error.localizedDescription,
                durationSeconds: Date().timeIntervalSince(startedAt)
            ))
        } catch {
            presentedError = .unexpected(error.localizedDescription)
        }
    }

    func launchProfile(_ profile: ManagedServiceConfiguration, bypassCachedConflict: Bool = false) async {
        let startedAt = Date()
        profileFailures[profile.id] = nil
        if !bypassCachedConflict,
           let conflict = PortConflictDetector.conflicts(for: profile, listeners: listeners).first {
            pendingLaunchConflict = PendingLaunchConflict(profile: profile, conflict: conflict)
            await record(HistoryEvent(
                id: UUID(), timestamp: startedAt, port: conflict.expectedPort.port,
                processFingerprint: conflict.listener.process.fingerprint, processName: conflict.listener.process.name,
                projectID: profile.projectID, profileID: profile.id, type: .portConflictDetected,
                result: .cancelled, errorDetails: "Launch paused for explicit conflict resolution.", durationSeconds: 0
            ))
            return
        }
        do {
            try await launchService.launch(profile)
            runningProfileIDs.insert(profile.id)
            await record(HistoryEvent(
                id: UUID(), timestamp: startedAt, port: profile.expectedPorts.first?.port,
                processFingerprint: nil, processName: profile.name, projectID: profile.projectID,
                profileID: profile.id, type: .launchSucceeded, result: .succeeded,
                errorDetails: nil, durationSeconds: Date().timeIntervalSince(startedAt)
            ))
            refreshNow()
        } catch let error as DevBerthError {
            profileFailures[profile.id] = error.localizedDescription
            presentedError = error
            await record(HistoryEvent(
                id: UUID(), timestamp: startedAt, port: profile.expectedPorts.first?.port,
                processFingerprint: nil, processName: profile.name, projectID: profile.projectID,
                profileID: profile.id, type: .launchFailed, result: .failed,
                errorDetails: error.localizedDescription, durationSeconds: Date().timeIntervalSince(startedAt)
            ))
        } catch {
            profileFailures[profile.id] = error.localizedDescription
            presentedError = .unexpected(error.localizedDescription)
        }
    }

    func inspectPendingConflict() {
        guard let pendingLaunchConflict else { return }
        selectedListenerID = pendingLaunchConflict.conflict.listener.id
        requestedSection = .activePorts
        self.pendingLaunchConflict = nil
    }

    func editProfileForPendingConflict() {
        requestedSection = .launchProfiles
        pendingLaunchConflict = nil
    }

    func resolvePendingConflict(startAfterStopping: Bool) async {
        guard let pending = pendingLaunchConflict else { return }
        let listener = pending.conflict.listener
        do {
            let outcome = try await processController.terminate(
                ProcessActionTarget(listener: listener),
                mode: .graceful(timeoutSeconds: pending.profile.shutdownTimeoutSeconds)
            )
            guard outcome.didExit else {
                presentedError = .unexpected("The conflicting process did not stop before the timeout. Inspect it before considering a force stop.")
                return
            }
            pendingLaunchConflict = nil
            await record(HistoryEvent(
                id: UUID(), timestamp: Date(), port: listener.port,
                processFingerprint: listener.process.fingerprint, processName: listener.process.name,
                projectID: pending.profile.projectID, profileID: pending.profile.id,
                type: .gracefulStopRequested, result: .succeeded,
                errorDetails: "Stopped after explicit port-conflict approval.", durationSeconds: outcome.durationSeconds
            ))
            if startAfterStopping {
                await launchProfile(pending.profile, bypassCachedConflict: true)
            } else {
                refreshNow()
            }
        } catch let error as DevBerthError {
            presentedError = error
        } catch {
            presentedError = .unexpected(error.localizedDescription)
        }
    }

    func stopProfile(_ profile: ManagedServiceConfiguration) async {
        let startedAt = Date()
        do {
            try await launchService.stop(profileID: profile.id, timeoutSeconds: profile.shutdownTimeoutSeconds)
            runningProfileIDs.remove(profile.id)
            await record(HistoryEvent(
                id: UUID(), timestamp: startedAt, port: profile.expectedPorts.first?.port,
                processFingerprint: nil, processName: profile.name, projectID: profile.projectID,
                profileID: profile.id, type: .processStopped, result: .succeeded,
                errorDetails: nil, durationSeconds: Date().timeIntervalSince(startedAt)
            ))
            refreshNow()
        } catch let error as DevBerthError {
            presentedError = error
        } catch {
            presentedError = .unexpected(error.localizedDescription)
        }
    }

    func startProject(_ profiles: [ManagedServiceConfiguration]) async {
        let startedAt = Date()
        do {
            let result = try await projectOrchestrator.start(profiles: profiles)
            runningProfileIDs.formUnion(result.startedProfileIDs)
            for profile in profiles where result.startedProfileIDs.contains(profile.id) {
                await record(HistoryEvent(
                    id: UUID(), timestamp: startedAt, port: profile.expectedPorts.first?.port,
                    processFingerprint: nil, processName: profile.name, projectID: profile.projectID,
                    profileID: profile.id, type: .launchSucceeded, result: .succeeded,
                    errorDetails: nil, durationSeconds: result.durationSeconds
                ))
            }
        } catch {
            presentedError = .unexpected("Project startup stopped because a dependency failed: \(error.localizedDescription)")
        }
    }

    func stopProject(_ profiles: [ManagedServiceConfiguration]) async {
        do {
            try await projectOrchestrator.stop(profiles: profiles)
            runningProfileIDs.subtract(profiles.map(\.id))
        } catch {
            presentedError = .unexpected("One or more project services could not stop: \(error.localizedDescription)")
        }
    }

    private func recordPortChanges(_ diff: RuntimeDiff) {
        for listener in diff.added {
            notifyIfConfigured(listener, change: "became active")
            Task { await record(HistoryEvent(
                id: UUID(), timestamp: Date(), port: listener.port,
                processFingerprint: listener.process.fingerprint, processName: listener.process.name,
                projectID: nil, profileID: listener.process.managedServiceID,
                type: .portDetected, result: .observed, errorDetails: nil, durationSeconds: nil
            )) }
        }
        for listener in diff.removed {
            notifyIfConfigured(listener, change: "was released")
            Task { await record(HistoryEvent(
                id: UUID(), timestamp: Date(), port: listener.port,
                processFingerprint: listener.process.fingerprint, processName: listener.process.name,
                projectID: nil, profileID: listener.process.managedServiceID,
                type: .portReleased, result: .observed, errorDetails: nil, durationSeconds: nil
            )) }
        }
    }

    private func notifyIfConfigured(_ listener: ObservedListener, change: String) {
        guard
            UserDefaults.standard.bool(forKey: "notifyConfiguredPorts"),
            notificationPorts.contains(listener.port)
        else { return }
        Task {
            await notifier.notify(
                title: "Port \(listener.port) \(change)",
                body: "\(listener.process.name) · \(listener.protocolKind.rawValue) \(listener.address):\(listener.port)"
            )
        }
    }

    private func record(_ event: HistoryEvent) async {
        guard let historyRecorder else { return }
        do { try await historyRecorder.record(event) }
        catch { presentedError = .unexpected("History could not be saved: \(error.localizedDescription)") }
    }
}
