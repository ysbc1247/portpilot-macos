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
            let application: ControlHostApplicationIdentity
            do {
                application = try ControlHostApplication.resolveDevelopment()
            } catch {
                throw MCPBridgeError.hostUnavailable(error.localizedDescription)
            }
            let process = Process()
            process.executableURL = application.executableURL
            process.arguments = ["--development-control-host"]
            var environment = ProcessInfo.processInfo.environment
            environment["DEVBERTH_DEVELOPMENT_CONTROL"] = "1"
            environment["DEVBERTH_DEVELOPMENT_WORKSPACE"] = options.workspace?.path
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
        } else {
            let application: ControlHostApplicationIdentity
            do {
                application = try ControlHostApplication.resolveInstalledProduction()
            } catch {
                throw MCPBridgeError.hostUnavailable(error.localizedDescription)
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-gj", application.bundleURL.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
        }
    }
}
