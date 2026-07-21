import Darwin
import Foundation

enum DiagnosticsReportBuilder {
    static func build(
        listeners: [ObservedListener],
        refreshInterval: Double,
        historyRetentionDays: Int,
        notificationsEnabled: Bool,
        recentError: DevBerthError?
    ) -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Development"
        let rows = listeners.map { listener in
            "- \(listener.protocolKind.rawValue) \(listener.address):\(listener.port) | PID \(listener.process.identity.pid) | \(listener.process.name) | \(listener.process.runtime.rawValue) | protected=\(listener.process.isSystemProcess)"
        }.joined(separator: "\n")
        return """
        DevBerth diagnostics
        Generated: \(Date().formatted(.iso8601))
        Version: \(version) (\(build))
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Architecture: \(ProcessInfo.processInfo.machineHardwareName)

        Non-secret settings
        - refresh interval: \(refreshInterval) seconds
        - history retention: \(historyRetentionDays) days
        - configured-port notifications: \(notificationsEnabled)

        Discovery
        - lsof available: \(FileManager.default.isExecutableFile(atPath: "/usr/sbin/lsof"))
        - ps available: \(FileManager.default.isExecutableFile(atPath: "/bin/ps"))
        - active listeners: \(listeners.count)
        \(rows)

        Recent UI error
        \(recentError?.localizedDescription ?? "None")

        Secret values, environment values, Keychain contents, and full command lines are intentionally excluded.
        """
    }
}

private extension ProcessInfo {
    var machineHardwareName: String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var value = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.machine", &value, &size, nil, 0)
        return String(cString: value)
    }
}
