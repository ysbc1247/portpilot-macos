import Foundation

enum RestartTrustEvaluator {
    static func observedSummary(
        for listener: ObservedListener,
        assessedAt: Date = Date()
    ) -> RestartTrustSummary {
        if listener.process.docker != nil {
            return RestartTrustSummary(
                state: .conditionallyRestartable,
                reasons: [
                    "The running container has an exact Docker identity and can be restarted while it exists.",
                    "DevBerth does not yet have a reviewed definition that can recreate the container after removal."
                ],
                assessedAt: assessedAt,
                lastValidatedAt: nil
            )
        }
        guard listener.process.fingerprint.isStrong else {
            return RestartTrustSummary(
                state: .notRestartable,
                reasons: ["The observed process does not have a complete safety fingerprint."],
                assessedAt: assessedAt,
                lastValidatedAt: nil
            )
        }
        guard listener.process.executablePath != nil else {
            return RestartTrustSummary(
                state: .notRestartable,
                reasons: ["The executable path is unavailable."],
                assessedAt: assessedAt,
                lastValidatedAt: nil
            )
        }
        guard listener.process.currentDirectory != nil else {
            return RestartTrustSummary(
                state: .notRestartable,
                reasons: ["The original working directory is unavailable."],
                assessedAt: assessedAt,
                lastValidatedAt: nil
            )
        }
        return RestartTrustSummary(
            state: .inferredRestartCandidate,
            reasons: [
                "The executable, command line, and working directory were observed.",
                "The original argument boundaries, shell state, and environment were not observed completely.",
                "Review and validate a managed-service definition before relying on restart."
            ],
            assessedAt: assessedAt,
            lastValidatedAt: nil
        )
    }

    static func assessment(
        for profile: ManagedServiceConfiguration,
        validation: ManagedServiceValidationResult?,
        fileManager: FileManager = .default,
        assessedAt: Date = Date()
    ) -> RestartTrustAssessment {
        let summary = summary(
            for: profile,
            validation: validation,
            fileManager: fileManager,
            assessedAt: assessedAt
        )
        return RestartTrustAssessment(
            id: UUID(),
            managedServiceID: profile.id,
            state: summary.state,
            reasons: summary.reasons,
            evidenceIDs: validation.map { [$0.id] } ?? [],
            assessedAt: summary.assessedAt,
            lastValidatedAt: summary.lastValidatedAt
        )
    }

    static func summary(
        for profile: ManagedServiceConfiguration,
        validation: ManagedServiceValidationResult?,
        fileManager: FileManager = .default,
        assessedAt: Date = Date()
    ) -> RestartTrustSummary {
        let validationErrors = ManagedServiceValidator.validate(profile, fileManager: fileManager)
            .filter { $0.severity == .error }
        let sensitivePlaintextNames = profile.environment.keys
            .filter(SensitiveEnvironmentKeyPolicy.isSensitive)
            .sorted()
        if !validationErrors.isEmpty || !sensitivePlaintextNames.isEmpty {
            var reasons = validationErrors.map(\.message)
            if !sensitivePlaintextNames.isEmpty {
                reasons.append(
                    "Move secret-like environment fields to Keychain references: \(sensitivePlaintextNames.joined(separator: ", "))."
                )
            }
            return RestartTrustSummary(
                state: .notRestartable,
                reasons: reasons,
                assessedAt: assessedAt,
                lastValidatedAt: validation?.completedAt
            )
        }
        guard profile.isReviewed else {
            return RestartTrustSummary(
                state: .inferredRestartCandidate,
                reasons: ["The launch definition contains inferred fields that have not been reviewed."],
                assessedAt: assessedAt,
                lastValidatedAt: validation?.completedAt
            )
        }
        let hasReadinessDefinition = profile.expectedPorts.contains(where: \.required)
            || profile.healthCheck != nil
        guard hasReadinessDefinition else {
            return RestartTrustSummary(
                state: .conditionallyRestartable,
                reasons: ["Add an expected listener or health check so a validation run can prove readiness."],
                assessedAt: assessedAt,
                lastValidatedAt: validation?.completedAt
            )
        }

        let currentDigest = ManagedServiceConfigurationDigest.make(for: profile)
        if let validation, validation.succeeded, validation.configurationDigest == currentDigest {
            return RestartTrustSummary(
                state: .verifiedRestartable,
                reasons: [
                    "The current launch definition completed an isolated start, readiness, and clean-stop validation."
                ],
                assessedAt: assessedAt,
                lastValidatedAt: validation.completedAt
            )
        }
        if let validation, validation.configurationDigest != currentDigest {
            return RestartTrustSummary(
                state: .conditionallyRestartable,
                reasons: ["Launch-critical fields changed after the last validation run."],
                assessedAt: assessedAt,
                lastValidatedAt: validation.completedAt
            )
        }
        if let validation, !validation.succeeded {
            return RestartTrustSummary(
                state: .conditionallyRestartable,
                reasons: ["The latest isolated validation failed: \(validation.summary)"],
                assessedAt: assessedAt,
                lastValidatedAt: validation.completedAt
            )
        }
        return RestartTrustSummary(
            state: .conditionallyRestartable,
            reasons: ["The definition is reviewed, but the current configuration has not completed an isolated validation run."],
            assessedAt: assessedAt,
            lastValidatedAt: nil
        )
    }
}
