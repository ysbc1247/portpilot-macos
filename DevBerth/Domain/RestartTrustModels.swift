import Foundation

enum RestartTrustState: String, Codable, CaseIterable, Sendable {
    case verifiedRestartable
    case conditionallyRestartable
    case inferredRestartCandidate
    case notRestartable

    var title: String {
        switch self {
        case .verifiedRestartable: "Verified restartable"
        case .conditionallyRestartable: "Conditionally restartable"
        case .inferredRestartCandidate: "Inferred restart candidate"
        case .notRestartable: "Not restartable"
        }
    }

    var symbol: String {
        switch self {
        case .verifiedRestartable: "checkmark.seal.fill"
        case .conditionallyRestartable: "exclamationmark.shield.fill"
        case .inferredRestartCandidate: "wand.and.stars"
        case .notRestartable: "nosign"
        }
    }
}

struct RestartTrustSummary: Hashable, Codable, Sendable {
    let state: RestartTrustState
    let reasons: [String]
    let assessedAt: Date
    let lastValidatedAt: Date?
}

struct RestartTrustAssessment: Hashable, Codable, Sendable, Identifiable {
    let id: UUID
    let managedServiceID: UUID
    let state: RestartTrustState
    let reasons: [String]
    let evidenceIDs: [UUID]
    let assessedAt: Date
    let lastValidatedAt: Date?

    var summary: RestartTrustSummary {
        RestartTrustSummary(
            state: state,
            reasons: reasons,
            assessedAt: assessedAt,
            lastValidatedAt: lastValidatedAt
        )
    }
}

enum ManagedServiceValidationStatus: String, Codable, Sendable {
    case succeeded
    case failed
}

struct ManagedServiceValidationEvidence: Hashable, Codable, Sendable, Identifiable {
    let id: UUID
    let field: String
    let detail: String
    let isVerified: Bool

    init(id: UUID = UUID(), field: String, detail: String, isVerified: Bool) {
        self.id = id
        self.field = field
        self.detail = detail
        self.isVerified = isVerified
    }
}

struct ManagedServiceValidationResult: Hashable, Codable, Sendable, Identifiable {
    let id: UUID
    let managedServiceID: UUID
    let configurationDigest: String
    let status: ManagedServiceValidationStatus
    let summary: String
    let evidence: [ManagedServiceValidationEvidence]
    let startedAt: Date
    let completedAt: Date

    var succeeded: Bool { status == .succeeded }
}

enum SensitiveEnvironmentKeyPolicy {
    private static let exactNames: Set<String> = [
        "DATABASE_URL", "REDIS_URL", "MONGODB_URI", "AUTHORIZATION", "COOKIE",
        "PRIVATE_KEY", "CLIENT_SECRET", "CONNECTION_STRING"
    ]
    private static let fragments = [
        "TOKEN", "SECRET", "PASSWORD", "PASSWD", "API_KEY", "APIKEY", "PRIVATE_KEY",
        "CREDENTIAL", "AUTH_HEADER", "ACCESS_KEY", "SESSION_KEY"
    ]

    static func isSensitive(_ name: String) -> Bool {
        let normalized = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: "-", with: "_")
        guard !normalized.isEmpty else { return false }
        return exactNames.contains(normalized) || fragments.contains { normalized.contains($0) }
    }
}

enum ManagedServiceConfigurationDigest {
    static func make(for profile: ManagedServiceConfiguration) -> String {
        let definition = RestartDefinition(profile: profile)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(definition)) ?? Data()
        return ProcessFingerprint.digest(commandLine: data.base64EncodedString())
    }
}

private struct RestartDefinition: Codable {
    let launchMechanism: LaunchMechanism
    let command: String
    let arguments: [String]
    let workingDirectory: String
    let shell: ShellSelection
    let environment: [String: String]
    let secretReferences: [String: UUID]
    let expectedPorts: [ExpectedListenerConfiguration]
    let startupTimeoutSeconds: Double
    let shutdownTimeoutSeconds: Double
    let restartPolicy: RestartPolicy
    let processPolicy: ManagedServiceProcessPolicy
    let healthCheck: HealthCheckConfiguration?
    let dependencyServiceIDs: [UUID]

    init(profile: ManagedServiceConfiguration) {
        launchMechanism = profile.launchMechanism
        command = profile.command
        arguments = profile.arguments
        workingDirectory = profile.workingDirectory
        shell = profile.shell
        environment = profile.environment
        secretReferences = profile.secretReferences
        expectedPorts = profile.expectedPorts.sorted {
            ($0.protocolKind.rawValue, $0.port, $0.id.uuidString)
                < ($1.protocolKind.rawValue, $1.port, $1.id.uuidString)
        }
        startupTimeoutSeconds = profile.startupTimeoutSeconds
        shutdownTimeoutSeconds = profile.shutdownTimeoutSeconds
        restartPolicy = profile.restartPolicy
        processPolicy = profile.processPolicy
        healthCheck = profile.healthCheck
        dependencyServiceIDs = profile.dependencyServiceIDs.sorted { $0.uuidString < $1.uuidString }
    }
}
