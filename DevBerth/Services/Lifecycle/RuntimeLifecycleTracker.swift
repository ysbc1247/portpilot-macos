import Foundation

actor RuntimeLifecycleTracker: RuntimeLifecycleObserving, DependencyReadinessProviding {
    private let recorder: (any RuntimeLifecycleRecording)?
    private let clock: @Sendable () -> Date
    private var statuses: [UUID: ManagedServiceRuntimeStatus] = [:]
    private var runtimes: [UUID: RuntimeInstance] = [:]
    private var recentEvents: [UUID: [LifecycleEvent]] = [:]
    private var incidents: [UUID: RuntimeIncidentSummary] = [:]
    private var continuations: [UUID: AsyncStream<RuntimeLifecycleSnapshot>.Continuation] = [:]

    init(
        recorder: (any RuntimeLifecycleRecording)? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.recorder = recorder
        self.clock = clock
    }

    func snapshots() -> AsyncStream<RuntimeLifecycleSnapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuations[id] = continuation
            continuation.yield(snapshot())
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    func isReady(managedServiceID: UUID) -> Bool {
        statuses[managedServiceID]?.isReady == true
    }

    func transition(_ updates: [RuntimeLifecycleUpdate]) async {
        guard !updates.isEmpty else { return }
        var listenerEvents: [LifecycleEvent] = []
        for update in updates {
            if case let .listenerObserved(listener, change) = update {
                let event = listenerEvent(listener, change: change, at: clock())
                appendLocally(event)
                listenerEvents.append(event)
            } else {
                await transition(update)
            }
        }
        guard !listenerEvents.isEmpty else { return }
        do { try await recorder?.record(listenerEvents) }
        catch { DevBerthLogger.persistence.error("Lifecycle event batch persistence failed: \(error.localizedDescription, privacy: .public)") }
        publish()
    }

    func transition(_ update: RuntimeLifecycleUpdate) async {
        let now = clock()
        switch update {
        case let .listenerObserved(listener, change):
            await append(listenerEvent(listener, change: change, at: now))

        case let .launchRequested(profile, trigger):
            setStatus(
                serviceID: profile.id,
                runtimeID: nil,
                lifecycle: .starting,
                health: .unknown,
                processRunning: false,
                message: "Launch requested.",
                at: now
            )
            await append(.init(
                timestamp: now,
                managedServiceID: profile.id,
                projectID: profile.projectID,
                category: .requested,
                outcome: .pending,
                source: trigger == .userAction ? .user : .system,
                trigger: trigger,
                summary: "Launch requested for \(profile.name)."
            ))

        case let .processSpawned(handle, profile):
            let runtime = RuntimeInstance(
                id: handle.id,
                managedServiceID: profile.id,
                processFingerprint: handle.leaderFingerprint,
                startedAt: handle.launchedAt,
                lifecycleState: .starting,
                healthState: .waitingForReadiness
            )
            runtimes[profile.id] = runtime
            setStatus(
                serviceID: profile.id,
                runtimeID: handle.id,
                lifecycle: .starting,
                health: .waitingForReadiness,
                processRunning: true,
                message: "Process spawned; waiting for readiness.",
                at: now
            )
            await persist(runtime)
            await append(.init(
                timestamp: now,
                runtimeID: handle.id,
                managedServiceID: profile.id,
                projectID: profile.projectID,
                category: .processSpawned,
                outcome: .succeeded,
                severity: .notice,
                source: .launcher,
                trigger: .automatic,
                summary: "Managed process spawned.",
                details: ["processGroupID": String(handle.processGroupID)],
                processFingerprint: handle.leaderFingerprint
            ))

        case let .waitingForPorts(serviceID, ports):
            await updateRuntime(serviceID: serviceID, lifecycle: .waitingForPort, health: .waitingForReadiness)
            setStatusFromExisting(
                serviceID: serviceID,
                lifecycle: .waitingForPort,
                health: .waitingForReadiness,
                processRunning: true,
                message: "Waiting for required port(s): \(ports.map(String.init).joined(separator: ", ")).",
                at: now
            )
            await appendForService(
                serviceID,
                category: .starting,
                outcome: .pending,
                source: .readiness,
                summary: "Waiting for required listeners.",
                details: ["ports": ports.map(String.init).joined(separator: ",")],
                at: now
            )

        case let .listenersReady(serviceID, listenerIDs):
            if var runtime = runtimes[serviceID] {
                runtime.listenerIDs = listenerIDs
                runtime.lifecycleState = .waitingForReadiness
                runtime.healthState = .ready
                runtimes[serviceID] = runtime
                await persist(runtime)
            }
            setStatusFromExisting(
                serviceID: serviceID,
                lifecycle: .waitingForReadiness,
                health: .ready,
                processRunning: true,
                listeners: listenerIDs,
                message: "Required listeners are open.",
                at: now
            )
            await appendForService(
                serviceID,
                category: .ready,
                outcome: .succeeded,
                source: .readiness,
                summary: "Required listeners became ready.",
                at: now
            )

        case let .serviceReady(serviceID, description):
            await updateRuntime(serviceID: serviceID, lifecycle: .running, health: .ready)
            setStatusFromExisting(
                serviceID: serviceID,
                lifecycle: .running,
                health: .ready,
                processRunning: true,
                message: description,
                at: now
            )
            await appendForService(
                serviceID,
                category: .ready,
                outcome: .succeeded,
                source: .readiness,
                summary: description,
                at: now
            )

        case let .waitingForHealth(serviceID, description):
            await updateRuntime(serviceID: serviceID, lifecycle: .waitingForReadiness, health: .checking)
            setStatusFromExisting(
                serviceID: serviceID,
                lifecycle: .waitingForReadiness,
                health: .checking,
                processRunning: true,
                message: description,
                at: now
            )

        case let .healthPassed(serviceID, description):
            await updateRuntime(serviceID: serviceID, lifecycle: .running, health: .healthy)
            setStatusFromExisting(
                serviceID: serviceID,
                lifecycle: .running,
                health: .healthy,
                processRunning: true,
                message: description,
                at: now
            )
            await appendForService(
                serviceID,
                category: .healthChanged,
                outcome: .succeeded,
                source: .health,
                summary: description,
                at: now
            )

        case let .healthDegraded(serviceID, reason):
            await updateRuntime(serviceID: serviceID, lifecycle: .running, health: .degraded)
            setStatusFromExisting(
                serviceID: serviceID,
                lifecycle: .running,
                health: .degraded,
                processRunning: true,
                message: reason,
                at: now
            )
            let event = await appendForService(
                serviceID,
                category: .healthChanged,
                outcome: .failed,
                severity: .warning,
                source: .health,
                summary: reason,
                at: now
            )
            await createIncident(serviceID: serviceID, terminalEvent: event, title: "Service became degraded.")

        case let .launchFailed(profile, reason):
            await updateRuntime(serviceID: profile.id, lifecycle: .failed, health: .unhealthy)
            setStatusFromExisting(
                serviceID: profile.id,
                lifecycle: .failed,
                health: .unhealthy,
                processRunning: false,
                message: reason,
                at: now
            )
            let event = await append(.init(
                timestamp: now,
                runtimeID: runtimes[profile.id]?.id,
                managedServiceID: profile.id,
                projectID: profile.projectID,
                category: .failed,
                outcome: .failed,
                severity: .error,
                source: .launcher,
                trigger: .automatic,
                summary: reason
            ))
            await createIncident(serviceID: profile.id, terminalEvent: event, title: "Service failed to start.")

        case let .stopping(serviceID, runtimeID, reason):
            await updateRuntime(serviceID: serviceID, lifecycle: .stopping, health: nil)
            setStatusFromExisting(
                serviceID: serviceID,
                runtimeID: runtimeID,
                lifecycle: .stopping,
                health: statuses[serviceID]?.healthState ?? .unknown,
                processRunning: true,
                message: reason,
                at: now
            )
            await appendForService(
                serviceID,
                category: .stopping,
                outcome: .pending,
                source: .launcher,
                summary: reason,
                at: now
            )

        case let .stopped(serviceID, runtimeID, reason):
            if var runtime = runtimes[serviceID] {
                runtime.lifecycleState = .exited
                runtime.healthState = .stopped
                runtime.exitResult = RuntimeExitResult(
                    exitedAt: now,
                    exitCode: nil,
                    signal: nil,
                    reason: reason
                )
                runtimes[serviceID] = runtime
                await persist(runtime)
            }
            setStatus(
                serviceID: serviceID,
                runtimeID: runtimeID,
                lifecycle: .stopped,
                health: .stopped,
                processRunning: false,
                message: reason,
                at: now
            )
            await appendForService(
                serviceID,
                category: .exited,
                outcome: .succeeded,
                source: .launcher,
                summary: reason,
                at: now
            )

        case let .exited(profile, handle, result, intentional):
            if var runtime = runtimes[profile.id] {
                runtime.lifecycleState = intentional ? .exited : (result.succeeded ? .exited : .failed)
                runtime.healthState = .stopped
                runtime.exitResult = result
                runtimes[profile.id] = runtime
                await persist(runtime)
            }
            let message = exitMessage(result: result, intentional: intentional)
            setStatus(
                serviceID: profile.id,
                runtimeID: handle.id,
                lifecycle: intentional ? .stopped : (result.succeeded ? .exited : .failed),
                health: .stopped,
                processRunning: false,
                message: message,
                at: now
            )
            let event = await append(.init(
                timestamp: now,
                runtimeID: handle.id,
                managedServiceID: profile.id,
                projectID: profile.projectID,
                category: .exited,
                outcome: intentional || result.succeeded ? .succeeded : .failed,
                severity: intentional || result.succeeded ? .notice : .error,
                source: .launcher,
                trigger: intentional ? .userAction : .automatic,
                summary: message,
                details: exitDetails(result),
                processFingerprint: handle.leaderFingerprint
            ))
            if !intentional {
                await createIncident(serviceID: profile.id, terminalEvent: event, title: "Service exited unexpectedly.")
            }

        case let .restartScheduled(serviceID, attempt, delaySeconds):
            await appendForService(
                serviceID,
                category: .requested,
                outcome: .pending,
                severity: .warning,
                source: .restartPolicy,
                summary: "Automatic restart attempt \(attempt) scheduled in \(delaySeconds.formatted()) seconds.",
                at: now
            )

        case let .restartFailed(serviceID, reason):
            let event = await appendForService(
                serviceID,
                category: .failed,
                outcome: .failed,
                severity: .error,
                source: .restartPolicy,
                summary: reason,
                at: now
            )
            await createIncident(serviceID: serviceID, terminalEvent: event, title: "Automatic restart failed.")
        }
        publish()
    }

    private func setStatus(
        serviceID: UUID,
        runtimeID: UUID?,
        lifecycle: RuntimeLifecycleState,
        health: RuntimeHealthState,
        processRunning: Bool,
        listeners: Set<String> = [],
        message: String,
        at date: Date
    ) {
        statuses[serviceID] = ManagedServiceRuntimeStatus(
            managedServiceID: serviceID,
            runtimeID: runtimeID,
            lifecycleState: lifecycle,
            healthState: health,
            processRunning: processRunning,
            openListenerIDs: listeners,
            statusMessage: message,
            changedAt: date
        )
    }

    private func setStatusFromExisting(
        serviceID: UUID,
        runtimeID: UUID? = nil,
        lifecycle: RuntimeLifecycleState,
        health: RuntimeHealthState,
        processRunning: Bool,
        listeners: Set<String>? = nil,
        message: String,
        at date: Date
    ) {
        setStatus(
            serviceID: serviceID,
            runtimeID: runtimeID ?? statuses[serviceID]?.runtimeID,
            lifecycle: lifecycle,
            health: health,
            processRunning: processRunning,
            listeners: listeners ?? statuses[serviceID]?.openListenerIDs ?? [],
            message: message,
            at: date
        )
    }

    private func updateRuntime(
        serviceID: UUID,
        lifecycle: RuntimeLifecycleState,
        health: RuntimeHealthState?
    ) async {
        guard var runtime = runtimes[serviceID] else { return }
        runtime.lifecycleState = lifecycle
        if let health { runtime.healthState = health }
        runtimes[serviceID] = runtime
        await persist(runtime)
    }

    @discardableResult
    private func appendForService(
        _ serviceID: UUID,
        category: LifecycleEventCategory,
        outcome: LifecycleEventOutcome,
        severity: LifecycleEventSeverity = .info,
        source: LifecycleEventSource,
        summary: String,
        details: [String: String] = [:],
        at date: Date
    ) async -> LifecycleEvent {
        await append(.init(
            timestamp: date,
            runtimeID: runtimes[serviceID]?.id,
            managedServiceID: serviceID,
            category: category,
            outcome: outcome,
            severity: severity,
            source: source,
            trigger: source == .restartPolicy ? .automatic : .system,
            summary: summary,
            details: details
        ))
    }

    @discardableResult
    private func append(_ event: LifecycleEvent) async -> LifecycleEvent {
        appendLocally(event)
        do { try await recorder?.record(event) }
        catch { DevBerthLogger.persistence.error("Lifecycle event persistence failed: \(error.localizedDescription, privacy: .public)") }
        return event
    }

    private func appendLocally(_ event: LifecycleEvent) {
        if let serviceID = event.managedServiceID {
            var events = recentEvents[serviceID, default: []]
            events.append(event)
            recentEvents[serviceID] = Array(events.suffix(50))
            if var runtime = runtimes[serviceID] {
                runtime.lifecycleEventIDs.append(event.id)
                runtime.lifecycleEventIDs = Array(runtime.lifecycleEventIDs.suffix(100))
                runtimes[serviceID] = runtime
            }
        }
    }

    private func listenerEvent(
        _ listener: ObservedListener,
        change: ObservedListenerLifecycleChange,
        at date: Date
    ) -> LifecycleEvent {
        let action = switch change {
        case .discovered: "discovered"
        case .changed: "changed"
        case .released: "released"
        }
        return LifecycleEvent(
            timestamp: date,
            managedServiceID: listener.process.managedServiceID,
            projectID: nil,
            category: .listenerChanged,
            outcome: .observed,
            severity: .info,
            source: .monitor,
            trigger: .observation,
            summary: "Listener \(listener.protocolKind.rawValue) \(listener.address):\(listener.port) was \(action).",
            details: [
                "change": change.rawValue,
                "port": String(listener.port),
                "protocol": listener.protocolKind.rawValue,
                "processName": listener.process.name,
                "inferredProject": listener.process.project?.name ?? ""
            ],
            processFingerprint: listener.process.fingerprint,
            listenerID: listener.id
        )
    }

    private func persist(_ runtime: RuntimeInstance) async {
        do { try await recorder?.record(runtime) }
        catch { DevBerthLogger.persistence.error("Runtime persistence failed: \(error.localizedDescription, privacy: .public)") }
    }

    private func createIncident(
        serviceID: UUID,
        terminalEvent: LifecycleEvent,
        title: String
    ) async {
        let relevant = Array(recentEvents[serviceID, default: []].suffix(8))
        let incident = IncidentSummarizer.make(
            serviceID: serviceID,
            runtimeID: runtimes[serviceID]?.id,
            title: title,
            events: relevant,
            terminalEvent: terminalEvent,
            generatedAt: clock()
        )
        incidents[serviceID] = incident
        do { try await recorder?.record(incident) }
        catch { DevBerthLogger.persistence.error("Incident persistence failed: \(error.localizedDescription, privacy: .public)") }
    }

    private func publish() {
        let value = snapshot()
        continuations.values.forEach { $0.yield(value) }
    }

    private func snapshot() -> RuntimeLifecycleSnapshot {
        RuntimeLifecycleSnapshot(statuses: statuses, incidents: incidents)
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func exitMessage(result: RuntimeExitResult, intentional: Bool) -> String {
        if intentional { return "Managed service stopped intentionally." }
        if let signal = result.signal { return "Managed service exited after signal \(signal)." }
        if let code = result.exitCode { return "Managed service exited with status \(code)." }
        return "Managed service exited unexpectedly."
    }

    private func exitDetails(_ result: RuntimeExitResult) -> [String: String] {
        var details: [String: String] = [:]
        if let code = result.exitCode { details["exitCode"] = String(code) }
        if let signal = result.signal { details["signal"] = String(signal) }
        if let reason = result.reason { details["reason"] = reason }
        return details
    }
}

enum IncidentSummarizer {
    static func make(
        serviceID: UUID,
        runtimeID: UUID?,
        title: String,
        events: [LifecycleEvent],
        terminalEvent: LifecycleEvent,
        generatedAt: Date
    ) -> RuntimeIncidentSummary {
        let ordered = (events + [terminalEvent])
            .uniqued(by: \.id)
            .sorted { $0.timestamp < $1.timestamp }
        let cause = terminalEvent.summary
        let suggestedAction: String
        switch terminalEvent.source {
        case .readiness:
            suggestedAction = "Inspect expected listeners, dependency readiness, and the latest redacted service logs."
        case .health:
            suggestedAction = "Inspect the failing health criterion and verify its dependency before retrying."
        case .restartPolicy:
            suggestedAction = "Review the crash cause and restart policy before retrying manually."
        default:
            suggestedAction = "Inspect the ordered lifecycle evidence and redacted logs before retrying."
        }
        return RuntimeIncidentSummary(
            id: UUID(),
            managedServiceID: serviceID,
            runtimeID: runtimeID,
            title: title,
            cause: cause,
            suggestedAction: suggestedAction,
            steps: ordered.map {
                IncidentSummaryStep(timestamp: $0.timestamp, explanation: $0.summary, eventID: $0.id)
            },
            relatedEventIDs: ordered.map(\.id),
            generatedAt: generatedAt
        )
    }
}

private extension Array {
    func uniqued<Key: Hashable>(by keyPath: KeyPath<Element, Key>) -> [Element] {
        var seen = Set<Key>()
        return filter { seen.insert($0[keyPath: keyPath]).inserted }
    }
}

actor ManagedProcessExitHub: ManagedProcessExitObserving {
    private var continuations: [UUID: AsyncStream<ManagedProcessExitNotice>.Continuation] = [:]

    func notices() -> AsyncStream<ManagedProcessExitNotice> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(20)) { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.remove(id) }
            }
        }
    }

    func managedProcessDidExit(_ notice: ManagedProcessExitNotice) {
        continuations.values.forEach { $0.yield(notice) }
    }

    private func remove(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
