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
