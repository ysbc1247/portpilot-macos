import Foundation

actor ManagedServiceValidationRunner: ManagedServiceValidating {
    private let launchService: any LaunchProfileServing
    private let clock: @Sendable () -> Date

    init(
        launchService: any LaunchProfileServing,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.launchService = launchService
        self.clock = clock
    }

    func validate(_ profile: ManagedServiceConfiguration) async -> ManagedServiceValidationResult {
        let startedAt = clock()
        let digest = ManagedServiceConfigurationDigest.make(for: profile)
        let preflight = RestartTrustEvaluator.summary(
            for: profile,
            validation: nil,
            assessedAt: startedAt
        )
        guard preflight.state != .notRestartable,
              profile.isReviewed,
              profile.expectedPorts.contains(where: \.required) || profile.healthCheck != nil else {
            return result(
                profile: profile,
                digest: digest,
                status: .failed,
                summary: preflight.reasons.joined(separator: " "),
                evidence: preflight.reasons.map {
                    .init(field: "preflight", detail: $0, isVerified: false)
                },
                startedAt: startedAt
            )
        }

        var didLaunch = false
        do {
            try await launchService.launch(profile)
            didLaunch = true
            try await launchService.stop(
                profileID: profile.id,
                timeoutSeconds: profile.shutdownTimeoutSeconds
            )
            return result(
                profile: profile,
                digest: digest,
                status: .succeeded,
                summary: "Isolated launch, readiness, and controlled shutdown succeeded.",
                evidence: successEvidence(for: profile),
                startedAt: startedAt
            )
        } catch {
            if didLaunch {
                try? await launchService.stop(
                    profileID: profile.id,
                    timeoutSeconds: profile.shutdownTimeoutSeconds
                )
            }
            return result(
                profile: profile,
                digest: digest,
                status: .failed,
                summary: error.localizedDescription,
                evidence: [
                    .init(
                        field: "validation failure",
                        detail: "The isolated validation did not complete. No secret or environment value was recorded.",
                        isVerified: false
                    )
                ],
                startedAt: startedAt
            )
        }
    }

    private func successEvidence(
        for profile: ManagedServiceConfiguration
    ) -> [ManagedServiceValidationEvidence] {
        var evidence = [
            ManagedServiceValidationEvidence(
                field: "process scope",
                detail: "A dedicated managed process group started and stopped cleanly.",
                isVerified: true
            )
        ]
        for listener in profile.expectedPorts.filter(\.required) {
            evidence.append(.init(
                field: "required listener",
                detail: "\(listener.protocolKind.rawValue) :\(listener.port) became ready.",
                isVerified: true
            ))
        }
        if let healthCheck = profile.healthCheck {
            evidence.append(.init(
                field: "health check",
                detail: "\(healthCheck.url.absoluteString) returned the reviewed status.",
                isVerified: true
            ))
        }
        return evidence
    }

    private func result(
        profile: ManagedServiceConfiguration,
        digest: String,
        status: ManagedServiceValidationStatus,
        summary: String,
        evidence: [ManagedServiceValidationEvidence],
        startedAt: Date
    ) -> ManagedServiceValidationResult {
        ManagedServiceValidationResult(
            id: UUID(),
            managedServiceID: profile.id,
            configurationDigest: digest,
            status: status,
            summary: summary,
            evidence: evidence,
            startedAt: startedAt,
            completedAt: clock()
        )
    }
}
