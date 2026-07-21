import Foundation

enum OwnershipCategory: String, Codable, CaseIterable, Sendable {
    case applicationManagedProcess
    case standaloneHostProcess
    case shellLaunchedProcess
    case terminalLaunchedProcess
    case ideLaunchedProcess
    case codingAgentLaunchedProcess
    case dockerContainer
    case dockerComposeService
    case homebrewService
    case kubernetesPortForward
    case sshTunnel
    case launchAgent
    case launchDaemon
    case supervisorManagedProcess
    case unknown

    var title: String {
        switch self {
        case .applicationManagedProcess: "DevBerth managed process"
        case .standaloneHostProcess: "Standalone host process"
        case .shellLaunchedProcess: "Shell-launched process"
        case .terminalLaunchedProcess: "Terminal-launched process"
        case .ideLaunchedProcess: "IDE-launched process"
        case .codingAgentLaunchedProcess: "Coding-agent-launched process"
        case .dockerContainer: "Docker container"
        case .dockerComposeService: "Docker Compose service"
        case .homebrewService: "Homebrew service"
        case .kubernetesPortForward: "Kubernetes port forward"
        case .sshTunnel: "SSH tunnel"
        case .launchAgent: "LaunchAgent"
        case .launchDaemon: "LaunchDaemon"
        case .supervisorManagedProcess: "Supervisor-managed process"
        case .unknown: "Unknown owner"
        }
    }
}

enum EvidenceConfidence: String, Codable, CaseIterable, Comparable, Sendable {
    case unknown
    case weaklyInferred
    case stronglyInferred
    case verified

    private var rank: Int {
        switch self {
        case .unknown: 0
        case .weaklyInferred: 1
        case .stronglyInferred: 2
        case .verified: 3
        }
    }

    static func < (lhs: EvidenceConfidence, rhs: EvidenceConfidence) -> Bool {
        lhs.rank < rhs.rank
    }

    var title: String {
        switch self {
        case .verified: "Verified"
        case .stronglyInferred: "Strongly inferred"
        case .weaklyInferred: "Weakly inferred"
        case .unknown: "Unknown"
        }
    }
}

enum OwnershipDetectionMethod: String, Codable, CaseIterable, Sendable {
    case managedRuntimeRegistry
    case processLineage
    case commandSignature
    case dockerMetadata
    case composeMetadata
    case serviceManager
    case launchdMetadata
    case userAssignment
    case unknown

    var title: String {
        switch self {
        case .managedRuntimeRegistry: "Managed runtime registry"
        case .processLineage: "Process lineage"
        case .commandSignature: "Command signature"
        case .dockerMetadata: "Docker metadata"
        case .composeMetadata: "Docker Compose metadata"
        case .serviceManager: "Service-manager evidence"
        case .launchdMetadata: "launchd evidence"
        case .userAssignment: "User assignment"
        case .unknown: "Unknown method"
        }
    }
}

enum OwnershipSubject: Hashable, Codable, Sendable {
    case listener(id: String)
    case process(fingerprint: ProcessFingerprint)
    case runtime(id: UUID)
}

struct OwnershipEvidenceItem: Hashable, Codable, Sendable, Identifiable {
    let id: UUID
    let field: String
    let value: String
    let source: String
    let isVerified: Bool

    init(id: UUID = UUID(), field: String, value: String, source: String, isVerified: Bool) {
        self.id = id
        self.field = field
        self.value = value
        self.source = source
        self.isVerified = isVerified
    }
}

struct OwnershipConclusion: Hashable, Codable, Sendable, Identifiable {
    let id: UUID
    let subject: OwnershipSubject
    let category: OwnershipCategory
    let value: String
    let confidence: EvidenceConfidence
    let evidence: [OwnershipEvidenceItem]
    let detectionMethod: OwnershipDetectionMethod
    let observedAt: Date

    init(
        id: UUID = UUID(),
        subject: OwnershipSubject,
        category: OwnershipCategory,
        value: String,
        confidence: EvidenceConfidence,
        evidence: [OwnershipEvidenceItem],
        detectionMethod: OwnershipDetectionMethod,
        observedAt: Date = Date()
    ) {
        self.id = id
        self.subject = subject
        self.category = category
        self.value = value
        self.confidence = confidence
        self.evidence = evidence
        self.detectionMethod = detectionMethod
        self.observedAt = observedAt
    }
}

enum LifecycleControllerKind: String, Codable, Sendable {
    case managedProcess
    case dockerContainer
    case dockerComposeService
    case homebrewService
    case kubernetesPortForward
    case sshTunnel
    case launchdService
    case guardedExternalProcess
    case unavailable
}

enum LifecycleActionKind: String, Codable, Hashable, Sendable {
    case inspect
    case gracefulStop
    case forceStop
    case restart
}

struct ProcessLineageNode: Hashable, Codable, Sendable, Identifiable {
    var id: ProcessFingerprint { fingerprint }
    let fingerprint: ProcessFingerprint
    let name: String
    let commandLine: String?
    let currentDirectory: String?
}

struct OwnershipActionRecommendation: Hashable, Codable, Sendable {
    let controllerKind: LifecycleControllerKind
    let title: String
    let reason: String
    let supportedActions: Set<LifecycleActionKind>

    init(
        controllerKind: LifecycleControllerKind,
        title: String,
        reason: String,
        supportedActions: Set<LifecycleActionKind> = [.inspect]
    ) {
        self.controllerKind = controllerKind
        self.title = title
        self.reason = reason
        self.supportedActions = supportedActions
    }
}

struct OwnerAwareLifecycleResult: Sendable, Equatable {
    let controllerKind: LifecycleControllerKind
    let action: LifecycleActionKind
    let didStop: Bool
    let summary: String
    let durationSeconds: Double
}

struct RuntimeOwnershipGraph: Hashable, Codable, Sendable, Identifiable {
    var id: String { listenerID }
    let listenerID: String
    let listener: ObservedListener
    let processGroupID: Int32?
    let processLineage: [ProcessLineageNode]
    let primaryConclusion: OwnershipConclusion
    let additionalConclusions: [OwnershipConclusion]
    let managedRuntimeID: UUID?
    let managedServiceID: UUID?
    let managedConfigurationDigest: String?
    let projectID: UUID?
    let workspaceSessionIDs: [UUID]
    let recommendation: OwnershipActionRecommendation
    let resolvedAt: Date
}
