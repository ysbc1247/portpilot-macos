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
    @Published var requestedProjectImport = false
    @Published var requestedManagedServiceCreation = false
    @Published var requestedSessionCapture = false
    @Published var requestedSessionID: UUID?
    @Published var requestedSessionRestoreID: UUID?
    @Published var requestedManagedServiceLogsID: UUID?
    @Published var requestedManagedServiceID: UUID?
    @Published var pendingLaunchConflict: PendingLaunchConflict?
    @Published private(set) var ownershipGraphs: [String: RuntimeOwnershipGraph] = [:]
    @Published private(set) var ownershipInspectionsInProgress = Set<String>()
    @Published private(set) var servicesBeingValidated = Set<UUID>()
    @Published private(set) var runtimeStatuses: [UUID: ManagedServiceRuntimeStatus] = [:]
    @Published private(set) var runtimeIncidents: [UUID: RuntimeIncidentSummary] = [:]
    @Published private(set) var processResourceUsage: [Int32: ProcessResourceUsage] = [:]
    @Published private(set) var projectOperations: [UUID: ProjectOperationStatus] = [:]
    @Published private(set) var serviceOperations: [UUID: ServiceOperationStatus] = [:]

    private let monitor: PortMonitor
    private let lifecycleRouter: any OwnerAwareLifecycleRouting
    private let historyRecorder: (any HistoryRecording)?
    private let ownershipRecorder: (any OwnershipRecording)?
    private let ownershipResolver: any RuntimeOwnershipResolving
    private let validationService: any ManagedServiceValidating
    private let secretStore: any SecretStoring
    private let restartTrustStore: (any RestartTrustStoring)?
    private let runtimeLifecycle: any RuntimeLifecycleObserving
    private let exitHub: ManagedProcessExitHub
    private let launchService: any LaunchProfileServing
    private let projectOrchestrator: ProjectOrchestrator
    private let workspaceSessions: WorkspaceSessionCoordinator
    private let notifier: any PortNotifying
    private let dockerAssociations: DockerAssociationProvider
    let dockerService: any DockerServing
    let lifecycleEventRecorder: (any RuntimeLifecycleRecording)?
    private let projectDiscovery: any ProjectDiscoveryServing
    private let projectManifest: any ProjectManifestServing
    private let processResourceReader: any ProcessResourceUsageReading
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
        projectManifest: (any ProjectManifestServing)? = nil,
        workspaceSessionRecorder: (any WorkspaceSessionRecording)? = nil,
        processResourceReader: (any ProcessResourceUsageReading)? = nil,
        runtimeRegistry: ManagedRuntimeRegistry? = nil
    ) {
        let runner = FoundationCommandRunner()
        let service = discoverer ?? LocalPortDiscovery(runner: runner)
        let logs = ServiceLogBuffer()
        let runtimeRegistry = runtimeRegistry ?? ManagedRuntimeRegistry()
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
        let resolvedSecrets = KeychainSecretStore()
        self.secretStore = resolvedSecrets
        let managedLauncher = ManagedProcessLauncher(
            secrets: resolvedSecrets,
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
        self.dockerService = dockerClient
        self.lifecycleEventRecorder = lifecycleRecorder
        self.monitor = PortMonitor(discoverer: service)
        self.lifecycleRouter = lifecycleRouter ?? OwnerAwareLifecycleRouter(
            processController: resolvedProcessController,
            managedServiceController: coordinator,
            dockerController: dockerClient,
            runtimeRegistry: runtimeRegistry,
            lifecycleRecorder: lifecycleRecorder
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
        self.workspaceSessions = WorkspaceSessionCoordinator(
            launcher: coordinator,
            trustStore: restartTrustStore,
            secrets: resolvedSecrets,
            listenerDiscoverer: service,
            recorder: workspaceSessionRecorder,
            lifecycleRecorder: lifecycleRecorder
        )
        self.logBuffer = logs
        self.notifier = LocalNotificationService()
        self.dockerAssociations = DockerAssociationProvider(
            client: dockerClient,
            lifecycleRecorder: lifecycleRecorder
        )
        self.projectDiscovery = projectDiscovery ?? LocalProjectDiscoveryService()
        self.projectManifest = projectManifest ?? LocalProjectManifestService()
        self.processResourceReader = processResourceReader ?? SystemProcessResourceUsageReader(runner: runner)
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
                processResourceUsage = (try? await processResourceReader.read(
                    pids: Set(listeners.map { $0.process.fingerprint.pid })
                )) ?? [:]
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

    func requestProjectImport() {
        requestedProjectImport = true
        requestedSection = .projects
    }

    func requestManagedServiceCreation() {
        requestedManagedServiceCreation = true
        requestedSection = .managedServices
    }

    func requestSessionCapture() {
        requestedSessionCapture = true
        requestedSection = .sessions
    }

    func requestSession(_ id: UUID) {
        requestedSessionID = id
        requestedSection = .sessions
    }

    func requestSessionRestore(_ id: UUID) {
        requestedSessionRestoreID = id
        requestedSection = .sessions
    }

    func requestManagedServiceLogs(_ id: UUID) {
        requestedManagedServiceLogsID = id
        requestedSection = .managedServices
    }

    func requestManagedService(_ id: UUID) {
        requestedManagedServiceID = id
        requestedSection = .managedServices
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

    func captureWorkspaceSession(
        name: String,
        projectIDs: [UUID],
        services: [ManagedServiceConfiguration],
        projectRootPaths: Set<String>,
        notes: String?
    ) async -> WorkspaceSession? {
        do {
            return try await workspaceSessions.capture(
                name: name,
                projectIDs: projectIDs,
                services: services,
                currentState: workspaceCurrentState(projectRootPaths: projectRootPaths),
                notes: notes
            )
        } catch {
            presentedError = .unexpected("The workspace session could not be captured: \(error.localizedDescription)")
            return nil
        }
    }

    func compareWorkspaceSession(
        _ session: WorkspaceSession,
        services: [ManagedServiceConfiguration],
        projectRootPaths: Set<String>
    ) async -> WorkspaceSessionComparison {
        await workspaceSessions.compare(
            session: session,
            services: services,
            currentState: workspaceCurrentState(projectRootPaths: projectRootPaths)
        )
    }

    func previewWorkspaceSession(
        _ session: WorkspaceSession,
        services: [ManagedServiceConfiguration]
    ) async throws -> SessionRestorePlan {
        try await workspaceSessions.preview(
            session: session,
            services: services,
            runningServiceIDs: currentRunningServiceIDs
        )
    }

    func restoreWorkspaceSession(
        _ session: WorkspaceSession,
        services: [ManagedServiceConfiguration],
        options: SessionRestoreOptions
    ) async -> SessionRestoreExecution? {
        do {
            let execution = try await workspaceSessions.restore(
                session: session,
                services: services,
                runningServiceIDs: currentRunningServiceIDs,
                options: options
            )
            let rolledBack = Set(execution.result.rolledBackServiceIDs)
            runningProfileIDs.formUnion(execution.result.startedServiceIDs.filter { !rolledBack.contains($0) })
            runningProfileIDs.subtract(rolledBack)
            runningProfileIDs.subtract(execution.stoppedServiceIDs)
            refreshNow()
            return execution
        } catch let error as WorkspaceSessionRestoreError {
            presentedError = .unexpected(error.localizedDescription)
        } catch {
            presentedError = .unexpected("The workspace session could not be restored: \(error.localizedDescription)")
        }
        return nil
    }

    private var currentRunningServiceIDs: Set<UUID> {
        runningProfileIDs.union(runtimeStatuses.compactMap { id, status in
            status.processRunning ? id : nil
        })
    }

    private func workspaceCurrentState(projectRootPaths: Set<String>) -> WorkspaceSessionCurrentState {
        WorkspaceSessionCurrentState(
            runningServiceIDs: currentRunningServiceIDs,
            healthStates: runtimeStatuses.mapValues(\.healthState),
            listeners: listeners,
            selectedProjectRootPaths: projectRootPaths
        )
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

    func resolveOwnership(of listener: ObservedListener) async -> RuntimeOwnershipGraph {
        let graph = await ownershipResolver.resolve(listener: listener)
        ownershipGraphs[listener.id] = graph
        await persistOwnership(graph.primaryConclusion, reportsError: false)
        return graph
    }

    func secretReferenceResolution(for references: [String: UUID]) async -> [String: Bool] {
        var result: [String: Bool] = [:]
        for (name, reference) in references {
            result[name] = (try? await secretStore.value(for: reference)) != nil
        }
        return result
    }

    var managedRunningServiceIDs: Set<UUID> { currentRunningServiceIDs }

    func managedServiceActivity(
        for profile: ManagedServiceConfiguration
    ) -> ManagedServiceActivityEvidence {
        ManagedServiceActivityResolver.resolve(
            profile: profile,
            listeners: listeners,
            runningProfileIDs: runningProfileIDs,
            runtimeStatus: runtimeStatuses[profile.id]
        )
    }

    func isManagedServiceRunning(_ profileID: UUID) -> Bool {
        runningProfileIDs.contains(profileID) || runtimeStatuses[profileID]?.processRunning == true
    }

    func inspectObservedRuntime(for profile: ManagedServiceConfiguration) {
        let activity = managedServiceActivity(for: profile)
        guard activity.state == .observed,
              let listener = listeners.first(where: { activity.matchingListenerIDs.contains($0.id) })
        else { return }
        selectedListenerID = listener.id
        requestedSection = .runtime
    }

    func observedServiceStopTargets(
        for profile: ManagedServiceConfiguration
    ) -> [ObservedListener] {
        let activity = managedServiceActivity(for: profile)
        guard activity.state == .observed else { return [] }
        let matches = listeners.filter { activity.matchingListenerIDs.contains($0.id) }
        var processFingerprints = Set<ProcessFingerprint>()
        var dockerTargets = Set<String>()
        return matches.filter { listener in
            if let docker = listener.process.docker {
                let key = docker.composeContext.map {
                    "compose:\($0.projectName):\($0.serviceName)"
                } ?? "container:\(docker.containerID)"
                return dockerTargets.insert(key).inserted
            }
            return processFingerprints.insert(listener.process.fingerprint).inserted
        }
        .sorted { lhs, rhs in
            if lhs.port != rhs.port { return lhs.port < rhs.port }
            return lhs.process.fingerprint.pid < rhs.process.fingerprint.pid
        }
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
        guard serviceOperations[profile.id]?.isRunning != true else { return }
        serviceOperations[profile.id] = ServiceOperationStatus(
            serviceID: profile.id,
            kind: .start,
            phase: .running,
            completedTargetCount: 0,
            totalTargetCount: 1,
            message: String(localized: "Starting \(profile.name)…"),
            startedAt: startedAt,
            finishedAt: nil
        )
        profileFailures[profile.id] = nil
        do {
            try await requireVerifiedRestartTrust(for: profile)
        } catch let error as DevBerthError {
            profileFailures[profile.id] = error.localizedDescription
            presentedError = error
            finishServiceOperation(
                profile,
                kind: .start,
                phase: .failed,
                message: error.localizedDescription,
                startedAt: startedAt
            )
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
            finishServiceOperation(
                profile,
                kind: .start,
                phase: .failed,
                message: error.localizedDescription,
                startedAt: startedAt
            )
            return
        }
        if !bypassCachedConflict,
           let conflict = PortConflictDetector.conflicts(for: profile, listeners: listeners).first {
            pendingLaunchConflict = PendingLaunchConflict(profile: profile, conflict: conflict)
            finishServiceOperation(
                profile,
                kind: .start,
                phase: .failed,
                message: String(localized: "Start paused because port \(conflict.expectedPort.port) is occupied."),
                startedAt: startedAt
            )
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
            finishServiceOperation(
                profile,
                kind: .start,
                phase: .succeeded,
                message: String(localized: "Started \(profile.name)."),
                startedAt: startedAt
            )
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
            finishServiceOperation(
                profile,
                kind: .start,
                phase: .failed,
                message: error.localizedDescription,
                startedAt: startedAt
            )
            await record(HistoryEvent(
                id: UUID(), timestamp: startedAt, port: profile.expectedPorts.first?.port,
                processFingerprint: nil, processName: profile.name, projectID: profile.projectID,
                profileID: profile.id, type: .launchFailed, result: .failed,
                errorDetails: error.localizedDescription, durationSeconds: Date().timeIntervalSince(startedAt)
            ))
        } catch {
            profileFailures[profile.id] = error.localizedDescription
            presentedError = .unexpected(error.localizedDescription)
            finishServiceOperation(
                profile,
                kind: .start,
                phase: .failed,
                message: error.localizedDescription,
                startedAt: startedAt
            )
        }
    }

    func inspectPendingConflict() {
        guard let pendingLaunchConflict else { return }
        selectedListenerID = pendingLaunchConflict.conflict.listener.id
        requestedSection = .runtime
        self.pendingLaunchConflict = nil
    }

    func editProfileForPendingConflict() {
        requestedSection = .managedServices
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

    func stopProfile(
        _ profile: ManagedServiceConfiguration,
        confirmsObservedProcess: Bool = false
    ) async {
        guard serviceOperations[profile.id]?.isRunning != true else { return }
        let startedAt = Date()
        let activity = managedServiceActivity(for: profile)
        let targets = activity.state == .observed ? observedServiceStopTargets(for: profile) : []
        let totalTargetCount = activity.state == .observed ? max(1, targets.count) : 1
        serviceOperations[profile.id] = ServiceOperationStatus(
            serviceID: profile.id,
            kind: .stop,
            phase: .running,
            completedTargetCount: 0,
            totalTargetCount: totalTargetCount,
            message: activity.state == .observed
                ? String(localized: "Revalidating the observed owner of \(profile.name)…")
                : String(localized: "Stopping \(profile.name)…"),
            startedAt: startedAt,
            finishedAt: nil
        )
        do {
            let stoppedTargets = try await performServiceStop(
                profile,
                activity: activity,
                observedTargets: targets,
                confirmsObservedProcess: confirmsObservedProcess
            )
            finishServiceOperation(
                profile,
                kind: .stop,
                phase: .succeeded,
                completedTargetCount: stoppedTargets,
                totalTargetCount: max(stoppedTargets, totalTargetCount),
                message: activity.state == .stopped
                    ? String(localized: "\(profile.name) is already stopped.")
                    : String(localized: "Stopped \(profile.name). Refreshing runtime evidence…"),
                startedAt: startedAt
            )
            refreshNow()
        } catch let error as DevBerthError {
            presentedError = error
            finishServiceOperation(
                profile,
                kind: .stop,
                phase: .failed,
                message: error.localizedDescription,
                startedAt: startedAt
            )
        } catch {
            presentedError = .unexpected(error.localizedDescription)
            finishServiceOperation(
                profile,
                kind: .stop,
                phase: .failed,
                message: error.localizedDescription,
                startedAt: startedAt
            )
        }
    }

    func dismissServiceOperation(_ serviceID: UUID) {
        guard serviceOperations[serviceID]?.isRunning != true else { return }
        serviceOperations.removeValue(forKey: serviceID)
    }

    private func performServiceStop(
        _ profile: ManagedServiceConfiguration,
        activity: ManagedServiceActivityEvidence,
        observedTargets: [ObservedListener],
        confirmsObservedProcess: Bool
    ) async throws -> Int {
        switch activity.state {
        case .controlled:
            try await launchService.stop(
                profileID: profile.id,
                timeoutSeconds: profile.shutdownTimeoutSeconds
            )
            runningProfileIDs.remove(profile.id)
            await record(HistoryEvent(
                id: UUID(), timestamp: Date(), port: profile.expectedPorts.first?.port,
                processFingerprint: nil, processName: profile.name, projectID: profile.projectID,
                profileID: profile.id, type: .processStopped, result: .succeeded,
                errorDetails: nil, durationSeconds: nil
            ))
            return 1
        case .observed:
            guard confirmsObservedProcess else {
                throw DevBerthError.unexpected(
                    "Stopping \(profile.name) will terminate process or container activity that DevBerth did not launch. Confirm the observed-runtime stop before continuing."
                )
            }
            guard !observedTargets.isEmpty else {
                throw DevBerthError.unexpected(
                    "The observed runtime for \(profile.name) changed before the stop. Refresh and try again."
                )
            }
            var completed = 0
            for listener in observedTargets {
                serviceOperations[profile.id] = ServiceOperationStatus(
                    serviceID: profile.id,
                    kind: .stop,
                    phase: .running,
                    completedTargetCount: completed,
                    totalTargetCount: observedTargets.count,
                    message: String(localized: "Stopping observed owner \(completed + 1) of \(observedTargets.count) for \(profile.name)…"),
                    startedAt: serviceOperations[profile.id]?.startedAt ?? Date(),
                    finishedAt: nil
                )
                try await stopObservedServiceTarget(listener, profile: profile)
                completed += 1
            }
            return completed
        case .stopped:
            runningProfileIDs.remove(profile.id)
            return 0
        }
    }

    private func stopObservedServiceTarget(
        _ listener: ObservedListener,
        profile: ManagedServiceConfiguration
    ) async throws {
        let pid = listener.process.fingerprint.pid
        guard !processesBeingControlled.contains(pid) else {
            throw DevBerthError.unexpected("A lifecycle action is already in progress for PID \(pid).")
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
                processFingerprint: listener.process.fingerprint,
                processName: listener.process.name,
                projectID: profile.projectID,
                profileID: profile.id,
                type: .gracefulStopRequested,
                result: .succeeded,
                errorDetails: outcome.summary,
                durationSeconds: outcome.durationSeconds
            ))
        } catch {
            await record(HistoryEvent(
                id: UUID(), timestamp: startedAt, port: listener.port,
                processFingerprint: listener.process.fingerprint,
                processName: listener.process.name,
                projectID: profile.projectID,
                profileID: profile.id,
                type: .gracefulStopRequested,
                result: .failed,
                errorDetails: error.localizedDescription,
                durationSeconds: Date().timeIntervalSince(startedAt)
            ))
            throw error
        }
    }

    private func finishServiceOperation(
        _ profile: ManagedServiceConfiguration,
        kind: ProjectOperationKind,
        phase: ProjectOperationPhase,
        completedTargetCount: Int? = nil,
        totalTargetCount: Int? = nil,
        message: String,
        startedAt: Date
    ) {
        let current = serviceOperations[profile.id]
        serviceOperations[profile.id] = ServiceOperationStatus(
            serviceID: profile.id,
            kind: kind,
            phase: phase,
            completedTargetCount: completedTargetCount ?? current?.completedTargetCount ?? 0,
            totalTargetCount: totalTargetCount ?? current?.totalTargetCount ?? 1,
            message: message,
            startedAt: startedAt,
            finishedAt: Date()
        )
    }

    func startProject(_ profiles: [ManagedServiceConfiguration]) async {
        guard let projectID = exactProjectID(for: profiles) else {
            presentedError = .unexpected(String(localized: "Project startup requires one non-empty project definition."))
            return
        }
        guard projectOperations[projectID]?.isRunning != true else { return }

        let targets = profiles.filter { managedServiceActivity(for: $0).state == .stopped }
        let targetIDs = Set(targets.map(\.id))
        let skippedIDs = Set(profiles.map(\.id)).subtracting(targetIDs)
        let startedAt = Date()
        guard !targets.isEmpty else {
            projectOperations[projectID] = ProjectOperationStatus(
                projectID: projectID,
                kind: .start,
                phase: .succeeded,
                completedServiceCount: 0,
                totalServiceCount: 0,
                message: String(localized: "All project services are already active or externally observed."),
                startedAt: startedAt,
                finishedAt: Date()
            )
            return
        }
        projectOperations[projectID] = ProjectOperationStatus(
            projectID: projectID,
            kind: .start,
            phase: .running,
            completedServiceCount: 0,
            totalServiceCount: targets.count,
            message: String(localized: "Checking exact restart trust before starting \(targets.count) service(s)…"),
            startedAt: startedAt,
            finishedAt: nil
        )
        do {
            for profile in targets {
                updateProjectOperation(
                    projectID: projectID,
                    kind: .start,
                    completed: 0,
                    total: targets.count,
                    message: String(localized: "Checking restart trust for \(profile.name)…"),
                    startedAt: startedAt
                )
                try await requireVerifiedRestartTrust(for: profile)
            }
            let result = try await projectOrchestrator.start(
                profiles: profiles,
                skippingProfileIDs: skippedIDs
            ) { [weak self] completed, total in
                await self?.updateProjectOperation(
                    projectID: projectID,
                    kind: .start,
                    completed: completed,
                    total: total,
                    message: completed == 0
                        ? String(localized: "Starting the first dependency layer…")
                        : String(localized: "Started \(completed) of \(total) service(s)…"),
                    startedAt: startedAt
                )
            }
            runningProfileIDs.formUnion(result.startedProfileIDs)
            for profile in targets where result.startedProfileIDs.contains(profile.id) {
                await record(HistoryEvent(
                    id: UUID(), timestamp: startedAt, port: profile.expectedPorts.first?.port,
                    processFingerprint: nil, processName: profile.name, projectID: profile.projectID,
                    profileID: profile.id, type: .launchSucceeded, result: .succeeded,
                    errorDetails: nil, durationSeconds: result.durationSeconds
                ))
            }
            let skippedMessage = skippedIDs.isEmpty
                ? ""
                : String(localized: " \(skippedIDs.count) already-active service(s) were left unchanged.")
            projectOperations[projectID] = ProjectOperationStatus(
                projectID: projectID,
                kind: .start,
                phase: .succeeded,
                completedServiceCount: result.startedProfileIDs.count,
                totalServiceCount: targets.count,
                message: String(localized: "Started \(result.startedProfileIDs.count) service(s) in \(result.durationSeconds.formatted(.number.precision(.fractionLength(1)))) seconds.\(skippedMessage)"),
                startedAt: startedAt,
                finishedAt: Date()
            )
            refreshNow()
        } catch {
            let completed = projectOperations[projectID]?.completedServiceCount ?? 0
            let message = String(localized: "Project startup stopped after \(completed) of \(targets.count) service(s): \(error.localizedDescription)")
            projectOperations[projectID] = ProjectOperationStatus(
                projectID: projectID,
                kind: .start,
                phase: .failed,
                completedServiceCount: completed,
                totalServiceCount: targets.count,
                message: message,
                startedAt: startedAt,
                finishedAt: Date()
            )
            presentedError = .unexpected(message)
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

    func stopProject(
        _ profiles: [ManagedServiceConfiguration],
        confirmsObservedProcesses: Bool = false
    ) async {
        guard let projectID = exactProjectID(for: profiles) else {
            presentedError = .unexpected(String(localized: "Project shutdown requires one non-empty project definition."))
            return
        }
        guard projectOperations[projectID]?.isRunning != true else { return }

        let activities = profiles.reduce(into: [UUID: ManagedServiceActivityEvidence]()) {
            $0[$1.id] = managedServiceActivity(for: $1)
        }
        let targets = profiles.filter { activities[$0.id]?.state != .stopped }
        let targetIDs = Set(targets.map(\.id))
        let skippedIDs = Set(profiles.map(\.id)).subtracting(targetIDs)
        let startedAt = Date()
        guard !targets.isEmpty else {
            projectOperations[projectID] = ProjectOperationStatus(
                projectID: projectID,
                kind: .stop,
                phase: .succeeded,
                completedServiceCount: 0,
                totalServiceCount: 0,
                message: String(localized: "All project services are already stopped."),
                startedAt: startedAt,
                finishedAt: Date()
            )
            return
        }
        projectOperations[projectID] = ProjectOperationStatus(
            projectID: projectID,
            kind: .stop,
            phase: .running,
            completedServiceCount: 0,
            totalServiceCount: targets.count,
            message: String(localized: "Stopping \(targets.count) service(s) in reverse dependency order…"),
            startedAt: startedAt,
            finishedAt: nil
        )
        do {
            let observedTargets = targets.filter { activities[$0.id]?.state == .observed }
            guard observedTargets.isEmpty || confirmsObservedProcesses else {
                throw DevBerthError.unexpected(
                    "Stopping this project includes \(observedTargets.count) service(s) that DevBerth did not launch. Confirm the observed-runtime stop before continuing."
                )
            }
            let layers = try DependencyPlanner.orderedLayers(for: profiles)
            var completed = 0
            for layer in layers.reversed() {
                for profile in layer where targetIDs.contains(profile.id) {
                    guard let activity = activities[profile.id] else { continue }
                    let serviceStartedAt = Date()
                    let observed = activity.state == .observed
                        ? observedServiceStopTargets(for: profile)
                        : []
                    serviceOperations[profile.id] = ServiceOperationStatus(
                        serviceID: profile.id,
                        kind: .stop,
                        phase: .running,
                        completedTargetCount: 0,
                        totalTargetCount: max(1, observed.count),
                        message: String(localized: "Stopping \(profile.name)…"),
                        startedAt: serviceStartedAt,
                        finishedAt: nil
                    )
                    do {
                        let stoppedTargets = try await performServiceStop(
                            profile,
                            activity: activity,
                            observedTargets: observed,
                            confirmsObservedProcess: confirmsObservedProcesses
                        )
                        finishServiceOperation(
                            profile,
                            kind: .stop,
                            phase: .succeeded,
                            completedTargetCount: stoppedTargets,
                            totalTargetCount: max(stoppedTargets, 1),
                            message: String(localized: "Stopped \(profile.name)."),
                            startedAt: serviceStartedAt
                        )
                    } catch {
                        finishServiceOperation(
                            profile,
                            kind: .stop,
                            phase: .failed,
                            message: error.localizedDescription,
                            startedAt: serviceStartedAt
                        )
                        throw error
                    }
                    completed += 1
                    updateProjectOperation(
                        projectID: projectID,
                        kind: .stop,
                        completed: completed,
                        total: targets.count,
                        message: String(localized: "Stopped \(completed) of \(targets.count) service(s)…"),
                        startedAt: startedAt
                    )
                }
            }
            runningProfileIDs.subtract(targetIDs)
            let duration = Date().timeIntervalSince(startedAt)
            let skippedMessage = skippedIDs.isEmpty
                ? ""
                : String(localized: " \(skippedIDs.count) already-stopped service(s) were left unchanged.")
            projectOperations[projectID] = ProjectOperationStatus(
                projectID: projectID,
                kind: .stop,
                phase: .succeeded,
                completedServiceCount: targets.count,
                totalServiceCount: targets.count,
                message: String(localized: "Stopped \(targets.count) service(s) in \(duration.formatted(.number.precision(.fractionLength(1)))) seconds.\(skippedMessage)"),
                startedAt: startedAt,
                finishedAt: Date()
            )
            refreshNow()
        } catch {
            let completed = projectOperations[projectID]?.completedServiceCount ?? 0
            let message = String(localized: "Project shutdown stopped after \(completed) of \(targets.count) service(s): \(error.localizedDescription)")
            projectOperations[projectID] = ProjectOperationStatus(
                projectID: projectID,
                kind: .stop,
                phase: .failed,
                completedServiceCount: completed,
                totalServiceCount: targets.count,
                message: message,
                startedAt: startedAt,
                finishedAt: Date()
            )
            presentedError = .unexpected(message)
        }
    }

    func dismissProjectOperation(_ projectID: UUID) {
        guard projectOperations[projectID]?.isRunning != true else { return }
        projectOperations.removeValue(forKey: projectID)
    }

    private func exactProjectID(for profiles: [ManagedServiceConfiguration]) -> UUID? {
        guard
            let projectID = profiles.first?.projectID,
            profiles.allSatisfy({ $0.projectID == projectID })
        else { return nil }
        return projectID
    }

    private func updateProjectOperation(
        projectID: UUID,
        kind: ProjectOperationKind,
        completed: Int,
        total: Int,
        message: String,
        startedAt: Date
    ) {
        projectOperations[projectID] = ProjectOperationStatus(
            projectID: projectID,
            kind: kind,
            phase: .running,
            completedServiceCount: completed,
            totalServiceCount: total,
            message: message,
            startedAt: startedAt,
            finishedAt: nil
        )
    }

    private func recordPortChanges(_ diff: RuntimeDiff) {
        for listener in diff.added {
            notifyIfConfigured(listener, change: "became active")
        }
        for listener in diff.removed {
            notifyIfConfigured(listener, change: "was released")
        }
        let lifecycleUpdates = diff.added.map { RuntimeLifecycleUpdate.listenerObserved($0, change: .discovered) }
            + diff.updated.map { RuntimeLifecycleUpdate.listenerObserved($0, change: .changed) }
            + diff.removed.map { RuntimeLifecycleUpdate.listenerObserved($0, change: .released) }
        let historyEvents = diff.added.map { listener in
            HistoryEvent(
                id: UUID(), timestamp: Date(), port: listener.port,
                processFingerprint: listener.process.fingerprint, processName: listener.process.name,
                projectID: nil, profileID: listener.process.managedServiceID,
                type: .portDetected, result: .observed, errorDetails: nil, durationSeconds: nil
            )
        } + diff.removed.map { listener in
            HistoryEvent(
                    id: UUID(), timestamp: Date(), port: listener.port,
                    processFingerprint: listener.process.fingerprint, processName: listener.process.name,
                    projectID: nil, profileID: listener.process.managedServiceID,
                    type: .portReleased, result: .observed, errorDetails: nil, durationSeconds: nil
            )
        }
        guard !lifecycleUpdates.isEmpty || !historyEvents.isEmpty else { return }
        Task {
            await runtimeLifecycle.transition(lifecycleUpdates)
            await record(historyEvents)
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

    private func record(_ events: [HistoryEvent]) async {
        guard let historyRecorder, !events.isEmpty else { return }
        do { try await historyRecorder.record(events) }
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
