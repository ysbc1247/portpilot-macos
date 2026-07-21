import Foundation

enum TerminationState: Equatable, Sendable {
    case idle
    case validatingIdentity
    case blocked(reason: String)
    case sendingSignal(Int32)
    case waitingForExit(deadline: Date)
    case exited
    case timedOut
    case failed(String)
}

enum TerminationEvent: Equatable, Sendable {
    case begin
    case identityValidated
    case identityRejected
    case protectionRejected(String)
    case signalSent(signal: Int32, deadline: Date)
    case processExited
    case deadlineReached
    case error(String)
}

enum TerminationStateMachine {
    static func reduce(state: TerminationState, event: TerminationEvent) -> TerminationState {
        switch (state, event) {
        case (.idle, .begin): .validatingIdentity
        case (.validatingIdentity, .identityValidated): .sendingSignal(0)
        case (.validatingIdentity, .identityRejected): .failed("Process identity changed before termination.")
        case (.validatingIdentity, let .protectionRejected(reason)): .blocked(reason: reason)
        case (.sendingSignal, let .signalSent(signal, deadline)) where signal > 0: .waitingForExit(deadline: deadline)
        case (.waitingForExit, .processExited): .exited
        case (.waitingForExit, .deadlineReached): .timedOut
        case (_, let .error(message)): .failed(message)
        default: .failed("Invalid termination state transition.")
        }
    }
}

enum ProcessSafetyPolicy {
    static func terminationBlockReason(for process: ObservedProcess) -> String? {
        if process.owner == "root" {
            return "Root-owned processes must be managed explicitly outside DevBerth."
        }
        if process.isSystemProcess {
            return "Apple and system service processes cannot be terminated from DevBerth."
        }
        if let executable = process.executablePath, executable.hasPrefix("/System/") || executable.hasPrefix("/usr/sbin/") {
            return "The executable is in a protected system location."
        }
        return nil
    }
}

