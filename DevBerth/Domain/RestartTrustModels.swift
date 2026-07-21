import Foundation

enum RestartTrustState: String, Codable, CaseIterable, Sendable {
    case verifiedRestartable
    case conditionallyRestartable
    case inferredRestartCandidate
    case notRestartable
}

struct RestartTrustAssessment: Hashable, Codable, Sendable, Identifiable {
    let id: UUID
    let managedServiceID: UUID
    let state: RestartTrustState
    let reasons: [String]
    let evidenceIDs: [UUID]
    let assessedAt: Date
    let lastValidatedAt: Date?
}
