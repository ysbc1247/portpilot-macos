import Foundation
import OSLog

actor WorkspaceSessionCoordinator {
    private struct OperationOutcome: Sendable {
        let serviceID: UUID
        let error: String?
    }

    private let launcher: any LaunchProfileServing
    private let trustStore: (any RestartTrustStoring)?
    private let secrets: any SecretStoring
    private let listenerDiscoverer: any PortDiscovering
    private let recorder: (any WorkspaceSessionRecording)?
    private let lifecycleRecorder: (any RuntimeLifecycleRecording)?
    private let resolver: ExecutableResolver
    private let fileManager: FileManager

    init(
        launcher: any LaunchProfileServing,
        trustStore: (any RestartTrustStoring)?,
        secrets: any SecretStoring,
        listenerDiscoverer: any PortDiscovering,
        recorder: (any WorkspaceSessionRecording)? = nil,
        lifecycleRecorder: (any RuntimeLifecycleRecording)? = nil,
        resolver: ExecutableResolver = ExecutableResolver(),
        fileManager: FileManager = .default
    ) {
        self.launcher = launcher
        self.trustStore = trustStore
        self.secrets = secrets
        self.listenerDiscoverer = listenerDiscoverer
        self.recorder = recorder
        self.lifecycleRecorder = lifecycleRecorder
        self.resolver = resolver
        self.fileManager = fileManager
    }

    func capture(
        name: String,
        projectIDs: [UUID],
        services: [ManagedServiceConfiguration],
        currentState: WorkspaceSessionCurrentState,
        notes: String?,
        capturedAt: Date = Date()
    ) async throws -> WorkspaceSession {
        let selectedProjects = Set(projectIDs)
        let selectedServices = services
            .filter { service in service.projectID.map(selectedProjects.contains) ?? false }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let snapshots = selectedServices.map { service in
            let isRunning = currentState.runningServiceIDs.contains(service.id)
            let observedListeners = currentState.listeners.filter {
                $0.process.managedServiceID == service.id
            }
            let capturedListeners: [ExpectedListenerConfiguration]
            if isRunning, !observedListeners.isEmpty {
                let unique = Dictionary(grouping: observedListeners, by: { "\($0.protocolKind.rawValue):\($0.port)" })
                    .values.compactMap(\.first)
                    .sorted { lhs, rhs in
                        lhs.port == rhs.port
                            ? lhs.protocolKind.rawValue < rhs.protocolKind.rawValue
                            : lhs.port < rhs.port
                    }
                capturedListeners = unique.map {
                    ExpectedListenerConfiguration(
                        id: UUID(),
                        port: $0.port,
                        protocolKind: $0.protocolKind,
                        required: true
                    )
                }
            } else {
                capturedListeners = service.expectedPorts
            }
            return WorkspaceSessionServiceSnapshot(
                managedServiceID: service.id,
                expectedState: isRunning ? .running : .stopped,
                expectedListeners: capturedListeners,
                dependencyServiceIDs: service.dependencyServiceIDs,
                previousHealthState: currentState.healthStates[service.id] ?? .unknown,
                configurationDigest: ManagedServiceConfigurationDigest.make(for: service)
            )
        }
        let session = WorkspaceSession(
            name: name,
            projectIDs: projectIDs.sorted { $0.uuidString < $1.uuidString },
            serviceSnapshots: snapshots,
            capturedAt: capturedAt,
            notes: notes?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
        try await recorder?.record(session)
        await recordLifecycle(LifecycleEvent(
            timestamp: capturedAt,
            sessionID: session.id,
            category: .sessionCapture,
            outcome: .succeeded,
            severity: .notice,
            source: .session,
            trigger: .userAction,
            summary: "Captured workspace session \(session.name).",
            details: [
                "projectCount": String(session.projectIDs.count),
                "serviceCount": String(session.serviceSnapshots.count),
                "runningCount": String(session.serviceSnapshots.filter { $0.expectedState == .running }.count)
            ]
        ))
        return session
    }

    func compare(
        session: WorkspaceSession,
        services: [ManagedServiceConfiguration],
        currentState: WorkspaceSessionCurrentState
    ) -> WorkspaceSessionComparison {
        let snapshotsByID = Dictionary(uniqueKeysWithValues: session.serviceSnapshots.map { ($0.managedServiceID, $0) })
        let servicesByID = Dictionary(uniqueKeysWithValues: services.map { ($0.id, $0) })
        let sessionServiceIDs = Set(snapshotsByID.keys)
        let projectIDs = Set(session.projectIDs)
        let added = services.filter {
            ($0.projectID.map(projectIDs.contains) ?? false) && !sessionServiceIDs.contains($0.id)
        }.map(\.id).sorted { $0.uuidString < $1.uuidString }
        let missing = session.serviceSnapshots
            .filter { servicesByID[$0.managedServiceID] == nil }
            .map(\.managedServiceID)
        let drift = session.serviceSnapshots.compactMap { snapshot -> UUID? in
            guard let service = servicesByID[snapshot.managedServiceID] else { return nil }
            return ManagedServiceConfigurationDigest.make(for: service) == snapshot.configurationDigest
                ? nil
                : snapshot.managedServiceID
        }
        var portChanges: [SessionPortChange] = []
        var healthChanges: [SessionHealthChange] = []
        for snapshot in session.serviceSnapshots where snapshot.expectedState == .running {
            let name = servicesByID[snapshot.managedServiceID]?.name ?? snapshot.managedServiceID.uuidString
            let savedPorts = Set(snapshot.expectedListeners.map(\.port))
            let currentPorts = Set(currentState.listeners.filter {
                $0.process.managedServiceID == snapshot.managedServiceID
            }.map(\.port))
            if currentState.runningServiceIDs.contains(snapshot.managedServiceID), savedPorts != currentPorts {
                portChanges.append(SessionPortChange(
                    serviceID: snapshot.managedServiceID,
                    serviceName: name,
                    savedPorts: savedPorts,
                    currentPorts: currentPorts
                ))
            }
            let health = currentState.healthStates[snapshot.managedServiceID] ?? .unknown
            if snapshot.previousHealthState != .unknown, snapshot.previousHealthState != health {
                healthChanges.append(SessionHealthChange(
                    serviceID: snapshot.managedServiceID,
                    serviceName: name,
                    saved: snapshot.previousHealthState,
                    current: health
                ))
            }
        }
        let unexpected = currentState.listeners.filter { listener in
            guard listener.process.managedServiceID == nil,
                  let root = listener.process.project?.rootPath else { return false }
            return currentState.selectedProjectRootPaths.contains { selected in
                root == selected || root.hasPrefix(selected + "/")
            }
        }
        return WorkspaceSessionComparison(
            addedServiceIDs: added,
            missingServiceIDs: missing,
            configurationDriftServiceIDs: drift,
            portChanges: portChanges.sorted { $0.serviceName < $1.serviceName },
            healthChanges: healthChanges.sorted { $0.serviceName < $1.serviceName },
            unexpectedListeners: unexpected.sorted { $0.port < $1.port }
        )
    }

    func preview(
        session: WorkspaceSession,
        services: [ManagedServiceConfiguration],
        runningServiceIDs: Set<UUID>,
        createdAt: Date = Date()
    ) async throws -> SessionRestorePlan {
        let listeners = try await listenerDiscoverer.discover()
        let servicesByID = Dictionary(uniqueKeysWithValues: services.map { ($0.id, $0) })
        var actions: [SessionRestoreAction] = []
        var issues: [SessionRestoreIssue] = []
        var expectedRunningProfiles: [ManagedServiceConfiguration] = []

        for snapshot in session.serviceSnapshots {
            guard let service = servicesByID[snapshot.managedServiceID] else {
                actions.append(SessionRestoreAction(
                    serviceID: snapshot.managedServiceID,
                    serviceName: snapshot.managedServiceID.uuidString,
                    projectID: nil,
                    kind: .missing,
                    expectedPorts: snapshot.expectedListeners.map(\.port),
                    dependencyServiceIDs: snapshot.dependencyServiceIDs,
                    reason: "The captured managed service no longer exists."
                ))
                issues.append(issue(
                    kind: .missingService,
                    severity: .blocking,
                    serviceID: snapshot.managedServiceID,
                    discriminator: "service",
                    summary: "A captured managed service is missing.",
                    recovery: "Recreate or re-import the service, then capture or preview the session again."
                ))
                continue
            }
            let isRunning = runningServiceIDs.contains(service.id)
            let actionKind: SessionRestoreActionKind
            switch (snapshot.expectedState, isRunning) {
            case (.running, false): actionKind = .start
            case (.running, true): actionKind = .alreadyRunning
            case (.stopped, true): actionKind = .stop
            case (.stopped, false): actionKind = .alreadyStopped
            }
            actions.append(SessionRestoreAction(
                serviceID: service.id,
                serviceName: service.name,
                projectID: service.projectID,
                kind: actionKind,
                expectedPorts: service.expectedPorts.map(\.port),
                dependencyServiceIDs: service.dependencyServiceIDs,
                reason: actionReason(kind: actionKind)
            ))

            let currentDigest = ManagedServiceConfigurationDigest.make(for: service)
            if currentDigest != snapshot.configurationDigest {
                issues.append(issue(
                    kind: .configurationDrift,
                    severity: .confirmationRequired,
                    serviceID: service.id,
                    discriminator: currentDigest,
                    summary: "\(service.name) changed after this session was captured.",
                    recovery: "Review and validate the current definition, then explicitly accept restoring with it."
                ))
            }
            if actionKind == .stop {
                issues.append(issue(
                    kind: .expectedStoppedServiceRunning,
                    severity: .confirmationRequired,
                    serviceID: service.id,
                    discriminator: "running",
                    summary: "\(service.name) is running but the saved session expects it stopped.",
                    recovery: "Choose whether the restore should stop it after all required services become ready."
                ))
            }
            guard actionKind == .start else { continue }
            expectedRunningProfiles.append(service)
            issues.append(contentsOf: await preflightIssues(for: service, listeners: listeners, servicesByID: servicesByID))
        }

        let allExpectedRunningProfiles = session.serviceSnapshots
            .filter { $0.expectedState == .running }
            .compactMap { servicesByID[$0.managedServiceID] }
        let expectedRunningIDs = Set(allExpectedRunningProfiles.map(\.id))
        for profile in allExpectedRunningProfiles {
            for dependencyID in profile.dependencyServiceIDs where !expectedRunningIDs.contains(dependencyID) {
                issues.append(issue(
                    kind: .missingDependency,
                    severity: .blocking,
                    serviceID: profile.id,
                    discriminator: dependencyID.uuidString,
                    summary: "\(profile.name) depends on a service that is not expected to run in this session.",
                    recovery: "Include the dependency as running, or remove the dependency after reviewing the service definition."
                ))
            }
        }

        var orderedStartLayers: [[UUID]] = []
        if issues.contains(where: { $0.kind == .missingDependency }) == false {
            do {
                let layers = try DependencyPlanner.orderedLayers(for: allExpectedRunningProfiles)
                let startIDs = Set(expectedRunningProfiles.map(\.id))
                orderedStartLayers = layers.map { layer in
                    layer.map(\.id).filter(startIDs.contains)
                }.filter { !$0.isEmpty }
            } catch {
                issues.append(issue(
                    kind: .dependencyCycle,
                    severity: .blocking,
                    serviceID: nil,
                    discriminator: "graph",
                    summary: "The session dependency graph cannot be ordered.",
                    recovery: error.localizedDescription
                ))
            }
        }
        return SessionRestorePlan(
            sessionID: session.id,
            createdAt: createdAt,
            actions: actions.sorted { $0.serviceName < $1.serviceName },
            issues: deduplicated(issues),
            orderedStartLayers: orderedStartLayers
        )
    }

    func restore(
        session: WorkspaceSession,
        services: [ManagedServiceConfiguration],
        runningServiceIDs: Set<UUID>,
        options: SessionRestoreOptions,
        now: @Sendable () -> Date = { Date() }
    ) async throws -> SessionRestoreExecution {
        let plan = try await preview(
            session: session,
            services: services,
            runningServiceIDs: runningServiceIDs,
            createdAt: now()
        )
        let startedAt = now()
        let startEvent = LifecycleEvent(
            timestamp: startedAt,
            sessionID: session.id,
            category: .sessionRestore,
            outcome: .pending,
            severity: .notice,
            source: .session,
            trigger: .userAction,
            summary: options.dryRun ? "Previewed workspace session restore." : "Started workspace session restore.",
            details: [
                "actionCount": String(plan.estimatedMutationCount),
                "dryRun": String(options.dryRun)
            ]
        )
        await recordLifecycle(startEvent)

        if options.dryRun {
            let result = SessionRestoreResult(
                id: UUID(),
                sessionID: session.id,
                startedAt: startedAt,
                finishedAt: now(),
                outcome: .dryRun,
                startedServiceIDs: [],
                rolledBackServiceIDs: [],
                errors: plan.issues.map(\.summary)
            )
            await recordResult(result)
            await recordCompletion(result, relatedTo: startEvent.id)
            return SessionRestoreExecution(plan: plan, result: result, stoppedServiceIDs: [])
        }
        if !plan.blockingIssues.isEmpty {
            let reasons = plan.blockingIssues.map(\.summary)
            let result = SessionRestoreResult(
                id: UUID(),
                sessionID: session.id,
                startedAt: startedAt,
                finishedAt: now(),
                outcome: .failed,
                startedServiceIDs: [],
                rolledBackServiceIDs: [],
                errors: reasons
            )
            await recordResult(result)
            await recordCompletion(result, relatedTo: startEvent.id)
            throw WorkspaceSessionRestoreError.blocked(reasons)
        }
        let unconfirmed = plan.confirmationIssues.filter { !options.confirmedIssueIDs.contains($0.id) }
        if !unconfirmed.isEmpty {
            let reasons = unconfirmed.map(\.summary)
            let result = SessionRestoreResult(
                id: UUID(),
                sessionID: session.id,
                startedAt: startedAt,
                finishedAt: now(),
                outcome: .failed,
                startedServiceIDs: [],
                rolledBackServiceIDs: [],
                errors: reasons
            )
            await recordResult(result)
            await recordCompletion(result, relatedTo: startEvent.id)
            throw WorkspaceSessionRestoreError.confirmationsRequired(reasons)
        }

        let servicesByID = Dictionary(uniqueKeysWithValues: services.map { ($0.id, $0) })
        var startedIDs: [UUID] = []
        var errors: [String] = []
        for layer in plan.orderedStartLayers {
            let profiles = layer.compactMap { servicesByID[$0] }
            let outcomes = await launch(profiles)
            startedIDs.append(contentsOf: outcomes.filter { $0.error == nil }.map(\.serviceID))
            errors.append(contentsOf: outcomes.compactMap(\.error))
            if !errors.isEmpty || Task.isCancelled { break }
        }

        var rolledBackIDs: [UUID] = []
        if !errors.isEmpty || Task.isCancelled {
            if Task.isCancelled { errors.append("Session restoration was cancelled.") }
            if options.rollbackStartedServicesOnFailure {
                let rollback = await rollback(
                    startedIDs: startedIDs,
                    layers: plan.orderedStartLayers,
                    servicesByID: servicesByID
                )
                rolledBackIDs = rollback.successes
                errors.append(contentsOf: rollback.errors)
                if !startedIDs.isEmpty {
                    await recordRollback(
                        sessionID: session.id,
                        relatedTo: startEvent.id,
                        attemptedCount: startedIDs.count,
                        successes: rollback.successes,
                        errors: rollback.errors,
                        timestamp: now()
                    )
                }
            }
            let result = SessionRestoreResult(
                id: UUID(),
                sessionID: session.id,
                startedAt: startedAt,
                finishedAt: now(),
                outcome: Task.isCancelled ? .cancelled : .failed,
                startedServiceIDs: startedIDs,
                rolledBackServiceIDs: rolledBackIDs,
                errors: errors
            )
            await recordResult(result)
            await recordCompletion(result, relatedTo: startEvent.id)
            return SessionRestoreExecution(plan: plan, result: result, stoppedServiceIDs: [])
        }

        let stopIDs = Set(plan.actions.filter { $0.kind == .stop }.map(\.serviceID))
        var stoppedIDs: [UUID] = []
        var stopFailureOccurred = false
        if options.applyExpectedStoppedState, !stopIDs.isEmpty {
            let stopOrder = orderedStopIDs(allServices: services, selectedIDs: stopIDs)
            for serviceID in stopOrder {
                guard let profile = servicesByID[serviceID] else { continue }
                do {
                    try await launcher.stop(profileID: serviceID, timeoutSeconds: profile.shutdownTimeoutSeconds)
                    stoppedIDs.append(serviceID)
                } catch {
                    stopFailureOccurred = true
                    errors.append("\(profile.name) could not stop: \(error.localizedDescription)")
                }
            }
        } else if !stopIDs.isEmpty {
            errors.append("\(stopIDs.count) service(s) expected to be stopped were left running by restore options.")
        }

        if stopFailureOccurred, options.rollbackStartedServicesOnFailure {
            let rollback = await rollback(
                startedIDs: startedIDs,
                layers: plan.orderedStartLayers,
                servicesByID: servicesByID
            )
            rolledBackIDs = rollback.successes
            errors.append(contentsOf: rollback.errors)
            if !startedIDs.isEmpty {
                await recordRollback(
                    sessionID: session.id,
                    relatedTo: startEvent.id,
                    attemptedCount: startedIDs.count,
                    successes: rollback.successes,
                    errors: rollback.errors,
                    timestamp: now()
                )
            }
        }
        let outcome: SessionRestoreOutcome = errors.isEmpty ? .succeeded : .partiallySucceeded
        let result = SessionRestoreResult(
            id: UUID(),
            sessionID: session.id,
            startedAt: startedAt,
            finishedAt: now(),
            outcome: outcome,
            startedServiceIDs: startedIDs,
            rolledBackServiceIDs: rolledBackIDs,
            errors: errors
        )
        await recordResult(result)
        await recordCompletion(result, relatedTo: startEvent.id)
        return SessionRestoreExecution(plan: plan, result: result, stoppedServiceIDs: stoppedIDs)
    }

    private func preflightIssues(
        for service: ManagedServiceConfiguration,
        listeners: [ObservedListener],
        servicesByID: [UUID: ManagedServiceConfiguration]
    ) async -> [SessionRestoreIssue] {
        var issues: [SessionRestoreIssue] = []
        var isDirectory: ObjCBool = false
        if !fileManager.fileExists(atPath: service.workingDirectory, isDirectory: &isDirectory) || !isDirectory.boolValue {
            issues.append(issue(
                kind: .missingWorkingDirectory,
                severity: .blocking,
                serviceID: service.id,
                discriminator: service.workingDirectory,
                summary: "\(service.name) has a missing working directory.",
                recovery: "Restore the directory or edit and revalidate the service."
            ))
        }
        if !hasExecutable(for: service) {
            issues.append(issue(
                kind: .missingExecutable,
                severity: .blocking,
                serviceID: service.id,
                discriminator: service.command,
                summary: "\(service.name) has no resolvable executable.",
                recovery: "Install the executable or edit and revalidate the service."
            ))
        }
        for (name, reference) in service.secretReferences.sorted(by: { $0.key < $1.key }) {
            let exists = (try? await secrets.value(for: reference)) != nil
            if !exists {
                issues.append(issue(
                    kind: .missingSecret,
                    severity: .blocking,
                    serviceID: service.id,
                    discriminator: name,
                    summary: "\(service.name) is missing the Keychain value for \(name).",
                    recovery: "Open Managed Services and provide the missing Keychain value."
                ))
            }
        }
        let validation: ManagedServiceValidationResult?
        if let trustStore {
            validation = try? await trustStore.latestValidation(for: service.id)
        } else {
            validation = nil
        }
        let trust = RestartTrustEvaluator.summary(for: service, validation: validation)
        if trust.state != .verifiedRestartable {
            issues.append(issue(
                kind: .unverifiedDefinition,
                severity: .blocking,
                serviceID: service.id,
                discriminator: trust.state.rawValue,
                summary: "\(service.name) is not verified restartable for its current definition.",
                recovery: trust.reasons.joined(separator: " ")
            ))
        }
        for expected in service.expectedPorts {
            guard let conflict = listeners.first(where: {
                $0.protocolKind == expected.protocolKind
                    && $0.port == expected.port
                    && $0.process.managedServiceID != service.id
            }) else { continue }
            issues.append(issue(
                kind: .occupiedPort,
                severity: .blocking,
                serviceID: service.id,
                discriminator: "\(expected.protocolKind.rawValue):\(expected.port)",
                summary: "Port \(expected.port) for \(service.name) is occupied by \(conflict.process.name).",
                recovery: "Inspect and explicitly resolve the current owner before restoring."
            ))
            if let ownerID = conflict.process.managedServiceID,
               let owner = servicesByID[ownerID],
               owner.projectID != service.projectID {
                issues.append(issue(
                    kind: .conflictingProject,
                    severity: .warning,
                    serviceID: service.id,
                    discriminator: ownerID.uuidString,
                    summary: "\(service.name) conflicts with \(owner.name) from another project.",
                    recovery: "Review both projects' expected ports before changing either definition."
                ))
            }
        }
        return issues
    }

    private func hasExecutable(for service: ManagedServiceConfiguration) -> Bool {
        switch service.shell {
        case .direct:
            let environment = ProcessInfo.processInfo.environment.merging(service.environment) { _, profile in profile }
            return resolver.resolve(
                service.command,
                environment: environment,
                workingDirectory: service.workingDirectory
            ) != nil
        case let .loginShell(path), let .custom(path):
            return fileManager.isExecutableFile(atPath: path)
        }
    }

    private func launch(_ profiles: [ManagedServiceConfiguration]) async -> [OperationOutcome] {
        await withTaskGroup(of: OperationOutcome.self, returning: [OperationOutcome].self) { group in
            for profile in profiles {
                group.addTask { [launcher] in
                    do {
                        try await launcher.launch(profile)
                        return OperationOutcome(serviceID: profile.id, error: nil)
                    } catch {
                        return OperationOutcome(
                            serviceID: profile.id,
                            error: "\(profile.name) could not become ready: \(error.localizedDescription)"
                        )
                    }
                }
            }
            var outcomes: [OperationOutcome] = []
            for await outcome in group { outcomes.append(outcome) }
            return outcomes.sorted { $0.serviceID.uuidString < $1.serviceID.uuidString }
        }
    }

    private func rollback(
        startedIDs: [UUID],
        layers: [[UUID]],
        servicesByID: [UUID: ManagedServiceConfiguration]
    ) async -> (successes: [UUID], errors: [String]) {
        let started = Set(startedIDs)
        var successes: [UUID] = []
        var errors: [String] = []
        for layer in layers.reversed() {
            let profiles = layer.filter(started.contains).compactMap { servicesByID[$0] }
            let outcomes = await withTaskGroup(of: OperationOutcome.self, returning: [OperationOutcome].self) { group in
                for profile in profiles {
                    group.addTask { [launcher] in
                        do {
                            try await launcher.stop(
                                profileID: profile.id,
                                timeoutSeconds: profile.shutdownTimeoutSeconds
                            )
                            return OperationOutcome(serviceID: profile.id, error: nil)
                        } catch {
                            return OperationOutcome(
                                serviceID: profile.id,
                                error: "Rollback could not stop \(profile.name): \(error.localizedDescription)"
                            )
                        }
                    }
                }
                var values: [OperationOutcome] = []
                for await value in group { values.append(value) }
                return values
            }
            successes.append(contentsOf: outcomes.filter { $0.error == nil }.map(\.serviceID))
            errors.append(contentsOf: outcomes.compactMap(\.error))
        }
        return (successes, errors)
    }

    private func orderedStopIDs(
        allServices: [ManagedServiceConfiguration],
        selectedIDs: Set<UUID>
    ) -> [UUID] {
        guard let layers = try? DependencyPlanner.orderedLayers(for: allServices) else {
            return selectedIDs.sorted { $0.uuidString < $1.uuidString }
        }
        return layers.reversed().flatMap { $0.map(\.id).filter(selectedIDs.contains) }
    }

    private func actionReason(kind: SessionRestoreActionKind) -> String {
        switch kind {
        case .start: "The session expects this service running and it is currently stopped."
        case .alreadyRunning: "The session and current runtime both expect this service running."
        case .stop: "The session expects this service stopped, but it is currently running."
        case .alreadyStopped: "The session and current runtime both expect this service stopped."
        case .missing: "The captured service definition is unavailable."
        }
    }

    private func issue(
        kind: SessionRestoreIssueKind,
        severity: SessionRestoreIssueSeverity,
        serviceID: UUID?,
        discriminator: String,
        summary: String,
        recovery: String
    ) -> SessionRestoreIssue {
        let digest = ProcessFingerprint.digest(commandLine: discriminator)
        return SessionRestoreIssue(
            id: "\(kind.rawValue):\(serviceID?.uuidString ?? "session"):\(digest)",
            kind: kind,
            severity: severity,
            serviceID: serviceID,
            summary: summary,
            recoverySuggestion: recovery
        )
    }

    private func deduplicated(_ issues: [SessionRestoreIssue]) -> [SessionRestoreIssue] {
        var ids = Set<String>()
        return issues.filter { ids.insert($0.id).inserted }.sorted { lhs, rhs in
            if lhs.severity != rhs.severity {
                let order: [SessionRestoreIssueSeverity: Int] = [.blocking: 0, .confirmationRequired: 1, .warning: 2]
                return order[lhs.severity, default: 3] < order[rhs.severity, default: 3]
            }
            return lhs.summary < rhs.summary
        }
    }

    private func recordResult(_ result: SessionRestoreResult) async {
        do {
            try await recorder?.record(result)
        } catch {
            DevBerthLogger.persistence.error(
                "Session restore finished, but its result could not be saved: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func recordLifecycle(_ event: LifecycleEvent) async {
        do {
            try await lifecycleRecorder?.record(event)
        } catch {
            DevBerthLogger.persistence.error(
                "Session lifecycle evidence could not be saved: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func recordCompletion(_ result: SessionRestoreResult, relatedTo eventID: UUID) async {
        let succeeded = result.outcome == .succeeded || result.outcome == .dryRun
        let lifecycleOutcome: LifecycleEventOutcome = result.outcome == .cancelled
            ? .cancelled
            : (succeeded ? .succeeded : .failed)
        await recordLifecycle(LifecycleEvent(
            timestamp: result.finishedAt,
            sessionID: result.sessionID,
            category: .sessionRestore,
            outcome: lifecycleOutcome,
            severity: succeeded ? .notice : .error,
            source: .session,
            trigger: .userAction,
            summary: "Session restore finished with result \(result.outcome.rawValue).",
            details: [
                "startedCount": String(result.startedServiceIDs.count),
                "rolledBackCount": String(result.rolledBackServiceIDs.count),
                "errorCount": String(result.errors.count)
            ],
            durationSeconds: result.finishedAt.timeIntervalSince(result.startedAt),
            relatedEventIDs: [eventID]
        ))
    }

    private func recordRollback(
        sessionID: UUID,
        relatedTo eventID: UUID,
        attemptedCount: Int,
        successes: [UUID],
        errors: [String],
        timestamp: Date
    ) async {
        await recordLifecycle(LifecycleEvent(
            timestamp: timestamp,
            sessionID: sessionID,
            category: .sessionRollback,
            outcome: errors.isEmpty ? .succeeded : .failed,
            severity: errors.isEmpty ? .warning : .error,
            source: .session,
            trigger: .dependency,
            summary: errors.isEmpty
                ? "Rolled back managed services started by this session restore."
                : "Session restore rollback was incomplete.",
            details: [
                "attemptedCount": String(attemptedCount),
                "rolledBackCount": String(successes.count),
                "errorCount": String(errors.count)
            ],
            relatedEventIDs: [eventID]
        ))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
