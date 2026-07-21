import Foundation

struct HealthMonitoringPolicy: Equatable, Sendable {
    let minimumIntervalSeconds: Double
    let stableIntervalSeconds: Double
    let maximumBackoffSeconds: Double
    let jitterFraction: Double

    static let production = HealthMonitoringPolicy(
        minimumIntervalSeconds: 0.25,
        stableIntervalSeconds: 15,
        maximumBackoffSeconds: 60,
        jitterFraction: 0.1
    )

    func baseInterval(for profile: ManagedServiceConfiguration) -> Double {
        let intervals = [profile.healthCheck?.intervalSeconds]
            .compactMap { $0 } + profile.serviceChecks.map(\.intervalSeconds)
        return max(minimumIntervalSeconds, intervals.min() ?? 2)
    }

    func jittered(_ seconds: Double) -> Double {
        guard jitterFraction > 0 else { return seconds }
        return seconds * Double.random(in: (1 - jitterFraction)...(1 + jitterFraction))
    }
}

struct AdaptiveHealthSchedule: Equatable, Sendable {
    private let baseIntervalSeconds: Double
    private let stableIntervalSeconds: Double
    private let maximumBackoffSeconds: Double
    private(set) var consecutiveSuccesses = 0
    private(set) var consecutiveFailures = 0

    init(baseIntervalSeconds: Double, policy: HealthMonitoringPolicy) {
        self.baseIntervalSeconds = baseIntervalSeconds
        stableIntervalSeconds = max(policy.stableIntervalSeconds, baseIntervalSeconds)
        maximumBackoffSeconds = max(policy.maximumBackoffSeconds, baseIntervalSeconds)
    }

    var intervalSeconds: Double {
        if consecutiveFailures > 0 {
            return min(
                maximumBackoffSeconds,
                baseIntervalSeconds * pow(2, Double(min(8, consecutiveFailures - 1)))
            )
        }
        return consecutiveSuccesses >= 3 ? stableIntervalSeconds : baseIntervalSeconds
    }

    mutating func record(_ succeeded: Bool?) {
        guard let succeeded else { return }
        if succeeded {
            consecutiveFailures = 0
            consecutiveSuccesses += 1
        } else {
            consecutiveSuccesses = 0
            consecutiveFailures += 1
        }
    }
}

actor HealthCheckConcurrencyGate {
    private let limit: Int
    private var active = 0

    init(limit: Int = 4) {
        self.limit = max(1, limit)
    }

    func tryAcquire() -> Bool {
        guard active < limit else { return false }
        active += 1
        return true
    }

    func release() {
        active = max(0, active - 1)
    }
}

actor LaunchCoordinator: LaunchProfileServing {
    private let discoverer: any PortDiscovering
    private let processLauncher: any ManagedProcessLaunching
    private let healthChecker: any HealthChecking
    private let lifecycle: any RuntimeLifecycleObserving
    private let serviceCheckRunner: (any ServiceCheckRunning)?
    private let healthMonitoringPolicy: HealthMonitoringPolicy
    private let healthCheckGate: HealthCheckConcurrencyGate
    private var healthMonitorTasks: [UUID: Task<Void, Never>] = [:]
    private var healthMonitorGenerations: [UUID: UUID] = [:]
    private var latestHealthSuccess: [UUID: Bool] = [:]
    private var healthMonitoringSuspended = false

    init(
        discoverer: any PortDiscovering,
        processLauncher: any ManagedProcessLaunching,
        healthChecker: any HealthChecking,
        lifecycle: (any RuntimeLifecycleObserving)? = nil,
        serviceCheckRunner: (any ServiceCheckRunning)? = nil,
        healthMonitoringPolicy: HealthMonitoringPolicy = .production,
        maximumConcurrentHealthChecks: Int = 4
    ) {
        self.discoverer = discoverer
        self.processLauncher = processLauncher
        self.healthChecker = healthChecker
        self.lifecycle = lifecycle ?? RuntimeLifecycleTracker()
        self.serviceCheckRunner = serviceCheckRunner
        self.healthMonitoringPolicy = healthMonitoringPolicy
        healthCheckGate = HealthCheckConcurrencyGate(limit: maximumConcurrentHealthChecks)
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
            cancelHealthMonitoring(profileID: profile.id)
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

    func retire(profileID: UUID) async {
        cancelHealthMonitoring(profileID: profileID)
    }

    func setSystemSuspended(_ suspended: Bool) async {
        healthMonitoringSuspended = suspended
    }

    private func cancelHealthMonitoring(profileID: UUID) {
        healthMonitorTasks.removeValue(forKey: profileID)?.cancel()
        healthMonitorGenerations.removeValue(forKey: profileID)
        latestHealthSuccess.removeValue(forKey: profileID)
    }

    private func startHealthMonitoring(profile: ManagedServiceConfiguration) {
        healthMonitorTasks.removeValue(forKey: profile.id)?.cancel()
        let generation = UUID()
        healthMonitorGenerations[profile.id] = generation
        latestHealthSuccess[profile.id] = true
        let policy = healthMonitoringPolicy
        var schedule = AdaptiveHealthSchedule(
            baseIntervalSeconds: policy.baseInterval(for: profile),
            policy: policy
        )
        healthMonitorTasks[profile.id] = Task { [weak self, healthCheckGate] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(policy.jittered(schedule.intervalSeconds)))
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                let result = await self.sampleHealth(
                    profile: profile,
                    generation: generation,
                    gate: healthCheckGate
                )
                schedule.record(result)
            }
        }
    }

    private func sampleHealth(
        profile: ManagedServiceConfiguration,
        generation: UUID,
        gate: HealthCheckConcurrencyGate
    ) async -> Bool? {
        guard !healthMonitoringSuspended,
              healthMonitorGenerations[profile.id] == generation,
              await gate.tryAcquire() else { return nil }
        let succeeded: Bool
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
            guard !healthMonitoringSuspended,
                  healthMonitorGenerations[profile.id] == generation else {
                await gate.release()
                return nil
            }
            if latestHealthSuccess[profile.id] != true {
                await lifecycle.transition(.healthPassed(
                    serviceID: profile.id,
                    description: "Configured health checks recovered."
                ))
            }
            latestHealthSuccess[profile.id] = true
            succeeded = true
        } catch {
            guard !healthMonitoringSuspended,
                  healthMonitorGenerations[profile.id] == generation else {
                await gate.release()
                return nil
            }
            if latestHealthSuccess[profile.id] != false {
                await lifecycle.transition(.healthDegraded(
                    serviceID: profile.id,
                    reason: "A configured health check failed after startup: \(error.localizedDescription)"
                ))
            }
            latestHealthSuccess[profile.id] = false
            succeeded = false
        }
        await gate.release()
        return succeeded
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
