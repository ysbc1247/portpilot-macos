import Foundation

enum ServiceCheckKind: Hashable, Codable, Sendable {
    case tcpListener(host: String, port: UInt16)
    case http(url: URL, expectedStatus: Int, responseContains: String?)
    case executable(path: String, arguments: [String], workingDirectory: String?)
    case fileExists(path: String)
    case dockerHealth(containerID: String)
    case dependencyReady(managedServiceID: UUID)
}

struct ServiceCheckConfiguration: Hashable, Codable, Sendable, Identifiable {
    let id: UUID
    var kind: ServiceCheckKind
    var timeoutSeconds: Double
    var intervalSeconds: Double
    var retryLimit: Int
    var initialDelaySeconds: Double
    var failureMessage: String

    init(
        id: UUID = UUID(),
        kind: ServiceCheckKind,
        timeoutSeconds: Double = 30,
        intervalSeconds: Double = 0.5,
        retryLimit: Int = 60,
        initialDelaySeconds: Double = 0,
        failureMessage: String
    ) {
        self.id = id
        self.kind = kind
        self.timeoutSeconds = timeoutSeconds
        self.intervalSeconds = intervalSeconds
        self.retryLimit = retryLimit
        self.initialDelaySeconds = initialDelaySeconds
        self.failureMessage = failureMessage
    }
}

struct ServiceCheckResult: Hashable, Codable, Sendable, Identifiable {
    let id: UUID
    let checkID: UUID
    let succeeded: Bool
    let attempts: Int
    let summary: String
    let startedAt: Date
    let completedAt: Date

    init(
        id: UUID = UUID(),
        checkID: UUID,
        succeeded: Bool,
        attempts: Int,
        summary: String,
        startedAt: Date,
        completedAt: Date
    ) {
        self.id = id
        self.checkID = checkID
        self.succeeded = succeeded
        self.attempts = attempts
        self.summary = summary
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}
