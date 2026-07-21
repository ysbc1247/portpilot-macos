import Foundation

struct CommandResult: Sendable, Equatable {
    let stdout: Data
    let stderr: Data
    let exitCode: Int32

    var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

protocol CommandRunning: Sendable {
    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        currentDirectory: URL?
    ) async throws -> CommandResult
}

extension CommandRunning {
    func run(executable: URL, arguments: [String]) async throws -> CommandResult {
        try await run(executable: executable, arguments: arguments, environment: nil, currentDirectory: nil)
    }
}

protocol PortDiscovering: Sendable {
    func discover() async throws -> [ObservedListener]
}

protocol ProcessFingerprintVerifying: Sendable {
    func verify(_ expected: ProcessFingerprint) async throws -> ProcessFingerprintVerification
}

protocol ListenerOwnershipVerifying: Sendable {
    func verify(
        _ expectation: ListenerOwnershipExpectation,
        isOwnedBy fingerprint: ProcessFingerprint
    ) async throws -> Bool
}

enum TerminationMode: Sendable { case graceful(timeoutSeconds: Double), force(confirmed: Bool) }

enum TerminationCompletion: String, Sendable, Equatable {
    case exited
    case fingerprintChangedAfterSignal
    case timedOut
}

struct TerminationOutcome: Sendable, Equatable {
    let pid: Int32
    let mode: String
    let completion: TerminationCompletion
    let durationSeconds: Double

    var didExit: Bool { completion != .timedOut }
}

protocol ProcessControlling: Sendable {
    func terminate(_ target: ProcessActionTarget, mode: TerminationMode) async throws -> TerminationOutcome
}

protocol SecretStoring: Sendable {
    func save(value: String, reference: UUID) async throws
    func value(for reference: UUID) async throws -> String?
    func delete(reference: UUID) async throws
}

protocol HealthChecking: Sendable {
    func waitUntilHealthy(configuration: HealthCheckConfiguration, timeoutSeconds: Double) async throws
}

protocol HistoryRecording: Sendable {
    func record(_ event: HistoryEvent) async throws
}

protocol OwnershipRecording: Sendable {
    func record(_ conclusion: OwnershipConclusion) async throws
}

protocol OwnerAwareLifecycleRouting: Sendable {
    func perform(
        _ action: LifecycleActionKind,
        on graph: RuntimeOwnershipGraph,
        forceConfirmed: Bool
    ) async throws -> OwnerAwareLifecycleResult
}

protocol LaunchProfileServing: Sendable {
    func launch(_ profile: ManagedServiceConfiguration) async throws
    func stop(profileID: UUID, timeoutSeconds: Double) async throws
}

protocol ManagedProcessLaunching: Sendable {
    func launch(_ profile: ManagedServiceConfiguration) async throws
    func stop(profileID: UUID, timeoutSeconds: Double) async throws
}
