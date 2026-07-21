import Foundation

enum DevBerthError: LocalizedError, Identifiable, Sendable {
    case commandUnavailable(String)
    case commandFailed(command: String, status: Int32, details: String)
    case malformedOutput(command: String)
    case permissionDenied(String)
    case dockerUnavailable(String)
    case processFingerprintChanged(String)
    case listenerOwnershipChanged(UInt16)
    case ownerActionUnavailable(owner: String, reason: String)
    case restartTrustRequired(service: String, reason: String)
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
        case let .malformedOutput(command): "DevBerth could not understand output from \(command)."
        case let .permissionDenied(action): "Permission was denied while attempting to \(action)."
        case let .dockerUnavailable(details): "Docker is unavailable. \(details)"
        case let .processFingerprintChanged(details): "The process fingerprint changed before the action could be completed. \(details)"
        case let .listenerOwnershipChanged(port): "PID ownership of port \(port) changed before the action. DevBerth did not send a signal."
        case let .ownerActionUnavailable(owner, reason): "The requested action is unavailable for \(owner). \(reason)"
        case let .restartTrustRequired(service, reason): "\(service) is not verified restartable. \(reason)"
        case let .protectedProcess(reason): "DevBerth protected this process from termination. \(reason)"
        case let .launchValidation(details): "The managed service is not ready: \(details)"
        case let .portConflict(port): "Port \(port) is already occupied. Inspect the process before continuing."
        case let .healthCheckTimedOut(url): "The service started, but its health check at \(url.absoluteString) timed out."
        case let .missingSecret(name): "The Keychain value for ‘\(name)’ is missing."
        case let .unexpected(details): details
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .dockerUnavailable: "Start Docker or continue using DevBerth without container controls."
        case .processFingerprintChanged, .listenerOwnershipChanged: "Refresh Runtime to select the current process and listener."
        case .ownerActionUnavailable: "Inspect “Why is this running?” and use the controlling tool named there."
        case .restartTrustRequired: "Review the managed-service definition and complete a successful validation run."
        case .protectedProcess: "Inspect the exact executable and owner. Use Terminal if you intentionally need an administrative action."
        case .portConflict: "Cancel, inspect or stop the occupying process, or edit the expected port."
        case .missingSecret: "Edit the managed service and save the missing secret again."
        default: nil
        }
    }
}
