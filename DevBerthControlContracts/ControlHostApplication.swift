import Foundation

public struct ControlHostApplicationIdentity: Equatable, Sendable {
    public let bundleURL: URL
    public let executableURL: URL

    public init(bundleURL: URL, executableURL: URL) {
        self.bundleURL = bundleURL
        self.executableURL = executableURL
    }
}

public enum ControlHostApplicationError: Error, Equatable, LocalizedError {
    case missingDevelopmentApplicationPath
    case invalidBundle(String)
    case developmentBundleRequired
    case productionBundleRequired

    public var errorDescription: String? {
        switch self {
        case .missingDevelopmentApplicationPath:
            "DEVBERTH_APP_PATH must name the exact Debug DevBerth.app used for this development session."
        case let .invalidBundle(reason):
            "The selected DevBerth application is invalid: \(reason)"
        case .developmentBundleRequired:
            "DEVBERTH_APP_PATH must identify a Debug bundle that explicitly allows the isolated development control host."
        case .productionBundleRequired:
            "The installed /Applications/DevBerth.app is not a production bundle."
        }
    }
}

public enum ControlHostApplication {
    public static let bundleIdentifier = "com.ysbc.devberth"
    public static let executableName = "DevBerth"
    public static let developmentPathEnvironmentKey = "DEVBERTH_APP_PATH"
    public static let developmentAllowedInfoKey = "DevBerthDevelopmentControlHostAllowed"
    public static let installedProductionBundleURL = URL(fileURLWithPath: "/Applications/DevBerth.app", isDirectory: true)

    public static func resolveDevelopment(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> ControlHostApplicationIdentity {
        guard let path = environment[developmentPathEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            throw ControlHostApplicationError.missingDevelopmentApplicationPath
        }
        return try validate(
            bundleURL: URL(fileURLWithPath: path, isDirectory: true),
            requiresDevelopmentPermission: true,
            fileManager: fileManager
        )
    }

    public static func resolveInstalledProduction(
        fileManager: FileManager = .default
    ) throws -> ControlHostApplicationIdentity {
        let standardized = installedProductionBundleURL.standardizedFileURL
        let resolved = standardized.resolvingSymlinksInPath()
        guard standardized.path == resolved.path else {
            throw ControlHostApplicationError.invalidBundle("/Applications/DevBerth.app must not be a symbolic link.")
        }
        return try validate(
            bundleURL: standardized,
            requiresDevelopmentPermission: false,
            fileManager: fileManager
        )
    }

    public static func validate(
        bundleURL: URL,
        requiresDevelopmentPermission: Bool,
        fileManager: FileManager = .default
    ) throws -> ControlHostApplicationIdentity {
        let bundle = bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        guard bundle.pathExtension == "app" else {
            throw ControlHostApplicationError.invalidBundle("the path is not an .app bundle.")
        }

        let infoURL = bundle.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        guard let data = fileManager.contents(atPath: infoURL.path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ControlHostApplicationError.invalidBundle("Contents/Info.plist is missing or unreadable.")
        }
        guard plist["CFBundleIdentifier"] as? String == bundleIdentifier else {
            throw ControlHostApplicationError.invalidBundle("the bundle identifier is not \(bundleIdentifier).")
        }
        guard plist["CFBundleExecutable"] as? String == executableName else {
            throw ControlHostApplicationError.invalidBundle("CFBundleExecutable is not \(executableName).")
        }

        let developmentAllowed =
            (plist[developmentAllowedInfoKey] as? NSNumber)?.boolValue == true
            || (plist[developmentAllowedInfoKey] as? String)?.caseInsensitiveCompare("YES") == .orderedSame
        if requiresDevelopmentPermission {
            guard developmentAllowed else {
                throw ControlHostApplicationError.developmentBundleRequired
            }
        } else if developmentAllowed {
            throw ControlHostApplicationError.productionBundleRequired
        }

        let executable = bundle.appendingPathComponent("Contents/MacOS/\(executableName)", isDirectory: false)
        guard fileManager.isExecutableFile(atPath: executable.path) else {
            throw ControlHostApplicationError.invalidBundle("Contents/MacOS/\(executableName) is missing or not executable.")
        }
        return ControlHostApplicationIdentity(bundleURL: bundle, executableURL: executable)
    }
}
