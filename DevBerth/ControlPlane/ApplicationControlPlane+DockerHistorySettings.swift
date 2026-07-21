import DevBerthControlContracts
import Foundation
import ServiceManagement
import SwiftData

extension ApplicationControlPlane {
    func dockerStatus() async throws -> JSONValue {
        if developmentMode, await fixtureController.isActive(name: "docker_unavailable_simulation") {
            return .object([
                "status": .string("daemon_unavailable"),
                "reason": .string("Application-owned development fixture"),
                "enabled": .bool(true), "simulated": .bool(true)
            ])
        }
        switch await model.dockerService.availability() {
        case .checking: return .object(["status": .string("checking"), "enabled": .bool(true)])
        case let .available(version): return .object(["status": .string("available"), "version": .string(version), "enabled": .bool(true)])
        case .notInstalled: return .object(["status": .string("not_installed"), "enabled": .bool(true)])
        case let .daemonUnavailable(reason): return .object(["status": .string("daemon_unavailable"), "reason": .string(reason), "enabled": .bool(true)])
        }
    }

    func dockerContainers() async throws -> JSONValue {
        try await rejectSimulatedDockerUnavailability()
        do {
            let containers = try await model.dockerService.runningContainers()
            return .object(["containers": .array(containers.map(dockerContainerValue)), "count": .number(Double(containers.count))])
        } catch {
            throw ControlFailure(code: .dockerUnavailable, message: error.localizedDescription)
        }
    }

    func dockerContainerInspect(_ arguments: JSONValue) async throws -> JSONValue {
        try await rejectSimulatedDockerUnavailability()
        let id = try requiredString("container_id", arguments)
        let containers = try await model.dockerService.runningContainers()
        guard let container = containers.first(where: { $0.id == id || $0.name == id }) else {
            throw ControlFailure(code: .entityNotFound, message: "No running Docker container matches \(id).")
        }
        var value = dockerContainerValue(container).objectValue ?? [:]
        value["recent_logs_available"] = .bool(true)
        value["available_actions"] = .array([.string("logs"), .string("stop_preview"), .string("restart_preview")])
        return .object(value)
    }

    func dockerComposeProjects() async throws -> JSONValue {
        try await rejectSimulatedDockerUnavailability()
        let containers = try await model.dockerService.runningContainers()
        let grouped = Dictionary(grouping: containers.compactMap { container -> (String, DockerContainer)? in
            container.composeProject.map { ($0, container) }
        }, by: { $0.0 })
        let projects = grouped.keys.sorted().map { name in
            let members = grouped[name]!.map(\.1)
            return JSONValue.object([
                "id": .string(name), "name": .string(name),
                "service_count": .number(Double(Set(members.compactMap(\.composeService)).count)),
                "container_ids": .array(members.map { .string($0.id) }),
                "verified_contexts": .number(Double(members.filter { $0.composeContext != nil }.count))
            ])
        }
        return .object(["projects": .array(projects)])
    }

    func dockerComposeProjectInspect(_ arguments: JSONValue) async throws -> JSONValue {
        try await rejectSimulatedDockerUnavailability()
        let id = try requiredString("compose_project_id", arguments)
        let containers = try await model.dockerService.runningContainers().filter { $0.composeProject == id }
        guard !containers.isEmpty else {
            throw ControlFailure(code: .entityNotFound, message: "No running Compose project matches \(id).")
        }
        return .object([
            "id": .string(id),
            "containers": .array(containers.map(dockerContainerValue)),
            "services": .array(Array(Set(containers.compactMap(\.composeService))).sorted().map(JSONValue.string)),
            "ports": .array(containers.flatMap(\.ports).map(dockerPortValue)),
            "contexts_verified": .bool(containers.allSatisfy { $0.composeContext != nil })
        ])
    }

    private func rejectSimulatedDockerUnavailability() async throws {
        if developmentMode, await fixtureController.isActive(name: "docker_unavailable_simulation") {
            throw ControlFailure(code: .dockerUnavailable, message: "Docker is unavailable because the development fixture is active.")
        }
    }

    func serviceLogs(_ arguments: JSONValue) async throws -> JSONValue {
        let id = try requiredUUID("service_id", arguments)
        _ = try store.service(id: id)
        let entries = await model.logBuffer.entries(for: id)
        let tail = max(1, min(arguments["tail_count"]?.intValue ?? 200, 2_000))
        let query = arguments["search"]?.stringValue?.lowercased()
        let stream = arguments["stream"]?.stringValue
        let filtered = entries.filter { entry in
            (query == nil || entry.message.lowercased().contains(query!))
                && (stream == nil || stream == "both" || entry.stream.rawValue == stream)
        }
        let selected = Array(filtered.suffix(tail))
        let maximumBytes = max(1_024, min(arguments["maximum_bytes"]?.intValue ?? 256_000, 1_000_000))
        var used = 0
        var bounded: [ServiceLogEntry] = []
        for entry in selected.reversed() {
            let size = entry.message.utf8.count
            guard used + size <= maximumBytes else { break }
            bounded.append(entry); used += size
        }
        bounded.reverse()
        return .object([
            "entries": try JSONValue.encode(bounded),
            "truncated": .bool(bounded.count < filtered.count),
            "bytes": .number(Double(used)),
            "secret_values_included": .bool(false)
        ])
    }

    func logsExport(_ arguments: JSONValue) async throws -> JSONValue {
        let id = try requiredUUID("service_id", arguments)
        let service = try store.service(id: id)
        let entries = await model.logBuffer.entries(for: id)
        let maximum = max(1, min(arguments["maximum_entries"]?.intValue ?? 2_000, 2_000))
        let text = entries.suffix(maximum).map {
            "[\($0.timestamp.ISO8601Format())] [\($0.stream.rawValue)] \($0.message)"
        }.joined(separator: "\n")
        let url = try exportURL(prefix: "logs-\(safeFilename(service.name))", extension: "log")
        try Data(text.utf8).write(to: url, options: .atomic)
        return .object(["path": .string(url.path), "entry_count": .number(Double(min(entries.count, maximum))), "redacted": .bool(true)])
    }

    func historyQuery(_ arguments: JSONValue) throws -> JSONValue {
        let limit = max(1, min(arguments["limit"]?.intValue ?? 200, 1_000))
        let query = arguments["query"]?.stringValue?.lowercased()
        let filters = arguments["filters"]?.objectValue ?? arguments.objectValue ?? [:]
        let projectID = filters["project_id"]?.stringValue.flatMap(UUID.init(uuidString:))
        let serviceID = filters["service_id"]?.stringValue.flatMap(UUID.init(uuidString:))
        let category = filters["type"]?.stringValue
        let result = filters["result"]?.stringValue
        let records = try store.context.fetch(FetchDescriptor<LifecycleEventRecord>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)]))
        let contexts = try store.context.fetch(FetchDescriptor<LifecycleEventContextRecord>())
        let contextByID = Dictionary(uniqueKeysWithValues: contexts.map { ($0.lifecycleEventID, $0) })
        let values = records.filter { record in
            let haystack = "\(record.summary) \(record.categoryRawValue) \(record.outcomeRawValue)".lowercased()
            return (query == nil || haystack.contains(query!))
                && (projectID == nil || record.projectID == projectID)
                && (serviceID == nil || record.managedServiceID == serviceID)
                && (category == nil || record.categoryRawValue == category)
                && (result == nil || record.outcomeRawValue == result)
        }.prefix(limit).map { lifecycleEventValue($0, context: contextByID[$0.id]) }
        return .object(["events": .array(Array(values)), "limit": .number(Double(limit)), "truncated": .bool(records.count > limit)])
    }

    func historyEventInspect(_ arguments: JSONValue) throws -> JSONValue {
        let id = try requiredUUID("event_id", arguments)
        let records = try store.context.fetch(FetchDescriptor<LifecycleEventRecord>())
        guard let record = records.first(where: { $0.id == id }) else {
            throw ControlFailure(code: .entityNotFound, message: "No lifecycle event exists with ID \(id.uuidString).")
        }
        let contexts = try store.context.fetch(FetchDescriptor<LifecycleEventContextRecord>())
        let context = contexts.first { $0.lifecycleEventID == id }
        var value = lifecycleEventValue(record, context: context).objectValue ?? [:]
        let relatedIDs = (try? JSONDecoder().decode([UUID].self, from: context?.relatedEventIDsData ?? Data())) ?? []
        value["related_events"] = .array(records.filter { relatedIDs.contains($0.id) }.map { related in
            lifecycleEventValue(related, context: contexts.first { $0.lifecycleEventID == related.id })
        })
        return .object(value)
    }

    func historyExport(_ arguments: JSONValue) throws -> JSONValue {
        let result = try historyQuery(arguments)
        let url = try exportURL(prefix: "history", extension: "json")
        try JSONEncoder.devBerth.encode(result).write(to: url, options: .atomic)
        return .object(["path": .string(url.path), "redacted": .bool(true)])
    }

    func diagnosticsAnalyze(_ arguments: JSONValue) throws -> JSONValue {
        let incidents = try store.context.fetch(FetchDescriptor<RuntimeIncidentSummaryRecord>(sortBy: [SortDescriptor(\.generatedAt, order: .reverse)]))
            .compactMap(\.summary)
        let serviceID = arguments["service_id"]?.stringValue.flatMap(UUID.init(uuidString:))
        let selected = incidents.filter { serviceID == nil || $0.managedServiceID == serviceID }.prefix(50)
        return .object([
            "incidents": try JSONValue.encode(Array(selected)),
            "analysis_method": .string("deterministic_lifecycle_evidence"),
            "uses_model_inference": .bool(false),
            "recommendation": selected.first.map { .string($0.suggestedAction) } ?? .string("Inspect current runtime ownership and recent lifecycle events.")
        ])
    }

    func settingsGet() -> JSONValue {
        let defaults = UserDefaults.standard
        return .object([
            "monitoring_enabled": .bool(model.isMonitoring),
            "monitoring_interval": .number(model.refreshInterval),
            "history_retention_days": .number(Double(defaults.integer(forKey: "historyRetentionDays") == 0 ? 30 : defaults.integer(forKey: "historyRetentionDays"))),
            "notify_configured_ports": .bool(defaults.bool(forKey: "notifyConfiguredPorts")),
            "launch_at_login": .bool(SMAppService.mainApp.status == .enabled),
            "docker_integration": .bool(defaults.object(forKey: "dockerIntegration") as? Bool ?? true),
            "mcp": .object([
                "enabled": .bool(true),
                "protocol_version": .string(ControlProtocolConstants.version),
                "tool_schema_version": .string(ControlProtocolConstants.toolSchemaVersion),
                "production_tool_count": .number(Double(ControlCapabilityRegistry.productionTools.count)),
                "development_tool_count": .number(Double(ControlCapabilityRegistry.developmentTools.count)),
                "development_mode": .bool(developmentMode)
            ])
        ])
    }

    func settingsUpdate(_ arguments: JSONValue) async throws -> JSONValue {
        let patch = arguments["patch"]?.objectValue ?? arguments.objectValue ?? [:]
        if patch.keys.contains("safety_disabled") || patch.keys.contains("disable_identity_checks") {
            throw ControlFailure(code: .permissionDenied, message: "Safety systems cannot be disabled through MCP.")
        }
        if let interval = patch["monitoring_interval"]?.intValue {
            guard (1...60).contains(interval) else { throw ControlFailure(code: .invalidArguments, message: "Monitoring interval must be 1 through 60 seconds.") }
            model.refreshInterval = Double(interval)
            if model.isMonitoring { model.startMonitoring() }
            UserDefaults.standard.set(Double(interval), forKey: "refreshInterval")
        }
        if let enabled = patch["monitoring_enabled"]?.boolValue {
            enabled ? model.startMonitoring() : model.pauseMonitoring()
        }
        if let days = patch["history_retention_days"]?.intValue {
            guard (1...3650).contains(days) else { throw ControlFailure(code: .invalidArguments, message: "History retention must be 1 through 3650 days.") }
            UserDefaults.standard.set(days, forKey: "historyRetentionDays")
        }
        if let notify = patch["notify_configured_ports"]?.boolValue {
            UserDefaults.standard.set(notify, forKey: "notifyConfiguredPorts")
        }
        if let docker = patch["docker_integration"]?.boolValue {
            UserDefaults.standard.set(docker, forKey: "dockerIntegration")
        }
        if let login = patch["launch_at_login"]?.boolValue {
            do {
                if login {
                    try SMAppService.mainApp.register()
                } else {
                    try await SMAppService.mainApp.unregister()
                }
            }
            catch { throw ControlFailure(code: .permissionDenied, message: error.localizedDescription, recoverySuggestion: "Change Launch at Login in DevBerth Settings.") }
        }
        mutationVersion &+= 1
        return settingsGet()
    }

    func favoritesUpdate(_ arguments: JSONValue) throws -> JSONValue {
        let kind = arguments["kind"]?.stringValue ?? "service"
        let id = try requiredString("id", arguments)
        let favorite = arguments["favorite"]?.boolValue ?? true
        if kind == "service", let uuid = UUID(uuidString: id) {
            _ = try store.service(id: uuid)
            let updated = try store.updateService(
                id: uuid,
                arguments: .object([
                    "revision": arguments["revision"] ?? .number(Double(try store.revision(kind: "service", id: uuid.uuidString))),
                    "patch": .object(["isFavorite": .bool(favorite)])
                ])
            )
            mutationVersion &+= 1
            return updated
        }
        return try genericMutation(tool: "favorites_update", kind: "favorite", arguments: arguments)
    }

    func genericMutation(tool: String, kind: String, arguments: JSONValue) throws -> JSONValue {
        let isDelete = tool.hasSuffix("_delete") || arguments["action"]?.stringValue == "delete"
        let isUpdate = tool.hasSuffix("_update") || arguments["action"]?.stringValue == "update"
        if isDelete {
            let id = try requiredUUIDForItem(arguments)
            try store.deleteItem(kind: kind, id: id, suppliedRevision: arguments["revision"]?.intValue)
            mutationVersion &+= 1
            return .object(["deleted": .string(id.uuidString), "kind": .string(kind)])
        }
        let value: JSONValue
        if isUpdate, let id = optionalUUIDForItem(arguments) {
            value = try store.updateItem(kind: kind, id: id, arguments: arguments)
        } else { value = try store.createItem(kind: kind, arguments: arguments) }
        mutationVersion &+= 1
        return value
    }

    private func dockerContainerValue(_ container: DockerContainer) -> JSONValue {
        .object([
            "id": .string(container.id), "name": .string(container.name), "image": .string(container.image),
            "state": .string(container.state), "status": .string(container.status),
            "health": container.healthStatus.map(JSONValue.string) ?? .null,
            "restart_policy": .string(container.restartPolicy),
            "ports": .array(container.ports.map(dockerPortValue)),
            "compose_project": container.composeProject.map(JSONValue.string) ?? .null,
            "compose_service": container.composeService.map(JSONValue.string) ?? .null,
            "compose_context": container.composeContext.flatMap { try? JSONValue.encode($0) } ?? .null,
            "compose_context_issue": container.composeContextIssue.map(JSONValue.string) ?? .null
        ])
    }

    private func dockerPortValue(_ port: DockerPortMapping) -> JSONValue {
        .object([
            "host_address": .string(port.hostAddress), "host_port": .number(Double(port.hostPort)),
            "container_port": .number(Double(port.containerPort)), "protocol": .string(port.protocolKind.rawValue)
        ])
    }

    private func lifecycleEventValue(_ record: LifecycleEventRecord, context: LifecycleEventContextRecord?) -> JSONValue {
        .object([
            "id": .string(record.id.uuidString), "timestamp": .string(record.timestamp.ISO8601Format()),
            "runtime_id": record.runtimeID.map { .string($0.uuidString) } ?? .null,
            "service_id": record.managedServiceID.map { .string($0.uuidString) } ?? .null,
            "project_id": record.projectID.map { .string($0.uuidString) } ?? .null,
            "session_id": record.sessionID.map { .string($0.uuidString) } ?? .null,
            "category": .string(record.categoryRawValue), "outcome": .string(record.outcomeRawValue),
            "severity": context.map { .string($0.severityRawValue) } ?? .null,
            "source": context.map { .string($0.sourceRawValue) } ?? .null,
            "trigger": context.map { .string($0.triggerRawValue) } ?? .null,
            "summary": .string(record.summary),
            "details": (try? JSONDecoder.devBerth.decode(JSONValue.self, from: record.detailsData)) ?? .object([:]),
            "listener_id": context?.listenerID.map(JSONValue.string) ?? .null,
            "duration_seconds": context?.durationSeconds.map(JSONValue.number) ?? .null
        ])
    }

    private func optionalUUIDForItem(_ arguments: JSONValue) -> UUID? {
        let values = arguments.objectValue ?? [:]
        return ["id", "port_id", "filter_id", "tag_id", "runtime_id"].compactMap { values[$0]?.stringValue.flatMap(UUID.init(uuidString:)) }.first
    }

    private func requiredUUIDForItem(_ arguments: JSONValue) throws -> UUID {
        guard let id = optionalUUIDForItem(arguments) else {
            throw ControlFailure(code: .invalidArguments, message: "A stable item ID is required.")
        }
        return id
    }
}
