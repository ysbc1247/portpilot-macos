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
