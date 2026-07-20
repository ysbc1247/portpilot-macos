import Foundation

enum PortPilotError: LocalizedError, Identifiable, Sendable {
    case commandUnavailable(String)
    case commandFailed(command: String, status: Int32, details: String)
    case malformedOutput(command: String)
    case permissionDenied(String)
    case dockerUnavailable(String)
    case processIdentityChanged
    case protectedProcess(String)
    case launchValidation(String)
    case portConflict(UInt16)
    case healthCheckTimedOut(URL)
    case missingSecret(String)
    case unexpected(String)

    var id: String { errorDescription ?? String(describing: self) }

    var errorDescription: String? {
        switch self {
        case let .commandUnavailable(command): "The required command ‘\(command)’ is unavailable."
        case let .commandFailed(command, status, details): "\(command) exited with status \(status). \(details)"
        case let .malformedOutput(command): "PortPilot could not understand output from \(command)."
        case let .permissionDenied(action): "Permission was denied while attempting to \(action)."
        case let .dockerUnavailable(details): "Docker is unavailable. \(details)"
        case .processIdentityChanged: "The process identity changed before the action could be completed. Refresh and try again."
        case let .protectedProcess(reason): "PortPilot protected this process from termination. \(reason)"
        case let .launchValidation(details): "The launch profile is not ready: \(details)"
        case let .portConflict(port): "Port \(port) is already occupied. Inspect the process before continuing."
        case let .healthCheckTimedOut(url): "The service started, but its health check at \(url.absoluteString) timed out."
        case let .missingSecret(name): "The Keychain value for ‘\(name)’ is missing."
        case let .unexpected(details): details
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .dockerUnavailable: "Start Docker or continue using PortPilot without container controls."
        case .processIdentityChanged: "Refresh Active Ports to select the current process."
        case .protectedProcess: "Inspect the exact executable and owner. Use Terminal if you intentionally need an administrative action."
        case .portConflict: "Cancel, inspect or stop the occupying process, or edit the expected port."
        case .missingSecret: "Edit the launch profile and save the missing secret again."
        default: nil
        }
    }
}

