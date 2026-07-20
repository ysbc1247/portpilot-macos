import Foundation

actor LaunchCoordinator: LaunchProfileServing {
    private let discoverer: any PortDiscovering
    private let processLauncher: any ManagedProcessLaunching
    private let healthChecker: any HealthChecking

    init(
        discoverer: any PortDiscovering,
        processLauncher: any ManagedProcessLaunching,
        healthChecker: any HealthChecking
    ) {
        self.discoverer = discoverer
        self.processLauncher = processLauncher
        self.healthChecker = healthChecker
    }

    func launch(_ profile: LaunchProfileConfiguration) async throws {
        let validationErrors = LaunchProfileValidator.validate(profile).filter { $0.severity == .error }
        guard validationErrors.isEmpty else {
            throw PortPilotError.launchValidation(validationErrors.map(\.message).joined(separator: " "))
        }
        let occupied = try await discoverer.discover()
        if let conflict = PortConflictDetector.conflicts(for: profile, listeners: occupied).first {
            throw PortPilotError.portConflict(conflict.expectedPort.port)
        }

        try await processLauncher.launch(profile)
        do {
            try await waitForExpectedPorts(profile)
            if let healthCheck = profile.healthCheck {
                try await healthChecker.waitUntilHealthy(
                    configuration: healthCheck,
                    timeoutSeconds: profile.startupTimeoutSeconds
                )
            }
        } catch {
            try? await processLauncher.stop(profileID: profile.id, timeoutSeconds: profile.shutdownTimeoutSeconds)
            throw error
        }
    }

    func stop(profileID: UUID, timeoutSeconds: Double) async throws {
        try await processLauncher.stop(profileID: profileID, timeoutSeconds: timeoutSeconds)
    }

    private func waitForExpectedPorts(_ profile: LaunchProfileConfiguration) async throws {
        let required = profile.expectedPorts.filter(\.required)
        guard !required.isEmpty else { return }
        let deadline = Date().addingTimeInterval(profile.startupTimeoutSeconds)
        while Date() < deadline {
            let listeners = try await discoverer.discover()
            let allPresent = required.allSatisfy { expected in
                listeners.contains { $0.port == expected.port && $0.protocolKind == expected.protocolKind }
            }
            if allPresent { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        let ports = required.map { String($0.port) }.joined(separator: ", ")
        throw PortPilotError.launchValidation("Expected port(s) \(ports) did not become active before the startup timeout.")
    }
}

