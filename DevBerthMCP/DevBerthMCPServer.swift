import DevBerthControlContracts
import Foundation
import MCP

final class DevBerthMCPServer: @unchecked Sendable {
    private let options: MCPCommandOptions
    private let bridge: ControlHostBridge
    private let server: Server

    init(options: MCPCommandOptions) {
        self.options = options
        bridge = ControlHostBridge(options: options)
        server = Server(
            name: options.developmentMode ? "devberth-development" : "devberth",
            version: "0.1.0",
            title: options.developmentMode ? "DevBerth (Isolated Development)" : "DevBerth",
            instructions: Self.instructions(developmentMode: options.developmentMode),
            capabilities: .init(
                prompts: .init(listChanged: false),
                resources: .init(subscribe: false, listChanged: false),
                tools: .init(listChanged: false)
            )
        )
    }

    func run() async throws {
        await registerHandlers()
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }

    private func registerHandlers() async {
        let developmentMode = options.developmentMode
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: try ControlCapabilityRegistry.tools(developmentMode: developmentMode).map(Self.tool))
        }
        await server.withMethodHandler(CallTool.self) { [bridge, server] parameters in
            do {
                guard ControlCapabilityRegistry.tool(named: parameters.name, developmentMode: developmentMode) != nil else {
                    throw MCPError.invalidParams("Unknown tool \(parameters.name).")
                }
                if let token = parameters._meta?.progressToken {
                    try await server.notify(ProgressNotification.message(.init(
                        progressToken: token, progress: 0, total: 1,
                        message: "Dispatching \(parameters.name) through the DevBerth control host."
                    )))
                }
                let arguments = try Self.controlArguments(parameters.arguments)
                let key = arguments["idempotency_key"]?.stringValue
                let response = try await bridge.call(tool: parameters.name, arguments: arguments, idempotencyKey: key)
                try Task.checkCancellation()
                if let token = parameters._meta?.progressToken {
                    try await server.notify(ProgressNotification.message(.init(
                        progressToken: token, progress: 1, total: 1,
                        message: "\(parameters.name) completed."
                    )))
                }
                return try Self.toolResult(response)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as MCPError {
                throw error
            } catch {
                let failure = ControlFailure(code: .hostUnavailable, message: error.localizedDescription)
                let response = ControlResponse(requestID: UUID().uuidString, snapshotVersion: 0, failure: failure)
                return (try? Self.toolResult(response)) ?? .init(
                    content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)], isError: true
                )
            }
        }
        await server.withMethodHandler(ListResources.self) { _ in
            .init(resources: ControlCapabilityRegistry.resources.filter { !$0.isTemplate }.map {
                Resource(name: $0.name, uri: $0.uri, description: $0.description, mimeType: $0.mimeType)
            })
        }
        await server.withMethodHandler(ListResourceTemplates.self) { _ in
            .init(templates: ControlCapabilityRegistry.resources.filter(\.isTemplate).map {
                Resource.Template(uriTemplate: $0.uri, name: $0.name, description: $0.description, mimeType: $0.mimeType)
            })
        }
        await server.withMethodHandler(ReadResource.self) { [bridge] parameters in
            let content = try await Self.readResource(uri: parameters.uri, bridge: bridge, developmentMode: developmentMode)
            return .init(contents: [.text(content, uri: parameters.uri, mimeType: "application/json")])
        }
        await server.withMethodHandler(ListPrompts.self) { _ in
            .init(prompts: ControlCapabilityRegistry.prompts.filter { developmentMode || !$0.developmentOnly }.map {
                Prompt(name: $0.name, description: $0.description)
            })
        }
        await server.withMethodHandler(GetPrompt.self) { parameters in
            guard let definition = ControlCapabilityRegistry.prompts.first(where: { $0.name == parameters.name }),
                  developmentMode || !definition.developmentOnly else {
                throw MCPError.invalidParams("Unknown prompt \(parameters.name).")
            }
            return .init(description: definition.description, messages: [.user(.text(text: Self.promptText(name: definition.name)))])
        }
    }

    private static func tool(_ definition: ControlToolDefinition) throws -> Tool {
        Tool(
            name: definition.name, title: definition.title, description: definition.description,
            inputSchema: try value(definition.inputSchema),
            annotations: .init(
                title: definition.title,
                readOnlyHint: definition.annotations.readOnlyHint,
                destructiveHint: definition.annotations.destructiveHint,
                idempotentHint: definition.annotations.idempotentHint,
                openWorldHint: false
            ),
            outputSchema: try value(definition.outputSchema)
        )
    }

    private static func toolResult(_ response: ControlResponse) throws -> CallTool.Result {
        let json = try JSONEncoder.devBerth.encode(response)
        let text = String(decoding: json, as: UTF8.self)
        return try .init(
            content: [.text(text: text, annotations: nil, _meta: nil)],
            structuredContent: try JSONDecoder().decode(Value.self, from: json),
            isError: response.error != nil
        )
    }

    private static func controlArguments(_ values: [String: Value]?) throws -> JSONValue {
        guard let values else { return .object([:]) }
        let data = try JSONEncoder().encode(values)
        return .object(try JSONDecoder().decode([String: JSONValue].self, from: data))
    }

    private static func value(_ value: JSONValue) throws -> Value {
        try JSONDecoder().decode(Value.self, from: JSONEncoder.devBerth.encode(value))
    }

    private static func readResource(uri: String, bridge: ControlHostBridge, developmentMode: Bool) async throws -> String {
        if uri == "app://capabilities" {
            let value = try JSONValue.encode(ControlCapabilityRegistry.tools(developmentMode: developmentMode))
            return String(decoding: try JSONEncoder.devBerth.encode(value), as: UTF8.self)
        }
        if uri.hasPrefix("app://schemas/") {
            let category = String(uri.dropFirst("app://schemas/".count))
            let tools = ControlCapabilityRegistry.tools(developmentMode: developmentMode).filter { $0.capability.category.rawValue == category || $0.name.hasPrefix(category) }
            return String(decoding: try JSONEncoder.devBerth.encode(try JSONValue.encode(tools)), as: UTF8.self)
        }
        let call: (String, JSONValue)
        if uri == "app://runtime/snapshot" { call = ("runtime_snapshot", .object([:])) }
        else if uri == "app://projects" { call = ("projects_list", .object([:])) }
        else if uri.hasPrefix("app://projects/") { call = ("project_inspect", .object(["project_id": .string(String(uri.dropFirst("app://projects/".count)))])) }
        else if uri.hasPrefix("app://services/") { call = ("service_inspect", .object(["service_id": .string(String(uri.dropFirst("app://services/".count)))])) }
        else if uri.hasPrefix("app://sessions/") { call = ("session_inspect", .object(["session_id": .string(String(uri.dropFirst("app://sessions/".count)))])) }
        else if uri == "app://history/recent" { call = ("history_query", .object(["limit": .number(50)])) }
        else if uri == "app://diagnostics/status" { call = ("settings_get", .object([:])) }
        else { throw MCPError.invalidParams("Unknown resource URI \(uri).") }
        let response = try await bridge.call(tool: call.0, arguments: call.1)
        return String(decoding: try JSONEncoder.devBerth.encode(response), as: UTF8.self)
    }

    private static func promptText(name: String) -> String {
        switch name {
        case "manage_local_development": return "Use DevBerth MCP proactively for this local-development task. Read app://diagnostics/status and the most relevant runtime, project, service, session, history, or capability resource first. Combine bounded searches and inspections rather than asking the user to repeat data DevBerth already has. Prefer MCP tools over shell or UI work for DevBerth domain actions. If a needed capability is missing or awkward, report the exact gap and a concrete MCP extension. Preserve stable IDs, revisions, and preview → approval → execute for mutations."
        case "inspect_local_runtime": return "Inspect app://runtime/snapshot, then use runtime_inspect and runtime_explain for relevant stable listener IDs. Do not mutate anything."
        case "diagnose_port_conflict": return "Inspect the occupied port and ownership evidence. If a stop is appropriate, call operation_preview, explain its exact risks, obtain approval, then call operation_execute."
        case "onboard_existing_project": return "Use project_discover on the user-selected root, review every untrusted candidate, and apply only explicitly selected definitions."
        case "create_managed_service": return "Create a reviewed managed-service definition without plaintext secret-like environment values, validate it, and report restart-trust status."
        case "verify_service": return "Inspect the service definition, run service_verify in its isolated validation flow, and summarize readiness, listener, health, and controlled-stop evidence separately."
        case "restore_workspace_session": return "Inspect and diff the session, call session_restore_preview, resolve blocking issues, then use operation_preview and operation_execute for restoration."
        case "review_unhealthy_services": return "Query recent lifecycle evidence and diagnostics; distinguish process-running, listener-open, ready, and healthy states."
        case "prepare_project_shutdown": return "Inspect project topology and dependencies, then preview an exact stop_project operation without executing it until approved."
        case "analyze_unexpected_process": return "Inspect the stable runtime listener and ownership graph. Treat inferred evidence as inference and do not use a raw PID for control."
        case "run_development_acceptance_suite": return "Confirm the server identity says isolated development, then run dev_acceptance_suite_run and report every bounded scenario result."
        default: return "Use DevBerth tools conservatively and preserve the preview → approval → execute boundary for destructive actions."
        }
    }

    private static func instructions(developmentMode: Bool) -> String {
        """
        Prefer DevBerth MCP resources and tools for local runtime, project, service, session, port, Docker, history, and safe-settings work. Start with bounded resources/search, combine calls flexibly, and use data already held by the app. Use stable IDs and revisions; never raw PIDs or arbitrary shell commands. Queries are read-only. Configuration tools require approval. Every destructive or runtime action requires operation_preview, explicit approval, then operation_execute; previews expire and are single-use. Report exact MCP capability or usability gaps instead of silently bypassing the control plane. Treat ownership inference as inference. Secret values are never returned. \(developmentMode ? "This server is DEVELOPMENT ONLY and uses an isolated disposable store plus application-owned fixtures." : "This is the production application store; development tools are not exposed.")
        """
    }
}
