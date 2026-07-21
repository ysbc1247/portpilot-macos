import Foundation

struct ProjectDiscoveryEvidence: Hashable, Codable, Sendable, Identifiable {
    let id: UUID
    let path: String
    let detail: String
    let confidence: EvidenceConfidence

    init(id: UUID = UUID(), path: String, detail: String, confidence: EvidenceConfidence) {
        self.id = id
        self.path = path
        self.detail = detail
        self.confidence = confidence
    }
}

struct ProjectDiscoveryMetadata: Hashable, Codable, Sendable, Identifiable {
    let id: UUID
    let projectID: UUID?
    let rootPath: String
    let adapterIdentifier: String
    let projectType: String
    let evidence: [ProjectDiscoveryEvidence]
    let confidence: EvidenceConfidence
    let discoveredAt: Date
    let importedAt: Date?
}

enum ProjectDiscoveryError: LocalizedError, Equatable {
    case rootDoesNotExist(String)
    case rootIsNotDirectory(String)
    case unsafeFile(String)
    case malformedFile(path: String, reason: String)
    case unsupportedManifestVersion(Int)

    var errorDescription: String? {
        switch self {
        case let .rootDoesNotExist(path):
            "The selected project folder does not exist: \(path)"
        case let .rootIsNotDirectory(path):
            "The selected project path is not a folder: \(path)"
        case let .unsafeFile(path):
            "DevBerth did not read \(path) because it is not a regular file or exceeds the discovery size limit."
        case let .malformedFile(path, reason):
            "DevBerth could not parse \(path): \(reason)"
        case let .unsupportedManifestVersion(version):
            "This DevBerth manifest uses unsupported schema version \(version)."
        }
    }
}

struct DiscoveredServiceCandidate: Hashable, Codable, Sendable, Identifiable {
    let id: UUID
    let adapterIdentifier: String
    var name: String
    var launchMechanism: LaunchMechanism
    var command: String
    var arguments: [String]
    var workingDirectory: String
    var shell: ShellSelection
    var environment: [String: String]
    var expectedPorts: [UInt16]
    var dependencyCandidateNames: [String]
    var requiredSecretNames: [String]
    var startupTimeoutSeconds: Double
    var shutdownTimeoutSeconds: Double
    var restartPolicy: RestartPolicy
    var evidence: [ProjectDiscoveryEvidence]
    var confidence: EvidenceConfidence
    var requiresShellReview: Bool

    init(
        id: UUID = UUID(),
        adapterIdentifier: String,
        name: String,
        launchMechanism: LaunchMechanism,
        command: String,
        arguments: [String] = [],
        workingDirectory: String,
        shell: ShellSelection = .direct,
        environment: [String: String] = [:],
        expectedPorts: [UInt16] = [],
        dependencyCandidateNames: [String] = [],
        requiredSecretNames: [String] = [],
        startupTimeoutSeconds: Double = 30,
        shutdownTimeoutSeconds: Double = 5,
        restartPolicy: RestartPolicy = .never,
        evidence: [ProjectDiscoveryEvidence],
        confidence: EvidenceConfidence,
        requiresShellReview: Bool = false
    ) {
        self.id = id
        self.adapterIdentifier = adapterIdentifier
        self.name = name
        self.launchMechanism = launchMechanism
        self.command = command
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.shell = shell
        self.environment = environment
        self.expectedPorts = expectedPorts
        self.dependencyCandidateNames = dependencyCandidateNames
        self.requiredSecretNames = requiredSecretNames
        self.startupTimeoutSeconds = startupTimeoutSeconds
        self.shutdownTimeoutSeconds = shutdownTimeoutSeconds
        self.restartPolicy = restartPolicy
        self.evidence = evidence
        self.confidence = confidence
        self.requiresShellReview = requiresShellReview
    }

    func unreviewedConfiguration(projectID: UUID?) -> ManagedServiceConfiguration {
        let missingSecretReferences = Dictionary(uniqueKeysWithValues: Set(requiredSecretNames).sorted().map {
            ($0, UUID())
        })
        return ManagedServiceConfiguration(
            id: id,
            name: name,
            projectID: projectID,
            launchMechanism: launchMechanism,
            command: command,
            arguments: arguments,
            workingDirectory: workingDirectory,
            shell: shell,
            environment: environment,
            secretReferences: missingSecretReferences,
            expectedPorts: expectedPorts.map {
                ExpectedListenerConfiguration(id: UUID(), port: $0, protocolKind: .tcp, required: true)
            },
            startupTimeoutSeconds: startupTimeoutSeconds,
            shutdownTimeoutSeconds: shutdownTimeoutSeconds,
            restartPolicy: restartPolicy,
            processPolicy: .controlledProcessGroup,
            tags: ["discovered", adapterIdentifier],
            isReviewed: false
        )
    }
}

struct ProjectDiscoveryFinding: Hashable, Codable, Sendable, Identifiable {
    let id: UUID
    let adapterIdentifier: String
    let projectType: String
    let evidence: [ProjectDiscoveryEvidence]
    let confidence: EvidenceConfidence
    let candidates: [DiscoveredServiceCandidate]

    init(
        id: UUID = UUID(),
        adapterIdentifier: String,
        projectType: String,
        evidence: [ProjectDiscoveryEvidence],
        confidence: EvidenceConfidence,
        candidates: [DiscoveredServiceCandidate]
    ) {
        self.id = id
        self.adapterIdentifier = adapterIdentifier
        self.projectType = projectType
        self.evidence = evidence
        self.confidence = confidence
        self.candidates = candidates
    }
}

struct ProjectDiscoveryReport: Hashable, Codable, Sendable {
    let rootPath: String
    let findings: [ProjectDiscoveryFinding]
    let discoveredAt: Date

    var candidates: [DiscoveredServiceCandidate] {
        findings.flatMap(\.candidates)
    }

    var recognizedProjectTypes: [String] {
        Array(Set(findings.map(\.projectType))).sorted()
    }
}

struct DevBerthProjectManifest: Hashable, Codable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    var projectName: String
    var services: [DevBerthManifestService]
}

struct DevBerthManifestService: Hashable, Codable, Sendable, Identifiable {
    let id: UUID
    var name: String
    var launchMechanism: LaunchMechanism
    var command: String
    var arguments: [String]
    var relativeWorkingDirectory: String
    var shell: ShellSelection
    var environment: [String: String]
    var expectedPorts: [UInt16]
    var dependencyNames: [String]
    var secretNames: [String]
    var startupTimeoutSeconds: Double
    var shutdownTimeoutSeconds: Double
    var restartPolicy: RestartPolicy
}
