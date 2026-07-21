import Combine
import Foundation
import OSLog

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
    @Published private(set) var ownershipGraphs: [String: RuntimeOwnershipGraph] = [:]
    @Published private(set) var ownershipInspectionsInProgress = Set<String>()
    @Published private(set) var servicesBeingValidated = Set<UUID>()
    @Published private(set) var runtimeStatuses: [UUID: ManagedServiceRuntimeStatus] = [:]
    @Published private(set) var runtimeIncidents: [UUID: RuntimeIncidentSummary] = [:]

    private let monitor: PortMonitor
    private let lifecycleRouter: any OwnerAwareLifecycleRouting
    private let historyRecorder: (any HistoryRecording)?
    private let ownershipRecorder: (any OwnershipRecording)?
    private let ownershipResolver: any RuntimeOwnershipResolving
    private let validationService: any ManagedServiceValidating
    private let restartTrustStore: (any RestartTrustStoring)?
    private let runtimeLifecycle: any RuntimeLifecycleObserving
    private let exitHub: ManagedProcessExitHub
    private let launchService: any LaunchProfileServing
    private let projectOrchestrator: ProjectOrchestrator
    private let notifier: any PortNotifying
    private let dockerAssociations: DockerAssociationProvider
    private let projectDiscovery: any ProjectDiscoveryServing
    private let projectManifest: any ProjectManifestServing
    private var notificationPorts = Set<UInt16>()
    let logBuffer: ServiceLogBuffer
    private var monitoringTask: Task<Void, Never>?
    private var lifecycleTask: Task<Void, Never>?
    private var exitTask: Task<Void, Never>?
    private var automaticRestartLimiters: [UUID: AutomaticRestartLimiter] = [:]
    var refreshInterval: Double = 2

    init(
        discoverer: (any PortDiscovering)? = nil,
        processController: (any ProcessControlling)? = nil,
        historyRecorder: (any HistoryRecording)? = nil,
        ownershipRecorder: (any OwnershipRecording)? = nil,
        restartTrustStore: (any RestartTrustStoring)? = nil,
        ownershipResolver: (any RuntimeOwnershipResolving)? = nil,
        lifecycleRouter: (any OwnerAwareLifecycleRouting)? = nil,
        validationService: (any ManagedServiceValidating)? = nil,
        runtimeLifecycle: (any RuntimeLifecycleObserving)? = nil,
        projectDiscovery: (any ProjectDiscoveryServing)? = nil,
        projectManifest: (any ProjectManifestServing)? = nil
    ) {
        let runner = FoundationCommandRunner()
        let service = discoverer ?? LocalPortDiscovery(runner: runner)
        let logs = ServiceLogBuffer()
        let runtimeRegistry = ManagedRuntimeRegistry()
        let lifecycleRecorder = historyRecorder as? any RuntimeLifecycleRecording
        let resolvedRuntimeLifecycle = runtimeLifecycle ?? RuntimeLifecycleTracker(
            recorder: lifecycleRecorder
        )
        let resolvedExitHub = ManagedProcessExitHub()
        let serviceCheckRunner = ServiceCheckRunner(
            discoverer: service,
            http: URLSessionHTTPProber(),
            commandRunner: runner,
            docker: DockerCLIHealthInspector(runner: runner),
            dependencies: resolvedRuntimeLifecycle as? any DependencyReadinessProviding
                ?? RuntimeLifecycleTracker()
        )
        let managedLauncher = ManagedProcessLauncher(
            secrets: KeychainSecretStore(),
            logs: logs,
            runner: runner,
            listenerDiscoverer: service,
            runtimeRegistry: runtimeRegistry,
            lifecycle: resolvedRuntimeLifecycle,
            exitObserver: resolvedExitHub
        )
        let coordinator = LaunchCoordinator(
            discoverer: service,
            processLauncher: managedLauncher,
            healthChecker: HTTPHealthChecker(),
            lifecycle: resolvedRuntimeLifecycle,
            serviceCheckRunner: serviceCheckRunner
        )
        let resolvedProcessController = processController ?? SafeProcessController(
            runner: runner,
            verifier: ProcessFingerprintVerifier(runner: runner)
        )
        let dockerClient = DockerCLIClient(runner: runner)
        self.monitor = PortMonitor(discoverer: service)
        self.lifecycleRouter = lifecycleRouter ?? OwnerAwareLifecycleRouter(
            processController: resolvedProcessController,
            managedServiceController: coordinator,
            dockerController: dockerClient,
            runtimeRegistry: runtimeRegistry
        )
        self.historyRecorder = historyRecorder
        self.ownershipRecorder = ownershipRecorder
        self.restartTrustStore = restartTrustStore
        self.runtimeLifecycle = resolvedRuntimeLifecycle
        self.exitHub = resolvedExitHub
        self.ownershipResolver = ownershipResolver ?? RuntimeOwnershipResolver(
            runtimeRegistry: runtimeRegistry,
            lineageProvider: SystemProcessLineageProvider(
                inspector: SystemProcessInspector(runner: runner)
            )
        )
        self.launchService = coordinator
        self.validationService = validationService ?? ManagedServiceValidationRunner(
            launchService: coordinator
        )
        self.projectOrchestrator = ProjectOrchestrator(launcher: coordinator)
        self.logBuffer = logs
        self.notifier = LocalNotificationService()
        self.dockerAssociations = DockerAssociationProvider(client: dockerClient)
        self.projectDiscovery = projectDiscovery ?? LocalProjectDiscoveryService()
        self.projectManifest = projectManifest ?? LocalProjectManifestService()
        lifecycleTask = Task { [weak self, resolvedRuntimeLifecycle] in
            let stream = await resolvedRuntimeLifecycle.snapshots()
            for await snapshot in stream {
                guard let self, !Task.isCancelled else { break }
                runtimeStatuses = snapshot.statuses
                runtimeIncidents = snapshot.incidents
            }
        }
        exitTask = Task { [weak self, resolvedExitHub] in
            let stream = await resolvedExitHub.notices()
            for await notice in stream {
                guard let self, !Task.isCancelled else { break }
                await handleManagedExit(notice)
            }
        }
    }

    deinit {
        monitoringTask?.cancel()
        lifecycleTask?.cancel()
        exitTask?.cancel()
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
                let currentListenerIDs = Set(listeners.map(\.id))
                ownershipGraphs = ownershipGraphs.filter { currentListenerIDs.contains($0.key) }
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

    func discoverProject(at rootPath: String) async throws -> ProjectDiscoveryReport {
        try await projectDiscovery.discover(at: URL(fileURLWithPath: rootPath, isDirectory: true))
    }

    func exportProjectManifest(
        projectName: String,
        rootPath: String,
        services: [ManagedServiceConfiguration],
        destination: URL
    ) async {
        do {
            try await projectManifest.export(
                projectName: projectName,
                projectRoot: URL(fileURLWithPath: rootPath, isDirectory: true),
                services: services,
                destination: destination
            )
        } catch let error as DevBerthError {
            presentedError = error
        } catch {
            presentedError = .unexpected("The project manifest could not be exported: \(error.localizedDescription)")
        }
    }

    func setNotificationPorts(_ ports: [Int]) {
        notificationPorts = Set(ports.compactMap { UInt16(exactly: $0) })
    }

    func inspectOwnership(of listener: ObservedListener) async {
        guard !ownershipInspectionsInProgress.contains(listener.id) else { return }
        ownershipInspectionsInProgress.insert(listener.id)
        defer { ownershipInspectionsInProgress.remove(listener.id) }
        let graph = await ownershipResolver.resolve(listener: listener)
        ownershipGraphs[listener.id] = graph
        await persistOwnership(graph.primaryConclusion, reportsError: true)
    }

    private func persistOwnership(
        _ conclusion: OwnershipConclusion,
        reportsError: Bool
    ) async {
        guard let ownershipRecorder else { return }
        do {
            try await ownershipRecorder.record(conclusion)
        } catch {
            let message = "Ownership was resolved, but its local evidence record could not be saved: \(error.localizedDescription)"
            if reportsError {
                presentedError = .unexpected(message)
            } else {
                DevBerthLogger.persistence.error("\(message, privacy: .public)")
            }
        }
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
        let lifecycleAction: LifecycleActionKind
        let forceConfirmed: Bool
        switch mode {
        case .graceful:
            lifecycleAction = .gracefulStop
            forceConfirmed = false
        case let .force(confirmed):
            lifecycleAction = .forceStop
            forceConfirmed = confirmed
        }
        do {
            let graph = await ownershipResolver.resolve(listener: listener)
            ownershipGraphs[listener.id] = graph
            await persistOwnership(graph.primaryConclusion, reportsError: false)
            let outcome = try await lifecycleRouter.perform(
                lifecycleAction,
                on: graph,
                forceConfirmed: forceConfirmed
            )
            await record(HistoryEvent(
                id: UUID(), timestamp: startedAt, port: listener.port,
                processFingerprint: listener.process.fingerprint, processName: listener.process.name,
                projectID: graph.projectID, profileID: graph.managedServiceID, type: eventType,
                result: outcome.didStop ? .succeeded : .failed,
                errorDetails: outcome.didStop ? nil : outcome.summary,
                durationSeconds: outcome.durationSeconds
            ))
            if !outcome.didStop {
                presentedError = .unexpected(outcome.summary)
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

    func stopObservedProcessForValidation(_ listener: ObservedListener) async throws {
        let pid = listener.process.fingerprint.pid
        guard !processesBeingControlled.contains(pid) else {
            throw DevBerthError.unexpected("A lifecycle action is already in progress for this process.")
        }
        processesBeingControlled.insert(pid)
        defer { processesBeingControlled.remove(pid) }
        let startedAt = Date()
        let graph = await ownershipResolver.resolve(listener: listener)
        ownershipGraphs[listener.id] = graph
        await persistOwnership(graph.primaryConclusion, reportsError: false)
        do {
            let outcome = try await lifecycleRouter.perform(
                .gracefulStop,
                on: graph,
                forceConfirmed: false
            )
            guard outcome.didStop else { throw DevBerthError.unexpected(outcome.summary) }
            await record(HistoryEvent(
                id: UUID(), timestamp: startedAt, port: listener.port,
                processFingerprint: listener.process.fingerprint, processName: listener.process.name,
                projectID: graph.projectID, profileID: graph.managedServiceID,
                type: .gracefulStopRequested,
                result: .succeeded,
                errorDetails: "Stopped with explicit approval before managed-service validation.",
                durationSeconds: outcome.durationSeconds
            ))
            refreshNow()
        } catch {
            await record(HistoryEvent(
                id: UUID(), timestamp: startedAt, port: listener.port,
                processFingerprint: listener.process.fingerprint, processName: listener.process.name,
                projectID: graph.projectID, profileID: graph.managedServiceID,
                type: .gracefulStopRequested, result: .failed,
                errorDetails: error.localizedDescription,
                durationSeconds: Date().timeIntervalSince(startedAt)
            ))
            throw error
        }
    }

    func restartOwnedRuntime(
        _ listener: ObservedListener,
        verifiedConfiguration: ManagedServiceConfiguration? = nil
    ) async {
        let pid = listener.process.fingerprint.pid
        guard !processesBeingControlled.contains(pid) else { return }
        processesBeingControlled.insert(pid)
        defer { processesBeingControlled.remove(pid) }
        let startedAt = Date()
        do {
            let graph = await ownershipResolver.resolve(listener: listener)
            ownershipGraphs[listener.id] = graph
            await persistOwnership(graph.primaryConclusion, reportsError: false)
            if graph.recommendation.controllerKind == .managedProcess {
                guard let verifiedConfiguration,
                      graph.managedServiceID == verifiedConfiguration.id,
                      graph.managedConfigurationDigest == ManagedServiceConfigurationDigest.make(
                          for: verifiedConfiguration
                      ) else {
                    throw DevBerthError.restartTrustRequired(
                        service: listener.process.name,
                        reason: "The active runtime was launched from a different definition. Stop it and validate the current definition before restart."
                    )
                }
                try await requireVerifiedRestartTrust(for: verifiedConfiguration)
            }
            let outcome = try await lifecycleRouter.perform(
                .restart,
                on: graph,
                forceConfirmed: false
            )
            await record(HistoryEvent(
                id: UUID(), timestamp: startedAt, port: listener.port,
                processFingerprint: listener.process.fingerprint, processName: listener.process.name,
                projectID: graph.projectID, profileID: graph.managedServiceID,
                type: .restartRequested, result: .succeeded,
                errorDetails: outcome.summary, durationSeconds: outcome.durationSeconds
            ))
            refreshNow()
        } catch let error as DevBerthError {
            presentedError = error
            await record(HistoryEvent(
                id: UUID(), timestamp: startedAt, port: listener.port,
                processFingerprint: listener.process.fingerprint, processName: listener.process.name,
                projectID: nil, profileID: listener.process.managedServiceID,
                type: .restartRequested, result: .failed,
                errorDetails: error.localizedDescription,
                durationSeconds: Date().timeIntervalSince(startedAt)
            ))
        } catch {
            presentedError = .unexpected(error.localizedDescription)
        }
    }

    func launchProfile(_ profile: ManagedServiceConfiguration, bypassCachedConflict: Bool = false) async {
        let startedAt = Date()
        profileFailures[profile.id] = nil
        do {
            try await requireVerifiedRestartTrust(for: profile)
        } catch let error as DevBerthError {
            profileFailures[profile.id] = error.localizedDescription
            presentedError = error
            await record(HistoryEvent(
                id: UUID(), timestamp: startedAt, port: profile.expectedPorts.first?.port,
                processFingerprint: nil, processName: profile.name, projectID: profile.projectID,
                profileID: profile.id, type: .launchFailed, result: .failed,
                errorDetails: error.localizedDescription,
                durationSeconds: Date().timeIntervalSince(startedAt)
            ))
            return
        } catch {
            presentedError = .unexpected(error.localizedDescription)
            return
        }
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
            let graph = await ownershipResolver.resolve(listener: listener)
            ownershipGraphs[listener.id] = graph
            await persistOwnership(graph.primaryConclusion, reportsError: false)
            let outcome = try await lifecycleRouter.perform(
                .gracefulStop,
                on: graph,
                forceConfirmed: false
            )
            guard outcome.didStop else {
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
            for profile in profiles {
                try await requireVerifiedRestartTrust(for: profile)
            }
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

    func validateManagedService(
        _ profile: ManagedServiceConfiguration
    ) async -> ManagedServiceValidationResult {
        guard !servicesBeingValidated.contains(profile.id) else {
            return ManagedServiceValidationResult(
                id: UUID(),
                managedServiceID: profile.id,
                configurationDigest: ManagedServiceConfigurationDigest.make(for: profile),
                status: .failed,
                summary: "A validation run is already in progress for this service.",
                evidence: [],
                startedAt: Date(),
                completedAt: Date()
            )
        }
        servicesBeingValidated.insert(profile.id)
        defer { servicesBeingValidated.remove(profile.id) }
        return await validationService.validate(profile)
    }

    func recordRestartTrust(
        for profile: ManagedServiceConfiguration,
        validation: ManagedServiceValidationResult?
    ) async throws {
        guard let restartTrustStore else { return }
        if let validation {
            guard validation.managedServiceID == profile.id else {
                throw DevBerthError.unexpected("The validation result belongs to another managed service.")
            }
            try await restartTrustStore.record(validation)
        }
        let resolvedValidation: ManagedServiceValidationResult?
        if let validation {
            resolvedValidation = validation
        } else {
            resolvedValidation = try await restartTrustStore.latestValidation(for: profile.id)
        }
        let assessment = RestartTrustEvaluator.assessment(
            for: profile,
            validation: resolvedValidation
        )
        try await restartTrustStore.record(assessment)
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
            Task {
                await runtimeLifecycle.transition(.listenerObserved(listener, change: .discovered))
                await record(HistoryEvent(
                    id: UUID(), timestamp: Date(), port: listener.port,
                    processFingerprint: listener.process.fingerprint, processName: listener.process.name,
                    projectID: nil, profileID: listener.process.managedServiceID,
                    type: .portDetected, result: .observed, errorDetails: nil, durationSeconds: nil
                ))
            }
        }
        for listener in diff.updated {
            Task { await runtimeLifecycle.transition(.listenerObserved(listener, change: .changed)) }
        }
        for listener in diff.removed {
            notifyIfConfigured(listener, change: "was released")
            Task {
                await runtimeLifecycle.transition(.listenerObserved(listener, change: .released))
                await record(HistoryEvent(
                    id: UUID(), timestamp: Date(), port: listener.port,
                    processFingerprint: listener.process.fingerprint, processName: listener.process.name,
                    projectID: nil, profileID: listener.process.managedServiceID,
                    type: .portReleased, result: .observed, errorDetails: nil, durationSeconds: nil
                ))
            }
        }
    }

    private func requireVerifiedRestartTrust(
        for profile: ManagedServiceConfiguration
    ) async throws {
        guard let restartTrustStore else { return }
        let validation = try await restartTrustStore.latestValidation(for: profile.id)
        let summary = RestartTrustEvaluator.summary(for: profile, validation: validation)
        guard summary.state == .verifiedRestartable else {
            throw DevBerthError.restartTrustRequired(
                service: profile.name,
                reason: summary.reasons.joined(separator: " ")
            )
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

    private func handleManagedExit(_ notice: ManagedProcessExitNotice) async {
        runningProfileIDs.remove(notice.profile.id)
        await launchService.runtimeDidExit(profileID: notice.profile.id)
        guard !notice.intentional else { return }
        guard RestartPolicyEvaluator.shouldRestart(
            policy: notice.profile.restartPolicy,
            result: notice.result,
            intentional: notice.intentional
        ) else { return }

        while !Task.isCancelled {
            let startedAt = Date()
            var limiter = automaticRestartLimiters[notice.profile.id] ?? AutomaticRestartLimiter()
            guard let attempt = limiter.registerAttempt(at: startedAt) else {
                let reason = "Automatic restart stopped after three attempts within one minute."
                profileFailures[notice.profile.id] = reason
                await runtimeLifecycle.transition(.restartFailed(
                    serviceID: notice.profile.id,
                    reason: reason
                ))
                return
            }
            automaticRestartLimiters[notice.profile.id] = limiter
            let delay = RestartPolicyEvaluator.delaySeconds(forAttempt: attempt)
            await runtimeLifecycle.transition(.restartScheduled(
                serviceID: notice.profile.id,
                attempt: attempt,
                delaySeconds: delay
            ))
            do {
                try await Task.sleep(for: .seconds(delay))
                try await requireVerifiedRestartTrust(for: notice.profile)
                try await launchService.launch(notice.profile)
                runningProfileIDs.insert(notice.profile.id)
                profileFailures[notice.profile.id] = nil
                await record(HistoryEvent(
                    id: UUID(), timestamp: Date(), port: notice.profile.expectedPorts.first?.port,
                    processFingerprint: nil, processName: notice.profile.name,
                    projectID: notice.profile.projectID, profileID: notice.profile.id,
                    type: .restartRequested, result: .succeeded,
                    errorDetails: "Automatic restart attempt \(attempt) succeeded.",
                    durationSeconds: Date().timeIntervalSince(startedAt)
                ))
                return
            } catch is CancellationError {
                return
            } catch let error as DevBerthError {
                let reason = "Automatic restart attempt \(attempt) failed: \(error.localizedDescription)"
                profileFailures[notice.profile.id] = reason
                await runtimeLifecycle.transition(.restartFailed(
                    serviceID: notice.profile.id,
                    reason: reason
                ))
                await record(HistoryEvent(
                    id: UUID(), timestamp: Date(), port: notice.profile.expectedPorts.first?.port,
                    processFingerprint: nil, processName: notice.profile.name,
                    projectID: notice.profile.projectID, profileID: notice.profile.id,
                    type: .restartRequested, result: .failed,
                    errorDetails: reason,
                    durationSeconds: Date().timeIntervalSince(startedAt)
                ))
                if case .restartTrustRequired = error { return }
            } catch {
                let reason = "Automatic restart attempt \(attempt) failed: \(error.localizedDescription)"
                profileFailures[notice.profile.id] = reason
                await runtimeLifecycle.transition(.restartFailed(
                    serviceID: notice.profile.id,
                    reason: reason
                ))
                await record(HistoryEvent(
                    id: UUID(), timestamp: Date(), port: notice.profile.expectedPorts.first?.port,
                    processFingerprint: nil, processName: notice.profile.name,
                    projectID: notice.profile.projectID, profileID: notice.profile.id,
                    type: .restartRequested, result: .failed,
                    errorDetails: reason,
                    durationSeconds: Date().timeIntervalSince(startedAt)
                ))
            }
        }
    }
}
