import Darwin
import DevBerthControlContracts
import Foundation
import MCP

@main
enum DevBerthMCPMain {
    static func main() async {
        do {
            let options = try MCPCommandOptions.parse(CommandLine.arguments)
            if options.printVersion {
                FileHandle.standardError.write(Data("devberth-mcp 0.1.0\n".utf8))
                return
            }
            guard options.serveStdio else { throw MCPBridgeError.usage }
            try await DevBerthMCPServer(options: options).run()
        } catch {
            FileHandle.standardError.write(Data("devberth-mcp: \(error.localizedDescription)\n".utf8))
            Darwin.exit(64)
        }
    }
}

struct MCPCommandOptions: Sendable {
    let serveStdio: Bool
    let developmentMode: Bool
    let workspace: URL?
    let printVersion: Bool

    static func parse(_ raw: [String]) throws -> MCPCommandOptions {
        let arguments = Array(raw.dropFirst())
        if arguments == ["--version"] || arguments == ["version"] {
            return MCPCommandOptions(serveStdio: false, developmentMode: false, workspace: nil, printVersion: true)
        }
        guard arguments.starts(with: ["serve", "--stdio"]) else { throw MCPBridgeError.usage }
        var development = false
        var workspace: URL?
        var index = 2
        while index < arguments.count {
            switch arguments[index] {
            case "--development":
                development = true
                index += 1
            case "--workspace":
                guard index + 1 < arguments.count else { throw MCPBridgeError.usage }
                let value = URL(fileURLWithPath: arguments[index + 1], isDirectory: true).standardizedFileURL
                var isDirectory: ObjCBool = false
                guard value.path.hasPrefix("/"), FileManager.default.fileExists(atPath: value.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    throw MCPBridgeError.invalidWorkspace
                }
                workspace = value
                index += 2
            default:
                throw MCPBridgeError.usage
            }
        }
#if !DEBUG
        guard !development else { throw MCPBridgeError.developmentUnavailable }
#endif
        guard !development || workspace != nil else { throw MCPBridgeError.developmentWorkspaceRequired }
        return MCPCommandOptions(serveStdio: true, developmentMode: development, workspace: workspace, printVersion: false)
    }
}

enum MCPBridgeError: LocalizedError {
    case usage
    case invalidWorkspace
    case developmentWorkspaceRequired
    case developmentUnavailable
    case hostUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .usage: "Usage: devberth-mcp serve --stdio [--development --workspace /absolute/repository]"
        case .invalidWorkspace: "The development workspace must be an existing absolute directory."
        case .developmentWorkspaceRequired: "Development mode requires --workspace with an existing repository root."
        case .developmentUnavailable: "Development mode is not present in Release builds. Build the Debug helper through Scripts/run-mcp-development."
        case let .hostUnavailable(message): "The DevBerth control host is unavailable. \(message)"
        }
    }
}
