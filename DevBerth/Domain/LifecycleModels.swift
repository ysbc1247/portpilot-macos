import Foundation

enum LifecycleEventCategory: String, Codable, CaseIterable, Sendable {
    case requested
    case preflight
    case starting
    case ready
    case healthChanged
    case stopping
    case exited
    case failed
    case ownershipChanged
    case sessionRestore
}

enum LifecycleEventOutcome: String, Codable, CaseIterable, Sendable {
    case pending
    case observed
    case succeeded
    case failed
    case cancelled
}

struct LifecycleEvent: Hashable, Codable, Sendable, Identifiable {
    let id: UUID
    let timestamp: Date
    let runtimeID: UUID?
    let managedServiceID: UUID?
    let projectID: UUID?
    let sessionID: UUID?
    let category: LifecycleEventCategory
    let outcome: LifecycleEventOutcome
    let summary: String
    let details: [String: String]
}
