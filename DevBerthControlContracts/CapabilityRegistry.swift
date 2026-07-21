import Foundation

public enum ControlDomainCategory: String, Codable, Sendable, CaseIterable {
    case runtime
    case projects
    case services
    case dependencies
    case sessions
    case ports
    case docker
    case logs
    case history
    case settings
    case organization
    case operations
    case changeSets = "change_sets"
    case development
}

public enum ControlCapabilityKind: String, Codable, Sendable {
    case query
    case configurationCommand = "configuration_command"
    case runtimeOperation = "runtime_operation"
}

public enum ControlPermissionLevel: String, Codable, Sendable {
    case automatic
    case prompt
    case destructivePrompt = "destructive_prompt"
    case developmentOnly = "development_only"
}

public struct ControlToolAnnotations: Codable, Sendable, Equatable {
    public let readOnlyHint: Bool
    public let destructiveHint: Bool
    public let idempotentHint: Bool
    public let openWorldHint: Bool

    public init(readOnly: Bool, destructive: Bool, idempotent: Bool, openWorld: Bool = false) {
        readOnlyHint = readOnly
        destructiveHint = destructive
        idempotentHint = idempotent
        openWorldHint = openWorld
    }
}

public struct ControlCapability: Codable, Sendable, Equatable, Identifiable {
    public var id: String { identifier }
    public let identifier: String
    public let displayName: String
    public let category: ControlDomainCategory
    public let kind: ControlCapabilityKind
    public let guiEntryPoint: String?
    public let menuBarEntryPoint: String?
    public let toolName: String
    public let permission: ControlPermissionLevel
    public let confirmationRequired: Bool
    public let previewRequired: Bool
    public let destructive: Bool
    public let productionAvailable: Bool
    public let developmentAvailable: Bool
    public let testReference: String
}

public struct ControlToolDefinition: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let title: String
    public let description: String
    public let inputSchema: JSONValue
    public let outputSchema: JSONValue
    public let annotations: ControlToolAnnotations
    public let capability: ControlCapability
}

public enum ControlCapabilityRegistry {
    public static let productionTools: [ControlToolDefinition] = makeProductionTools()
    public static let developmentTools: [ControlToolDefinition] = makeDevelopmentTools()
    public static let resources: [ControlResourceDefinition] = [
        .init(uri: "app://runtime/snapshot", name: "Runtime snapshot", description: "Current bounded runtime overview."),
        .init(uri: "app://projects", name: "Projects", description: "Current project collection."),
        .init(uri: "app://projects/{projectID}", name: "Project", description: "One project and its runtime topology.", isTemplate: true),
        .init(uri: "app://services/{serviceID}", name: "Managed service", description: "One safe managed-service definition.", isTemplate: true),
        .init(uri: "app://sessions/{sessionID}", name: "Workspace session", description: "One session and current drift.", isTemplate: true),
        .init(uri: "app://history/recent", name: "Recent history", description: "Recent bounded lifecycle evidence."),
        .init(uri: "app://schemas/project", name: "Project schema", description: "Project command schema."),
        .init(uri: "app://schemas/service", name: "Managed-service schema", description: "Managed-service command schema."),
        .init(uri: "app://schemas/session", name: "Session schema", description: "Workspace-session command schema."),
        .init(uri: "app://capabilities", name: "Capabilities", description: "Control-plane capability registry."),
        .init(uri: "app://diagnostics/status", name: "Control host status", description: "Non-secret MCP and host diagnostics.")
    ]
    public static let prompts: [ControlPromptDefinition] = [
        .init(name: "manage_local_development", description: "Use DevBerth resources and tools as the primary interface for a local-development task."),
        .init(name: "inspect_local_runtime", description: "Inspect the current local development runtime safely."),
        .init(name: "diagnose_port_conflict", description: "Diagnose a port conflict and preview the safest resolution."),
        .init(name: "onboard_existing_project", description: "Discover and review an existing project without executing it."),
        .init(name: "create_managed_service", description: "Create and review a managed-service definition."),
        .init(name: "verify_service", description: "Validate a service in an isolated controlled runtime."),
        .init(name: "restore_workspace_session", description: "Compare, preview, and restore a saved session."),
        .init(name: "review_unhealthy_services", description: "Review deterministic health and lifecycle evidence."),
        .init(name: "prepare_project_shutdown", description: "Preview an ownership-aware project shutdown."),
        .init(name: "analyze_unexpected_process", description: "Inspect an unexpected process without trusting inference."),
        .init(name: "run_development_acceptance_suite", description: "Run the disposable development acceptance suite.", developmentOnly: true)
    ]

    public static func tools(developmentMode: Bool) -> [ControlToolDefinition] {
        productionTools + (developmentMode ? developmentTools : [])
    }

    public static func tool(named name: String, developmentMode: Bool) -> ControlToolDefinition? {
        tools(developmentMode: developmentMode).first { $0.name == name }
    }

    private static func makeProductionTools() -> [ControlToolDefinition] {
        let queryGroups: [(ControlDomainCategory, [String])] = [
            (.runtime, ["runtime_snapshot", "runtime_search", "runtime_inspect", "runtime_explain"]),
            (.projects, ["projects_list", "project_inspect", "project_discover", "project_export", "project_validate"]),
            (.services, ["services_list", "service_inspect"]),
            (.dependencies, ["dependency_graph_get", "dependency_validate"]),
            (.sessions, ["sessions_list", "session_inspect", "session_diff", "session_export", "session_restore_preview"]),
            (.ports, ["ports_list", "port_inspect"]),
            (.docker, ["docker_status", "docker_containers_list", "docker_container_inspect", "docker_compose_projects_list", "docker_compose_project_inspect"]),
            (.logs, ["service_logs"]),
            (.history, ["history_query", "history_event_inspect", "history_export", "diagnostics_analyze"]),
            (.settings, ["settings_get"]),
            (.operations, ["operation_preview"]),
            (.changeSets, ["change_set_preview"])
        ]
        let commandGroups: [(ControlDomainCategory, [String])] = [
            (.runtime, ["runtime_update_metadata"]),
            (.projects, ["project_create", "project_update", "project_duplicate", "project_apply_discovery", "project_import", "project_archive", "project_delete"]),
            (.services, ["service_create", "service_update", "service_duplicate", "service_adopt_runtime", "service_enable", "service_archive", "service_delete"]),
            (.dependencies, ["dependency_update"]),
            (.sessions, ["session_create", "session_capture", "session_update", "session_update_from_runtime", "session_duplicate", "session_import", "session_archive", "session_delete"]),
            (.ports, ["port_watch_create", "port_watch_update", "port_watch_delete", "port_reservation_create", "port_reservation_update", "port_reservation_delete", "port_alias_create", "port_alias_update", "port_alias_delete", "port_ignore_rule_create", "port_ignore_rule_delete"]),
            (.docker, ["docker_association_update", "docker_import_compose_project"]),
            (.logs, ["logs_export"]),
            (.settings, ["settings_update"]),
            (.organization, ["favorites_update", "tags_manage", "saved_filter_create", "saved_filter_update", "saved_filter_delete"])
        ]
        let runtimeGroups: [(ControlDomainCategory, [String])] = [
            (.services, ["service_verify", "service_start", "service_recover"]),
            (.operations, ["operation_execute"]),
            (.changeSets, ["change_set_execute"])
        ]

        var result: [ControlToolDefinition] = []
        for (category, names) in queryGroups {
            result += names.map { definition(name: $0, category: category, kind: .query) }
        }
        for (category, names) in commandGroups {
            result += names.map { definition(name: $0, category: category, kind: .configurationCommand) }
        }
        for (category, names) in runtimeGroups {
            result += names.map { definition(name: $0, category: category, kind: .runtimeOperation) }
        }
        return result.sorted { $0.name < $1.name }
    }

    private static func makeDevelopmentTools() -> [ControlToolDefinition] {
        let queries = [
            "dev_build_info", "dev_internal_state", "dev_fixture_list", "dev_migration_validate",
            "dev_performance_measure", "dev_recent_errors", "dev_capability_parity_validate"
        ]
        let operations = [
            "dev_fixture_start", "dev_fixture_stop", "dev_acceptance_scenario_run",
            "dev_acceptance_suite_run", "dev_test_store_reset"
        ]
        return (queries.map {
            definition(name: $0, category: .development, kind: .query, developmentOnly: true)
        } + operations.map {
            definition(name: $0, category: .development, kind: .runtimeOperation, developmentOnly: true)
        }).sorted { $0.name < $1.name }
    }

    private static func definition(
        name: String,
        category: ControlDomainCategory,
        kind: ControlCapabilityKind,
        developmentOnly: Bool = false
    ) -> ControlToolDefinition {
        let conditionallyDestructive = ["project_delete", "service_delete", "session_delete"].contains(name)
        let destructive = conditionallyDestructive || name == "operation_execute" || name == "change_set_execute" || name == "dev_test_store_reset"
        let readOnly = kind == .query
        let previewRequired = name == "operation_execute" || name == "change_set_execute" || name == "dev_test_store_reset"
        let idempotent = readOnly || name.hasSuffix("_inspect") || name.hasSuffix("_list") || name == "operation_execute" || name == "change_set_execute"
        let permission: ControlPermissionLevel = developmentOnly ? .developmentOnly
            : destructive ? .destructivePrompt
            : readOnly ? .automatic : .prompt
        let title = name.split(separator: "_").map { $0.capitalized }.joined(separator: " ")
        let capability = ControlCapability(
            identifier: name.replacingOccurrences(of: "_", with: "."),
            displayName: title,
            category: category,
            kind: kind,
            guiEntryPoint: guiEntryPoint(for: name),
            menuBarEntryPoint: menuEntryPoint(for: name),
            toolName: name,
            permission: permission,
            confirmationRequired: !readOnly,
            previewRequired: previewRequired,
            destructive: destructive,
            productionAvailable: !developmentOnly,
            developmentAvailable: true,
            testReference: testReference(for: category)
        )
        return ControlToolDefinition(
            name: name,
            title: title,
            description: description(for: name),
            inputSchema: inputSchema(for: name),
            outputSchema: responseSchema,
            annotations: .init(readOnly: readOnly, destructive: destructive, idempotent: idempotent),
            capability: capability
        )
    }

    private static func inputSchema(for name: String) -> JSONValue {
        let noArgumentTools: Set<String> = [
            "runtime_snapshot", "projects_list", "services_list", "sessions_list", "ports_list",
            "docker_status", "docker_containers_list", "docker_compose_projects_list", "settings_get",
            "dependency_graph_get", "dev_build_info", "dev_internal_state", "dev_fixture_list",
            "dev_recent_errors", "dev_capability_parity_validate"
        ]
        if noArgumentTools.contains(name) { return objectSchema(properties: [:], required: []) }
        if name == "operation_preview" {
            return objectSchema(properties: [
                "operation_type": stringSchema(description: "Registered operation type."),
                "targets": arraySchema(items: stringSchema(description: "Stable target identifier.")),
                "options": objectSchema(properties: [:], required: [], allowsAdditional: true)
            ], required: ["operation_type", "targets"])
        }
        if name == "operation_execute" {
            return objectSchema(properties: [
                "operation_id": stringSchema(description: "Opaque preview operation identifier."),
                "idempotency_key": stringSchema(description: "Optional replay-safe idempotency key.")
            ], required: ["operation_id"])
        }
        if name == "change_set_preview" {
            return objectSchema(properties: [
                "changes": arraySchema(items: objectSchema(properties: [:], required: [], allowsAdditional: true))
            ], required: ["changes"])
        }
        if name == "change_set_execute" {
            return objectSchema(properties: [
                "change_set_token": stringSchema(description: "Opaque previewed change-set token."),
                "idempotency_key": stringSchema(description: "Optional replay-safe idempotency key.")
            ], required: ["change_set_token"])
        }
        let identifierKey = identifierKey(for: name)
        var properties: [String: JSONValue] = [
            "id": stringSchema(description: "Caller-selected stable UUID for a create, or a generic stable item identifier."),
            "name": stringSchema(description: "Human-readable entity or fixture name."),
            "revision": integerSchema(description: "Optimistic-concurrency revision."),
            "cursor": stringSchema(description: "Continuation cursor."),
            "limit": integerSchema(description: "Bounded result limit."),
            "patch": objectSchema(properties: [:], required: [], allowsAdditional: true),
            "options": objectSchema(properties: [:], required: [], allowsAdditional: true),
            "path": stringSchema(description: "Explicit local manifest path for an import or application-owned export selection."),
            "root_path": stringSchema(description: "User-selected project discovery root."),
            "project_id": stringSchema(description: "Stable project UUID."),
            "service_id": stringSchema(description: "Stable managed-service UUID."),
            "dependency_service_id": stringSchema(description: "Stable managed-service dependency UUID."),
            "session_id": stringSchema(description: "Stable workspace-session UUID."),
            "runtime_id": stringSchema(description: "Stable runtime or listener identifier; never a raw PID."),
            "port": integerSchema(description: "TCP or UDP port number."),
            "action": stringSchema(description: "Registered domain action, never a shell command."),
            "apply": boolSchema(description: "Apply a previously reviewed import or update preview."),
            "archived": boolSchema(description: "Desired archive state."),
            "enabled": boolSchema(description: "Desired enabled state."),
            "configuration": objectSchema(properties: [:], required: [], allowsAdditional: true),
            "session": objectSchema(properties: [:], required: [], allowsAdditional: true)
        ]
        properties[identifierKey] = stringSchema(description: "Stable entity identifier.")
        if name.contains("search") || name.hasSuffix("_list") || name.hasSuffix("_query") {
            properties["query"] = stringSchema(description: "Search query.")
            properties["filters"] = objectSchema(properties: [:], required: [], allowsAdditional: true)
        }
        return objectSchema(properties: properties, required: requiredKeys(for: name, identifierKey: identifierKey), allowsAdditional: true)
    }

    private static func requiredKeys(for name: String, identifierKey: String) -> [String] {
        if name == "project_create" { return ["name"] }
        if name == "service_create" { return ["name"] }
        if name == "session_create" { return ["name"] }
        if name == "project_discover" { return ["root_path"] }
        if name == "dev_fixture_start" || name == "dev_acceptance_scenario_run" { return ["name"] }
        if name == "dependency_update" { return ["service_id", "dependency_service_id", "action"] }
        if name == "favorites_update" { return ["id"] }
        if name.hasSuffix("_create") || name == "session_capture"
            || name == "tags_manage" || name == "settings_update"
            || name == "service_adopt_runtime" || name.hasSuffix("_import")
            || name == "history_export" || name == "logs_export" || name.hasPrefix("dev_") { return [] }
        if name.hasSuffix("_list") || name.hasSuffix("_query") || name == "runtime_search" { return [] }
        return [identifierKey]
    }

    private static func identifierKey(for name: String) -> String {
        if name.hasPrefix("project_") { return "project_id" }
        if name.hasPrefix("service_") || name == "service_logs" { return "service_id" }
        if name.hasPrefix("session_") { return "session_id" }
        if name.hasPrefix("port_") { return "port_id" }
        if name.hasPrefix("docker_container") { return "container_id" }
        if name.hasPrefix("docker_compose_project") { return "compose_project_id" }
        if name.hasPrefix("history_event") { return "event_id" }
        if name.hasPrefix("runtime_") { return "runtime_id" }
        return "id"
    }

    private static func guiEntryPoint(for name: String) -> String? {
        if name.hasPrefix("runtime_") { return "Runtime" }
        if name.hasPrefix("project") { return "Projects" }
        if name.hasPrefix("service") { return "Managed Services" }
        if name.hasPrefix("session") { return "Sessions" }
        if name.hasPrefix("docker") { return "Docker" }
        if name.hasPrefix("history") || name.hasPrefix("diagnostics") { return "History" }
        if name.hasPrefix("settings") { return "Settings" }
        if name.hasPrefix("port") { return "Runtime" }
        return nil
    }

    private static func menuEntryPoint(for name: String) -> String? {
        switch name {
        case "runtime_snapshot", "service_start", "session_capture", "projects_list":
            return "Menu Bar"
        default:
            return nil
        }
    }

    private static func description(for name: String) -> String {
        switch name {
        case "operation_preview":
            return "Preview an exact destructive or high-impact domain operation without executing it."
        case "operation_execute":
            return "Execute one unexpired, unused operation preview after revalidating state, identity, and ownership."
        case "change_set_preview":
            return "Validate and order a coordinated set of DevBerth domain changes without applying it."
        case "change_set_execute":
            return "Execute one unexpired previewed change set with revision checks and compensation."
        default:
            return "Perform the DevBerth \(name.replacingOccurrences(of: "_", with: " ")) capability through the shared application control plane."
        }
    }

    private static func testReference(for category: ControlDomainCategory) -> String {
        "\(category.rawValue.split(separator: "_").map { $0.capitalized }.joined())ToolTests"
    }

    private static let responseSchema: JSONValue = objectSchema(properties: [
        "schema_version": stringSchema(description: "Tool schema version."),
        "request_id": stringSchema(description: "Request correlation identifier."),
        "snapshot_version": integerSchema(description: "Application snapshot version."),
        "generated_at": stringSchema(description: "ISO-8601 generation time."),
        "data": objectSchema(properties: [:], required: [], allowsAdditional: true),
        "warnings": arraySchema(items: objectSchema(properties: [:], required: [], allowsAdditional: true)),
        "truncated": boolSchema(description: "Whether the result was bounded."),
        "next_cursor": stringSchema(description: "Continuation cursor when truncated."),
        "error": objectSchema(properties: [
            "code": stringSchema(description: "Stable DevBerth error code."),
            "message": stringSchema(description: "Actionable non-secret error message."),
            "recovery_suggestion": stringSchema(description: "Optional safe recovery guidance."),
            "details": objectSchema(properties: [:], required: [], allowsAdditional: true)
        ], required: ["code", "message"])
    ], required: ["schema_version", "request_id", "snapshot_version", "generated_at", "warnings", "truncated"])

    private static func objectSchema(
        properties: [String: JSONValue],
        required: [String],
        allowsAdditional: Bool = false
    ) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map(JSONValue.string)),
            "additionalProperties": .bool(allowsAdditional)
        ])
    }

    private static func stringSchema(description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func integerSchema(description: String) -> JSONValue {
        .object(["type": .string("integer"), "description": .string(description), "minimum": .number(0)])
    }

    private static func boolSchema(description: String) -> JSONValue {
        .object(["type": .string("boolean"), "description": .string(description)])
    }

    private static func arraySchema(items: JSONValue) -> JSONValue {
        .object(["type": .string("array"), "items": items])
    }
}

public struct ControlResourceDefinition: Codable, Sendable, Equatable, Identifiable {
    public var id: String { uri }
    public let uri: String
    public let name: String
    public let description: String
    public let mimeType: String
    public let isTemplate: Bool

    public init(
        uri: String,
        name: String,
        description: String,
        mimeType: String = "application/json",
        isTemplate: Bool = false
    ) {
        self.uri = uri
        self.name = name
        self.description = description
        self.mimeType = mimeType
        self.isTemplate = isTemplate
    }
}

public struct ControlPromptDefinition: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let description: String
    public let developmentOnly: Bool

    public init(name: String, description: String, developmentOnly: Bool = false) {
        self.name = name
        self.description = description
        self.developmentOnly = developmentOnly
    }

    public func body(arguments: [String: String] = [:]) -> String {
        let context = arguments.isEmpty ? "" : " Inputs: \(arguments.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))."
        return "Use DevBerth domain tools, stable IDs, and current revisions. Inspect before mutation. Use operation_preview then operation_execute for destructive work, and change sets for coordinated configuration. Never use raw shell/process/Docker commands or request secret values.\(context)"
    }
}
