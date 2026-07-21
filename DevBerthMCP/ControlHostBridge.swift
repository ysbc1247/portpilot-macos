import AppKit
import DevBerthControlContracts
import Foundation

actor ControlHostBridge {
    private let options: MCPCommandOptions
    private let client: UnixControlClient
    private let identity: ControlClientIdentity
    private var attemptedActivation = false

    init(options: MCPCommandOptions) {
        self.options = options
        client = UnixControlClient(socketURL: ControlSocketPath.socketURL(developmentMode: options.developmentMode))
        identity = ControlClientIdentity(name: options.developmentMode ? "DevBerth MCP (development)" : "DevBerth MCP", version: "0.1.0", developmentMode: options.developmentMode)
    }

    func call(tool: String, arguments: JSONValue, idempotencyKey: String? = nil) async throws -> ControlResponse {
        let request = ControlRequest(
            handshake: ControlHandshake(client: identity), toolName: tool, arguments: arguments,
            idempotencyKey: idempotencyKey, timeoutSeconds: tool == "operation_execute" || tool == "change_set_execute" ? 120 : 60,
            source: .mcp
        )
        do { return try await client.send(request) }
        catch {
            if !attemptedActivation {
                attemptedActivation = true
                try activateHost()
                for _ in 0..<40 {
                    try await Task.sleep(for: .milliseconds(125))
                    if let response = try? await client.send(request) { return response }
                }
            }
            throw MCPBridgeError.hostUnavailable(error.localizedDescription)
        }
    }

    private func activateHost() throws {
        if options.developmentMode {
            let explicit = ProcessInfo.processInfo.environment["DEVBERTH_APP_PATH"].map(URL.init(fileURLWithPath:))
            let application = explicit ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.ysbc.devberth")
            guard let executable = application?.appendingPathComponent("Contents/MacOS/DevBerth"),
                  FileManager.default.isExecutableFile(atPath: executable.path) else {
                throw MCPBridgeError.hostUnavailable("Set DEVBERTH_APP_PATH to DevBerth.app for an isolated development host.")
            }
            let process = Process()
            process.executableURL = executable
            process.arguments = ["--development-control-host"]
            var environment = ProcessInfo.processInfo.environment
            environment["DEVBERTH_DEVELOPMENT_CONTROL"] = "1"
            environment["DEVBERTH_DEVELOPMENT_WORKSPACE"] = options.workspace?.path
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
        } else {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-gj", "-b", "com.ysbc.devberth"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
        }
    }
}
