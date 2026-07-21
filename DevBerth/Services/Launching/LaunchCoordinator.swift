import Foundation

actor LaunchCoordinator: LaunchProfileServing {
    private let discoverer: any PortDiscovering
    private let processLauncher: any ManagedProcessLaunching
    private let healthChecker: any HealthChecking
    private let lifecycle: any RuntimeLifecycleObserving
    private let serviceCheckRunner: (any ServiceCheckRunning)?
    private var healthMonitorTasks: [UUID: Task<Void, Never>] = [:]
    private var latestHealthSuccess: [UUID: Bool] = [:]

    init(
        discoverer: any PortDiscovering,
        processLauncher: any ManagedProcessLaunching,
        healthChecker: any HealthChecking,
        lifecycle: (any RuntimeLifecycleObserving)? = nil,
        serviceCheckRunner: (any ServiceCheckRunning)? = nil
    ) {
        self.discoverer = discoverer
        self.processLauncher = processLauncher
        self.healthChecker = healthChecker
        self.lifecycle = lifecycle ?? RuntimeLifecycleTracker()
        self.serviceCheckRunner = serviceCheckRunner
    }

    func launch(_ profile: ManagedServiceConfiguration) async throws {
        await lifecycle.transition(.launchRequested(profile, trigger: .automatic))
        let validationErrors = ManagedServiceValidator.validate(profile).filter { $0.severity == .error }
        guard validationErrors.isEmpty else {
            await lifecycle.transition(.launchFailed(
                profile,
                reason: validationErrors.map(\.message).joined(separator: " ")
            ))
            throw DevBerthError.launchValidation(validationErrors.map(\.message).joined(separator: " "))
        }
        do {
            let occupied = try await discoverer.discover()
            if let conflict = PortConflictDetector.conflicts(for: profile, listeners: occupied).first {
                throw DevBerthError.portConflict(conflict.expectedPort.port)
            }
            try await processLauncher.launch(profile)
            let requiredPorts = profile.expectedPorts.filter(\.required).map(\.port)
            if !requiredPorts.isEmpty {
                await lifecycle.transition(.waitingForPorts(
                    serviceID: profile.id,
                    ports: requiredPorts
                ))
            }
            let listenerIDs = try await waitForExpectedPorts(profile)
            await lifecycle.transition(.listenersReady(
                serviceID: profile.id,
                listenerIDs: listenerIDs
            ))
            if let healthCheck = profile.healthCheck {
                await lifecycle.transition(.waitingForHealth(
                    serviceID: profile.id,
                    description: "Waiting for HTTP health status \(healthCheck.expectedStatus)."
                ))
                try await healthChecker.waitUntilHealthy(
                    configuration: healthCheck,
                    timeoutSeconds: profile.startupTimeoutSeconds
                )
                await lifecycle.transition(.healthPassed(
                    serviceID: profile.id,
                    description: "HTTP health check passed with the reviewed status."
                ))
            }
            if !profile.serviceChecks.isEmpty {
                guard let serviceCheckRunner else {
                    throw DevBerthError.launchValidation("Additional service checks are configured but no check runner is available.")
                }
                await lifecycle.transition(.waitingForHealth(
                    serviceID: profile.id,
                    description: "Running \(profile.serviceChecks.count) additional readiness and health check(s)."
                ))
                _ = try await serviceCheckRunner.run(profile.serviceChecks)
                await lifecycle.transition(.healthPassed(
                    serviceID: profile.id,
                    description: "All configured readiness and health checks passed."
                ))
            }
            if profile.healthCheck == nil, profile.serviceChecks.isEmpty {
                await lifecycle.transition(.serviceReady(
                    serviceID: profile.id,
                    description: "Process and required listeners are ready; no separate health check is configured."
                ))
            } else {
                startHealthMonitoring(profile: profile)
            }
        } catch {
            healthMonitorTasks.removeValue(forKey: profile.id)?.cancel()
            latestHealthSuccess.removeValue(forKey: profile.id)
            try? await processLauncher.stop(profileID: profile.id, timeoutSeconds: profile.shutdownTimeoutSeconds)
            await lifecycle.transition(.launchFailed(profile, reason: error.localizedDescription))
            throw error
        }
    }

    func stop(profileID: UUID, timeoutSeconds: Double) async throws {
        cancelHealthMonitoring(profileID: profileID)
        try await processLauncher.stop(profileID: profileID, timeoutSeconds: timeoutSeconds)
    }

    func runtimeDidExit(profileID: UUID) async {
        cancelHealthMonitoring(profileID: profileID)
    }

    private func cancelHealthMonitoring(profileID: UUID) {
        healthMonitorTasks.removeValue(forKey: profileID)?.cancel()
        latestHealthSuccess.removeValue(forKey: profileID)
    }

    private func startHealthMonitoring(profile: ManagedServiceConfiguration) {
        healthMonitorTasks.removeValue(forKey: profile.id)?.cancel()
        latestHealthSuccess[profile.id] = true
        let intervals = [profile.healthCheck?.intervalSeconds]
            .compactMap { $0 } + profile.serviceChecks.map(\.intervalSeconds)
        let interval = max(0.25, intervals.min() ?? 2)
        healthMonitorTasks[profile.id] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { return }
                await self.sampleHealth(profile: profile)
            }
        }
    }

    private func sampleHealth(profile: ManagedServiceConfiguration) async {
        do {
            if let configuration = profile.healthCheck {
                try await healthChecker.waitUntilHealthy(
                    configuration: configuration,
                    timeoutSeconds: max(0.5, configuration.intervalSeconds)
                )
            }
            if !profile.serviceChecks.isEmpty {
                guard let serviceCheckRunner else {
                    throw DevBerthError.launchValidation(
                        "Additional service checks are configured but no check runner is available."
                    )
                }
                _ = try await serviceCheckRunner.run(profile.serviceChecks)
            }
            if latestHealthSuccess[profile.id] != true {
                await lifecycle.transition(.healthPassed(
                    serviceID: profile.id,
                    description: "Configured health checks recovered."
                ))
            }
            latestHealthSuccess[profile.id] = true
        } catch {
            if latestHealthSuccess[profile.id] != false {
                await lifecycle.transition(.healthDegraded(
                    serviceID: profile.id,
                    reason: "A configured health check failed after startup: \(error.localizedDescription)"
                ))
            }
            latestHealthSuccess[profile.id] = false
        }
    }

    private func waitForExpectedPorts(_ profile: ManagedServiceConfiguration) async throws -> Set<String> {
        let required = profile.expectedPorts.filter(\.required)
        guard !required.isEmpty else { return [] }
        let deadline = Date().addingTimeInterval(profile.startupTimeoutSeconds)
        while Date() < deadline {
            let listeners = try await discoverer.discover()
            let matches = required.compactMap { expected in
                listeners.first { $0.port == expected.port && $0.protocolKind == expected.protocolKind }
            }
            if matches.count == required.count { return Set(matches.map(\.id)) }
            try await Task.sleep(for: .milliseconds(250))
        }
        let ports = required.map { String($0.port) }.joined(separator: ", ")
        throw DevBerthError.launchValidation("Expected port(s) \(ports) did not become active before the startup timeout.")
    }
}
