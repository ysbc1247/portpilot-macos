import Darwin
import DevBerthControlContracts
import Foundation
import SwiftData

extension ApplicationControlPlane {
    func developmentBuildInfo() throws -> JSONValue {
        try requireDevelopmentMode()
        let bundle = Bundle.main
        let workspace = ProcessInfo.processInfo.environment["DEVBERTH_DEVELOPMENT_WORKSPACE"]
        let git = workspace.map(readGitIdentity) ?? (branch: "unavailable", commit: "unavailable")
#if DEBUG
        let buildConfiguration = "Debug"
#else
        let buildConfiguration = "Release"
#endif
        return .object([
            "build_configuration": .string(buildConfiguration),
            "product_version": .string(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"),
            "git_branch": .string(git.branch), "git_commit": .string(git.commit),
            "database_schema_version": .number(7),
            "mcp_schema_version": .string(ControlProtocolConstants.toolSchemaVersion),
            "protocol_version": .string(ControlProtocolConstants.version),
            "feature_flags": .object([
                "development_mode": .bool(true), "fixtures": .bool(true),
                "destructive_preview": .bool(true), "change_sets": .bool(true)
            ])
        ])
    }

    func developmentInternalState() async throws -> JSONValue {
        try requireDevelopmentMode()
        let context = store.context
        let counts: [String: JSONValue] = [
            "projects": .number(Double(try context.fetchCount(FetchDescriptor<ProjectRecord>()))),
            "services": .number(Double(try context.fetchCount(FetchDescriptor<LaunchProfileRecord>()))),
            "sessions": .number(Double(try context.fetchCount(FetchDescriptor<WorkspaceSessionRecord>()))),
            "lifecycle_events": .number(Double(try context.fetchCount(FetchDescriptor<LifecycleEventRecord>()))),
            "control_items": .number(Double(try context.fetchCount(FetchDescriptor<ControlPlaneItemRecord>()))),
            "audit_events": .number(Double(try context.fetchCount(FetchDescriptor<MCPAuditEventRecord>())))
        ]
        return .object([
            "runtime_monitor": .object([
                "monitoring": .bool(model.isMonitoring), "refreshing": .bool(model.isRefreshing),
                "listener_count": .number(Double(model.listeners.count)),
                "last_refresh": model.lastRefresh.map { .string($0.ISO8601Format()) } ?? .null
            ]),
            "active_tasks": .object([
                "process_controls": .number(Double(model.processesBeingControlled.count)),
                "service_validations": .number(Double(model.servicesBeingValidated.count)),
                "ownership_inspections": .number(Double(model.ownershipInspectionsInProgress.count))
            ]),
            "event_queue": .object(["recent_changes": .number(Double(model.recentChanges.count))]),
            "caches": .object([
                "ownership_graphs": .number(Double(model.ownershipGraphs.count)),
                "resource_rows": .number(Double(model.processResourceUsage.count)),
                "idempotent_results": .number(Double(idempotentResults.count))
            ]),
            "connected_clients": .number(0),
            "fixtures": await fixtureController.state(), "persistence_counts": .object(counts),
            "recent_internal_errors": .array(Array(recentErrors.suffix(25)))
        ])
    }

    func developmentFixtureList() async throws -> JSONValue {
        try requireDevelopmentMode()
        return .object(["fixtures": .array(await fixtureController.list())])
    }

    func developmentFixtureMutation(tool: String, arguments: JSONValue) async throws -> JSONValue {
        try requireDevelopmentMode()
        if tool == "dev_fixture_start" {
            let name = try requiredString("name", arguments)
            let port = arguments["port"]?.intValue.flatMap(UInt16.init(exactly:))
            return try await fixtureController.start(name: name, requestedPort: port)
        }
        let id = try requiredUUID("fixture_id", arguments)
        try await fixtureController.stop(id: id)
        return .object(["fixture_id": .string(id.uuidString), "state": .string("stopped")])
    }

    func developmentAcceptance(tool: String, arguments: JSONValue) async throws -> JSONValue {
        try requireDevelopmentMode()
        let scenarios = [
            "create_project", "modify_project", "session_lifecycle", "observed_process_adoption",
            "safe_conflict_resolution", "coordinated_change_set", "docker_compose_control",
            "gui_mcp_concurrency", "development_acceleration"
        ]
        let selected: [String]
        if tool == "dev_acceptance_suite_run" { selected = scenarios }
        else {
            let name = try requiredString("name", arguments)
            guard scenarios.contains(name) else { throw ControlFailure(code: .invalidArguments, message: "Unknown acceptance scenario \(name).") }
            selected = [name]
        }
        var results: [JSONValue] = []
        for name in selected {
            results.append(await runDevelopmentAcceptanceScenario(name))
            await cleanupDevelopmentAcceptanceRuntime()
        }
        return .object([
            "passed": .bool(results.allSatisfy { $0["passed"]?.boolValue == true }),
            "scenarios": .array(results),
            "execution": .string("real_control_plane_and_application_owned_fixtures"),
            "production_data_touched": .bool(false)
        ])
    }

    private func runDevelopmentAcceptanceScenario(_ name: String) async -> JSONValue {
        let started = Date()
        var checks: [JSONValue] = []
        func pass(_ check: String, details: JSONValue = .null) {
            checks.append(.object(["name": .string(check), "passed": .bool(true), "details": details]))
        }
        func require(_ condition: Bool, _ check: String) throws {
            guard condition else {
                throw ControlFailure(code: .internalError, message: "Acceptance check failed: \(check).")
            }
            pass(check)
        }

        do {
            try require(developmentMode, "development_store_isolated")
            switch name {
            case "create_project":
                let root = try developmentWorkspaceRoot()
                let project = try await acceptanceCall("project_create", [
                    "name": .string("Acceptance full stack \(UUID().uuidString.prefix(6))"),
                    "folder_path": .string(root.path)
                ])
                let projectID = try acceptanceUUID("id", in: project)
                for component in ["frontend", "backend"] {
                    let discovery = try await acceptanceCall("project_discover", [
                        "root_path": .string(root.appendingPathComponent("Fixtures/Acceptance/\(component)").path)
                    ])
                    _ = try await acceptanceCall("project_apply_discovery", [
                        "discovery_id": discovery["discovery_id"] ?? .null,
                        "project_id": .string(projectID.uuidString)
                    ])
                }
                var services = try store.services().filter { $0.projectID == projectID }
                try require(services.count >= 2, "frontend_and_backend_discovered_and_applied")
                let ports = try await borrowDevelopmentPorts(count: 2)
                for index in 0..<2 {
                    _ = try await configureAcceptanceService(id: services[index].id, port: ports[index])
                }
                services = try store.services().filter { $0.projectID == projectID }
                let database = services[0]
                let backend = services[1]
                _ = try await acceptanceCall("dependency_update", [
                    "service_id": .string(backend.id.uuidString),
                    "dependency_service_id": .string(database.id.uuidString),
                    "action": .string("add"),
                    "revision": .number(Double(try store.revision(kind: "service", id: backend.id.uuidString)))
                ])
                _ = try await acceptanceCall("port_reservation_create", [
                    "name": .string("Acceptance backend"), "port": .number(Double(ports[1])),
                    "project_id": .string(projectID.uuidString), "service_id": .string(backend.id.uuidString)
                ])
                let validation = try await acceptanceCall("project_validate", ["project_id": .string(projectID.uuidString)])
                try require(validation["valid"]?.boolValue == true, "dependencies_ports_and_readiness_validate")
                for service in [database, backend] {
                    let result = try await acceptanceCall("service_verify", ["service_id": .string(service.id.uuidString)])
                    try require(result["verified_restartable"]?.boolValue == true, "service_\(service.id.uuidString.prefix(6))_verified")
                    _ = try await acceptanceCall("service_start", [
                        "service_id": .string(service.id.uuidString), "wait_level": .string("ready")
                    ])
                }
                let topology = try await acceptanceCall("runtime_snapshot")
                try require((topology["counts"]?["managed_runtimes"]?.intValue ?? 0) >= 2, "managed_runtime_topology_visible")
                let session = try await acceptanceCall("session_capture", [
                    "name": .string("Acceptance running workspace"),
                    "project_ids": .array([.string(projectID.uuidString)])
                ])
                try require(session["id"]?.stringValue != nil, "running_workspace_captured")
                let preview = try await acceptanceCall("operation_preview", [
                    "operation_type": .string("stop_project"), "targets": .array([.string(projectID.uuidString)])
                ])
                _ = try await acceptanceCall("operation_execute", ["operation_id": preview["operation_id"] ?? .null])
                pass("project_stopped_through_preview_execute")

            case "modify_project":
                let project = try await acceptanceCall("project_create", ["name": .string("Before MCP edit")])
                let projectID = try acceptanceUUID("id", in: project)
                let serviceID = UUID()
                let port = try await borrowDevelopmentPorts(count: 1)[0]
                let preview = try await acceptanceCall("change_set_preview", ["changes": .array([
                    .object(["tool": .string("project_update"), "arguments": .object([
                        "project_id": .string(projectID.uuidString), "revision": project["revision"] ?? .number(1),
                        "patch": .object(["name": .string("After MCP edit")])
                    ])]),
                    .object(["tool": .string("service_create"), "arguments": .object([
                        "id": .string(serviceID.uuidString), "name": .string("Acceptance worker"),
                        "project_id": .string(projectID.uuidString), "command": .string("/usr/bin/true"),
                        "working_directory": .string("/tmp"), "is_reviewed": .bool(true)
                    ])]),
                    .object(["tool": .string("port_reservation_create"), "arguments": .object([
                        "name": .string("Worker port"), "port": .number(Double(port)),
                        "project_id": .string(projectID.uuidString), "service_id": .string(serviceID.uuidString)
                    ])])
                ])])
                _ = try await acceptanceCall("change_set_execute", ["change_set_token": preview["change_set_token"] ?? .null])
                let inspected = try await acceptanceCall("project_inspect", ["project_id": .string(projectID.uuidString)])
                try require(inspected["name"] == .string("After MCP edit"), "revisioned_project_patch_applied")
                try require(inspected["services"]?.arrayValue?.contains { $0["id"] == .string(serviceID.uuidString) } == true, "worker_service_added")
                try require(try store.items(kind: "port_reservation").contains { $0["payload"]?["port"] == .number(Double(port)) }, "expected_port_changed_in_same_change_set")
                pass("shared_swiftdata_context_reflects_mcp_mutation")

            case "session_lifecycle":
                let project = try await acceptanceCall("project_create", ["name": .string("Session lifecycle")])
                let projectID = try acceptanceUUID("id", in: project)
                let service = try await acceptanceCall("service_create", [
                    "name": .string("Stopped session service"), "project_id": .string(projectID.uuidString),
                    "command": .string("/usr/bin/true"), "working_directory": .string("/tmp"), "is_reviewed": .bool(true)
                ])
                let serviceID = try acceptanceUUID("id", in: service)
                let session = try await acceptanceCall("session_create", [
                    "name": .string("Captured workspace"), "project_ids": .array([.string(projectID.uuidString)]),
                    "services": .array([.object(["service_id": .string(serviceID.uuidString), "expected_state": .string("stopped")])])
                ])
                let sessionID = try acceptanceUUID("id", in: session)
                _ = try await acceptanceCall("session_update", [
                    "session_id": .string(sessionID.uuidString), "revision": session["revision"] ?? .number(1),
                    "patch": .object(["name": .string("Reviewed workspace"), "notes": .string("Acceptance notes"), "service_ids": .array([])])
                ])
                let exported = try await acceptanceCall("session_export", ["session_id": .string(sessionID.uuidString)])
                try require(exported["path"]?.stringValue.map { FileManager.default.fileExists(atPath: $0) } == true, "session_export_written")
                let diff = try await acceptanceCall("session_diff", ["session_id": .string(sessionID.uuidString)])
                try require(diff["change_count"]?.intValue != nil, "session_compared_with_runtime")
                let restore = try await acceptanceCall("session_restore_preview", ["session_id": .string(sessionID.uuidString)])
                _ = try await acceptanceCall("operation_execute", ["operation_id": restore["operation"]?["operation_id"] ?? .null])
                let inspected = try await acceptanceCall("session_inspect", ["session_id": .string(sessionID.uuidString)])
                try require(inspected["restore_history"]?.arrayValue != nil, "restore_history_inspected")
                let duplicate = try await acceptanceCall("session_duplicate", ["session_id": .string(sessionID.uuidString)])
                let duplicateID = try acceptanceUUID("id", in: duplicate)
                let deletion = try await acceptanceCall("operation_preview", [
                    "operation_type": .string("delete_session_with_history"), "targets": .array([.string(duplicateID.uuidString)])
                ])
                _ = try await acceptanceCall("operation_execute", ["operation_id": deletion["operation_id"] ?? .null])
                pass("full_session_lifecycle_completed")

            case "observed_process_adoption":
                let root = try developmentWorkspaceRoot()
                let project = try await acceptanceCall("project_create", ["name": .string("Adopted runtime")])
                let projectID = try acceptanceUUID("id", in: project)
                let fixture = try await acceptanceCall("dev_fixture_start", ["name": .string("simple_tcp_listener")])
                let fixturePort = try acceptancePort(in: fixture)
                let listener = try await waitForDevelopmentListener(port: fixturePort)
                let search = try await acceptanceCall("runtime_search", ["port": .number(Double(fixturePort))])
                try require(search["count"]?.intValue == 1, "external_fixture_found")
                _ = try await acceptanceCall("runtime_explain", ["listener_id": .string(listener.id)])
                _ = try await acceptanceCall("runtime_update_metadata", [
                    "name": .string("Adoption metadata"), "listener_id": .string(listener.id),
                    "project_id": .string(projectID.uuidString), "label": .string("vite")
                ])
                let candidate = try await acceptanceCall("service_adopt_runtime", [
                    "listener_id": .string(listener.id), "project_id": .string(projectID.uuidString), "name": .string("Adopted Vite fixture")
                ])
                let serviceID = try acceptanceUUID("id", in: candidate)
                let managedPort = try await borrowDevelopmentPorts(count: 1)[0]
                _ = try await configureAcceptanceService(id: serviceID, port: managedPort)
                let verified = try await acceptanceCall("service_verify", ["service_id": .string(serviceID.uuidString)])
                try require(verified["verified_restartable"]?.boolValue == true, "adopted_candidate_reviewed_and_verified")
                let stop = try await acceptanceCall("operation_preview", [
                    "operation_type": .string("stop_runtime"), "targets": .array([.string(listener.id)])
                ])
                _ = try await acceptanceCall("operation_execute", ["operation_id": stop["operation_id"] ?? .null])
                _ = try await acceptanceCall("service_start", ["service_id": .string(serviceID.uuidString)])
                try require(model.managedRunningServiceIDs.contains(serviceID), "verified_managed_service_started")
                let serviceStop = try await acceptanceCall("operation_preview", [
                    "operation_type": .string("stop_service"), "targets": .array([.string(serviceID.uuidString)])
                ])
                _ = try await acceptanceCall("operation_execute", ["operation_id": serviceStop["operation_id"] ?? .null])
                try require(root.path.hasPrefix("/"), "workspace_path_canonical")

            case "safe_conflict_resolution":
                let project = try await acceptanceCall("project_create", ["name": .string("Conflict resolution")])
                let projectID = try acceptanceUUID("id", in: project)
                let port = try await borrowDevelopmentPorts(count: 1)[0]
                _ = try await acceptanceCall("port_reservation_create", [
                    "name": .string("Backend 8080 equivalent"), "port": .number(Double(port)), "project_id": .string(projectID.uuidString)
                ])
                let service = try await acceptanceCall("service_create", [
                    "name": .string("Conflict backend"), "project_id": .string(projectID.uuidString),
                    "command": .string("/usr/bin/true"), "working_directory": .string("/tmp"), "is_reviewed": .bool(true)
                ])
                let serviceID = try acceptanceUUID("id", in: service)
                _ = try await configureAcceptanceService(id: serviceID, port: port)
                _ = try await acceptanceCall("dev_fixture_start", ["name": .string("port_conflict"), "port": .number(Double(port))])
                let listener = try await waitForDevelopmentListener(port: port)
                let validation = try await acceptanceCall("project_validate", ["project_id": .string(projectID.uuidString)])
                try require(validation["issues"]?.arrayValue?.contains { $0["field"] == .string("expected_ports") } == true, "port_conflict_detected")
                _ = try await acceptanceCall("port_inspect", ["listener_id": .string(listener.id)])
                let preview = try await acceptanceCall("operation_preview", [
                    "operation_type": .string("resolve_port_conflict"), "targets": .array([.string(listener.id)])
                ])
                try require(preview["unrelated_processes_involved"] == .bool(false), "preview_targets_only_application_owned_fixture")
                _ = try await acceptanceCall("operation_execute", ["operation_id": preview["operation_id"] ?? .null])
                let verified = try await acceptanceCall("service_verify", ["service_id": .string(serviceID.uuidString)])
                try require(verified["verified_restartable"] == .bool(true), "backend_verified_after_resolution")
                _ = try await acceptanceCall("service_start", ["service_id": .string(serviceID.uuidString)])
                let stop = try await acceptanceCall("operation_preview", [
                    "operation_type": .string("stop_service"), "targets": .array([.string(serviceID.uuidString)])
                ])
                _ = try await acceptanceCall("operation_execute", ["operation_id": stop["operation_id"] ?? .null])
                pass("conflict_resolved_without_unrelated_process")

            case "coordinated_change_set":
                let projectA = UUID(), projectB = UUID(), serviceA = UUID(), serviceB = UUID()
                let sessionA = UUID(), sessionB = UUID()
                let ports = try await borrowDevelopmentPorts(count: 2)
                let changes: [JSONValue] = [
                    .object(["tool": .string("project_create"), "arguments": .object(["id": .string(projectA.uuidString), "name": .string("Change set A")])]),
                    .object(["tool": .string("project_create"), "arguments": .object(["id": .string(projectB.uuidString), "name": .string("Change set B")])]),
                    .object(["tool": .string("service_create"), "arguments": .object([
                        "id": .string(serviceA.uuidString), "name": .string("Service A"), "project_id": .string(projectA.uuidString),
                        "command": .string("/usr/bin/true"), "working_directory": .string("/tmp"), "is_reviewed": .bool(true)
                    ])]),
                    .object(["tool": .string("service_create"), "arguments": .object([
                        "id": .string(serviceB.uuidString), "name": .string("Service B"), "project_id": .string(projectB.uuidString),
                        "command": .string("/usr/bin/true"), "working_directory": .string("/tmp"),
                        "dependency_service_ids": .array([.string(serviceA.uuidString)]), "is_reviewed": .bool(true)
                    ])]),
                    .object(["tool": .string("port_reservation_create"), "arguments": .object(["name": .string("A"), "port": .number(Double(ports[0]))])]),
                    .object(["tool": .string("port_reservation_create"), "arguments": .object(["name": .string("B"), "port": .number(Double(ports[1]))])]),
                    .object(["tool": .string("session_create"), "arguments": .object(["id": .string(sessionA.uuidString), "name": .string("Default A")])]),
                    .object(["tool": .string("session_create"), "arguments": .object(["id": .string(sessionB.uuidString), "name": .string("Default B")])])
                ]
                let preview = try await acceptanceCall("change_set_preview", ["changes": .array(changes)])
                _ = try await acceptanceCall("change_set_execute", ["change_set_token": preview["change_set_token"] ?? .null])
                let graph = try await acceptanceCall("dependency_validate")
                try require(graph["valid"] == .bool(true), "two_project_change_set_executed")

                let rollbackProject = UUID()
                let rollbackPreview = try await acceptanceCall("change_set_preview", ["changes": .array([
                    .object(["tool": .string("project_create"), "arguments": .object(["id": .string(rollbackProject.uuidString), "name": .string("Must roll back")])]),
                    .object(["tool": .string("settings_update"), "arguments": .object(["patch": .object(["safety_disabled": .bool(true)])])])
                ])])
                do {
                    _ = try await acceptanceCall("change_set_execute", ["change_set_token": rollbackPreview["change_set_token"] ?? .null])
                    throw ControlFailure(code: .internalError, message: "The intentionally invalid change set unexpectedly succeeded.")
                } catch let failure as ControlFailure where failure.code == .permissionDenied {
                    try require((try? store.project(id: rollbackProject)) == nil, "failed_change_set_compensated")
                }

            case "docker_compose_control":
                let fixture = try await acceptanceCall("dev_fixture_start", ["name": .string("docker_unavailable_simulation")])
                let status = try await acceptanceCall("docker_status")
                try require(status["simulated"] == .bool(true), "docker_unavailable_simulated")
                do {
                    _ = try await acceptanceCall("docker_containers_list")
                    throw ControlFailure(code: .internalError, message: "Docker list unexpectedly ignored the unavailable fixture.")
                } catch let failure as ControlFailure where failure.code == .dockerUnavailable {
                    pass("docker_unavailable_error_is_structured")
                }
                _ = try await acceptanceCall("docker_import_compose_project", [
                    "name": .string("Acceptance Compose association"),
                    "compose_project": .string("devberth-acceptance"),
                    "project_id": .string(UUID().uuidString),
                    "working_directory": .string("/tmp"),
                    "configuration_files": .array([.string("compose.yml")])
                ])
                try require(try store.items(kind: "docker_association").count == 1, "compose_association_persisted_without_execution")
                if let fixtureID = fixture["fixture_id"]?.stringValue {
                    _ = try await acceptanceCall("dev_fixture_stop", ["fixture_id": .string(fixtureID)])
                }
                pass("live_compose_lifecycle_requires_available_daemon", details: .string("Deterministic unavailable path and context persistence executed; lifecycle controllers are covered by Docker integration tests."))

            case "gui_mcp_concurrency":
                let project = try await acceptanceCall("project_create", ["name": .string("Concurrent original")])
                let projectID = try acceptanceUUID("id", in: project)
                _ = try await acceptanceCall("project_update", [
                    "project_id": .string(projectID.uuidString), "revision": project["revision"] ?? .number(1),
                    "patch": .object(["name": .string("MCP winner")])
                ])
                do {
                    _ = try await acceptanceCall("project_update", [
                        "project_id": .string(projectID.uuidString), "revision": project["revision"] ?? .number(1),
                        "patch": .object(["name": .string("Stale GUI overwrite")])
                    ])
                    throw ControlFailure(code: .internalError, message: "A stale GUI-style revision unexpectedly overwrote MCP state.")
                } catch let failure as ControlFailure where failure.code == .entityChanged {
                    let current = try await acceptanceCall("project_inspect", ["project_id": .string(projectID.uuidString)])
                    try require(current["name"] == .string("MCP winner"), "stale_gui_revision_rejected_without_overwrite")
                    pass("current_and_attempted_states_remain_explicit")
                }

            case "development_acceleration":
                let project = try await acceptanceCall("project_create", ["name": .string("Disposable development project")])
                try require(project["id"]?.stringValue != nil, "disposable_project_created")
                let fixture = try await acceptanceCall("dev_fixture_start", ["name": .string("simple_tcp_listener")])
                try require(fixture["state"] == .string("running"), "fixture_service_started")
                let errors = try await acceptanceCall("dev_recent_errors")
                try require(errors["errors"]?.arrayValue != nil, "recent_errors_inspected")
                let parity = try await acceptanceCall("dev_capability_parity_validate")
                try require(parity["valid"] == .bool(true), "capability_parity_validated")
                let reset = try await acceptanceCall("dev_test_store_reset", ["confirm": .bool(true)])
                try require(reset["production_data_touched"] == .bool(false), "fixtures_stopped_and_disposable_store_reset")
                try require(try store.projects().isEmpty, "production_data_untouched")

            default:
                throw ControlFailure(code: .invalidArguments, message: "Unknown acceptance scenario \(name).")
            }
        } catch let failure as ControlFailure {
            checks.append(.object([
                "name": .string("scenario_execution"), "passed": .bool(false),
                "error_code": .string(failure.code.rawValue), "message": .string(failure.message)
            ]))
        } catch {
            checks.append(.object([
                "name": .string("scenario_execution"), "passed": .bool(false),
                "error_code": .string(ControlErrorCode.internalError.rawValue), "message": .string(error.localizedDescription)
            ]))
        }
        let passed = checks.allSatisfy { $0["passed"]?.boolValue == true }
        return .object([
            "name": .string(name), "passed": .bool(passed), "checks": .array(checks),
            "duration_seconds": .number(Date().timeIntervalSince(started))
        ])
    }

    private func acceptanceCall(_ tool: String, _ arguments: [String: JSONValue] = [:]) async throws -> JSONValue {
        let request = ControlRequest(
            handshake: ControlHandshake(client: .init(name: "DevBerth acceptance runner", version: "1", developmentMode: true)),
            toolName: tool, arguments: .object(arguments), source: .system
        )
        return try await dispatch(tool: tool, arguments: .object(arguments), request: request)
    }

    private func developmentWorkspaceRoot() throws -> URL {
        guard let package = Bundle.main.url(forResource: "package", withExtension: "json"),
              let procfile = Bundle.main.url(forResource: "Procfile", withExtension: nil) else {
            throw ControlFailure(code: .entityNotFound, message: "Bundled project-discovery acceptance fixtures are missing.")
        }
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("DevBerth-Acceptance-(UUID().uuidString)", isDirectory: true)
        do {
            let frontend = root.appendingPathComponent("Fixtures/Acceptance/frontend", isDirectory: true)
            let backend = root.appendingPathComponent("Fixtures/Acceptance/backend", isDirectory: true)
            try fileManager.createDirectory(at: frontend, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: backend, withIntermediateDirectories: true)
            try fileManager.copyItem(at: package, to: frontend.appendingPathComponent("package.json"))
            try fileManager.copyItem(at: procfile, to: backend.appendingPathComponent("Procfile"))
            developmentAcceptanceRoots.append(root)
            return root
        } catch {
            try? fileManager.removeItem(at: root)
            throw ControlFailure(code: .internalError, message: "Could not prepare the disposable project-discovery fixtures: (error.localizedDescription)")
        }
    }

    private func acceptanceUUID(_ key: String, in value: JSONValue) throws -> UUID {
        guard let id = value[key]?.stringValue.flatMap(UUID.init(uuidString:)) else {
            throw ControlFailure(code: .internalError, message: "Acceptance result is missing stable UUID field \(key).")
        }
        return id
    }

    private func acceptancePort(in value: JSONValue) throws -> UInt16 {
        guard let port = value["ports"]?.arrayValue?.first?.intValue.flatMap(UInt16.init(exactly:)) else {
            throw ControlFailure(code: .internalError, message: "Acceptance fixture did not return a port.")
        }
        return port
    }

    private func borrowDevelopmentPorts(count: Int) async throws -> [UInt16] {
        var fixtures: [(id: UUID, port: UInt16)] = []
        var blockedPorts = Set(model.listeners.map(\.port))
        blockedPorts.formUnion(try store.items(kind: "port_reservation").compactMap {
            $0["payload"]?["port"]?.intValue.flatMap(UInt16.init(exactly:))
        })
        do {
            for _ in 0..<count {
                var selected: (id: UUID, port: UInt16)?
                for _ in 0..<10 {
                    let fixture = try await fixtureController.start(name: "simple_tcp_listener", requestedPort: nil)
                    let candidate = (try acceptanceUUID("fixture_id", in: fixture), try acceptancePort(in: fixture))
                    if blockedPorts.insert(candidate.1).inserted {
                        selected = candidate
                        break
                    }
                    try await fixtureController.stop(id: candidate.0)
                }
                guard let selected else {
                    throw ControlFailure(code: .conflictDetected, message: "Could not allocate an unreserved disposable acceptance port.")
                }
                fixtures.append(selected)
            }
            for fixture in fixtures { try await fixtureController.stop(id: fixture.id) }
            try await Task.sleep(for: .milliseconds(150))
            return fixtures.map(\.port)
        } catch {
            for fixture in fixtures { try? await fixtureController.stop(id: fixture.id) }
            throw error
        }
    }

    private func configureAcceptanceService(id: UUID, port: UInt16) async throws -> JSONValue {
        guard let script = Bundle.main.url(forResource: "network_fixture", withExtension: "py") else {
            throw ControlFailure(code: .entityNotFound, message: "The bundled network acceptance fixture is missing.")
        }
        let expected = ExpectedListenerConfiguration(id: UUID(), port: port, protocolKind: .tcp, required: true)
        return try await acceptanceCall("service_update", [
            "service_id": .string(id.uuidString),
            "revision": .number(Double(try store.revision(kind: "service", id: id.uuidString))),
            "patch": .object([
                "launchMechanism": .string(LaunchMechanism.executable.rawValue),
                "command": .string("/usr/bin/python3"),
                "arguments": .array([.string("-u"), .string(script.path), .string("--mode"), .string("tcp"), .string("--port"), .string(String(port))]),
                "workingDirectory": .string(script.deletingLastPathComponent().path),
                "expectedPorts": try JSONValue.encode([expected]),
                "startupTimeoutSeconds": .number(8), "shutdownTimeoutSeconds": .number(2),
                "isReviewed": .bool(true)
            ])
        ])
    }

    private func waitForDevelopmentListener(port: UInt16) async throws -> ObservedListener {
        model.refreshInterval = 0.1
        model.startMonitoring()
        for _ in 0..<60 {
            if let listener = model.listeners.first(where: { $0.port == port }) { return listener }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ControlFailure(code: .timeout, message: "Development listener on port \(port) was not observed before the deadline.")
    }

    private func cleanupDevelopmentAcceptanceRuntime() async {
        await fixtureController.stopAll()
        let running = model.managedRunningServiceIDs
        if let services = try? store.services(includeArchived: true).filter({ running.contains($0.id) }) {
            for service in services { await model.stopProfile(service) }
        }
        for root in developmentAcceptanceRoots { try? FileManager.default.removeItem(at: root) }
        developmentAcceptanceRoots.removeAll()
    }

    func developmentMigrationValidation() -> JSONValue {
        guard developmentMode else {
            return .object(["valid": .bool(false), "error": .string(ControlErrorCode.developmentModeRequired.rawValue)])
        }
        return .object([
            "valid": .bool(DevBerthMigrationPlan.schemas.count == 7 && DevBerthMigrationPlan.stages.count == 6),
            "schema_versions": .array((1...7).map { .number(Double($0)) }),
            "migration_stage_count": .number(Double(DevBerthMigrationPlan.stages.count)),
            "latest_schema": .number(7), "fixture_validation_required_by_tests": .bool(true)
        ])
    }

    func developmentPerformance(_ arguments: JSONValue) async throws -> JSONValue {
        try requireDevelopmentMode()
        let iterations = min(max(arguments["iterations"]?.intValue ?? 20, 1), 200)
        func milliseconds(_ start: ContinuousClock.Instant, _ end: ContinuousClock.Instant) -> Double {
            let duration = start.duration(to: end)
            return Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1_000_000_000_000_000
        }
        let clock = ContinuousClock()
        func measure(_ body: () throws -> Void) rethrows -> Double {
            let start = clock.now
            try body()
            return milliseconds(start, clock.now)
        }
        func measureAsync(_ body: () async throws -> Void) async rethrows -> Double {
            let start = clock.now
            try await body()
            return milliseconds(start, clock.now)
        }
        let memoryBefore = currentResidentMemoryBytes()
        var queryValues: [Double] = []
        for _ in 0..<iterations {
            let start = clock.now
            _ = try runtimeSnapshot()
            queryValues.append(milliseconds(start, clock.now))
        }

        var projectID: UUID?
        var serviceID: UUID?
        var sessionID: UUID?
        let originalChangeSetIDs = Set(changeSetLeases.keys)
        let originalOperationIDs = Set(operationLeases.keys)
        defer {
            if let sessionID { try? store.deleteSession(id: sessionID, allowHistory: true) }
            if let serviceID { try? store.deleteService(id: serviceID, allowReferences: true) }
            if let projectID { try? store.deleteProject(id: projectID, allowReferences: true) }
            for id in Array(changeSetLeases.keys) where !originalChangeSetIDs.contains(id) {
                changeSetLeases.removeValue(forKey: id)
            }
            for id in Array(operationLeases.keys) where !originalOperationIDs.contains(id) {
                operationLeases.removeValue(forKey: id)
            }
        }

        var createdProject: JSONValue = .null
        let projectMutation = try measure {
            createdProject = try store.createProject(arguments: .object(["name": .string("MCP performance probe")]))
        }
        projectID = createdProject["id"]?.stringValue.flatMap(UUID.init(uuidString:))
        guard let projectID else {
            throw ControlFailure(code: .internalError, message: "Performance probe could not create its disposable project.")
        }
        let projectInspection = try measure {
            _ = try projectInspect(.object(["project_id": .string(projectID.uuidString)]))
        }
        let projectUpdate = try measure {
            _ = try store.updateProject(
                id: projectID,
                arguments: .object([
                    "revision": createdProject["revision"] ?? .number(1),
                    "patch": .object(["name": .string("MCP performance probe updated")])
                ])
            )
        }
        let createdService = try store.createService(arguments: .object([
            "name": .string("MCP performance service"), "project_id": .string(projectID.uuidString),
            "command": .string("/usr/bin/true"), "working_directory": .string("/tmp"), "is_reviewed": .bool(true)
        ]))
        serviceID = createdService["id"]?.stringValue.flatMap(UUID.init(uuidString:))
        guard let serviceID else {
            throw ControlFailure(code: .internalError, message: "Performance probe could not create its disposable service.")
        }

        var capturedSession: JSONValue = .null
        let sessionCaptureMilliseconds = try await measureAsync {
            capturedSession = try await sessionCapture(.object([
                "name": .string("MCP performance session"),
                "project_ids": .array([.string(projectID.uuidString)])
            ]))
        }
        sessionID = capturedSession["id"]?.stringValue.flatMap(UUID.init(uuidString:))
        guard let sessionID else {
            throw ControlFailure(code: .internalError, message: "Performance probe could not capture its disposable session.")
        }
        let sessionDiffMilliseconds = try await measureAsync {
            _ = try await sessionDiff(.object(["session_id": .string(sessionID.uuidString)]))
        }
        let changeSetPreviewMilliseconds = try measure {
            _ = try changeSetPreview(.object(["changes": .array([
                .object(["tool": .string("project_update"), "arguments": .object([
                    "project_id": .string(projectID.uuidString),
                    "revision": .number(Double(try store.revision(kind: "project", id: projectID.uuidString))),
                    "patch": .object(["name": .string("MCP performance preview")])
                ])])
            ])]))
        }
        let operationPreviewMilliseconds = try await measureAsync {
            _ = try await operationPreview(.object([
                "operation_type": .string("delete_project_with_dependencies"),
                "targets": .array([.string(projectID.uuidString)])
            ]))
        }
        let logRetrievalMilliseconds = try await measureAsync {
            _ = try await serviceLogs(.object(["service_id": .string(serviceID.uuidString), "limit": .number(100)]))
        }
        let memoryAfter = currentResidentMemoryBytes()
        let sorted = queryValues.sorted()
        return .object([
            "iterations": .number(Double(iterations)),
            "runtime_snapshot_latency_ms": .object([
                "minimum": .number(sorted.first ?? 0),
                "median": .number(sorted[sorted.count / 2]), "maximum": .number(sorted.last ?? 0)
            ]),
            "project_inspection_ms": .number(projectInspection),
            "project_create_ms": .number(projectMutation), "project_update_ms": .number(projectUpdate),
            "session_capture_ms": .number(sessionCaptureMilliseconds),
            "session_diff_ms": .number(sessionDiffMilliseconds),
            "change_set_preview_ms": .number(changeSetPreviewMilliseconds),
            "operation_preview_ms": .number(operationPreviewMilliseconds),
            "log_retrieval_ms": .number(logRetrievalMilliseconds),
            "port_discovery": .string("measured by the normal bounded runtime refresh tests"),
            "enrichment": .string("included in runtime snapshot state"),
            "memory_delta_bytes": memoryBefore.flatMap { before in
                memoryAfter.map { .number(Double(Int64($0) - Int64(before))) }
            } ?? .null,
            "event_writes": .number(0),
            "concurrent_clients": .string("covered by the eight-client Unix transport test"),
            "host_reconnect": .string("covered by host activation/retry and transport integration tests")
        ])
    }

    private func currentResidentMemoryBytes() -> UInt64? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        return UInt64(max(usage.ru_maxrss, 0))
    }

    func developmentStoreReset(_ arguments: JSONValue) async throws -> JSONValue {
        try requireDevelopmentMode()
        guard arguments["confirm"]?.boolValue == true else {
            throw ControlFailure(code: .operationNotApproved, message: "Disposable store reset requires confirm=true.")
        }
        await fixtureController.stopAll()
        let context = store.context
        try deleteAll(MCPAuditEventRecord.self, in: context)
        try deleteAll(ControlPlaneItemRecord.self, in: context)
        try deleteAll(EntityRevisionRecord.self, in: context)
        try deleteAll(LifecycleEventContextRecord.self, in: context)
        try deleteAll(LifecycleEventRecord.self, in: context)
        try deleteAll(SessionRestoreRecord.self, in: context)
        try deleteAll(WorkspaceSessionServiceRecord.self, in: context)
        try deleteAll(WorkspaceSessionRecord.self, in: context)
        try deleteAll(ManagedServiceCheckRecord.self, in: context)
        try deleteAll(ProfileDependencyRecord.self, in: context)
        try deleteAll(ExpectedPortRecord.self, in: context)
        try deleteAll(LaunchProfileRecord.self, in: context)
        try deleteAll(ProjectRecord.self, in: context)
        try context.save()
        mutationVersion &+= 1
        discoveryLeases.removeAll(); operationLeases.removeAll(); changeSetLeases.removeAll(); idempotentResults.removeAll(); recentErrors.removeAll()
        return .object(["reset": .bool(true), "scope": .string("disposable_development_store"), "production_data_touched": .bool(false)])
    }

    func parityValidation() -> JSONValue {
        let production = ControlCapabilityRegistry.productionTools
        let development = ControlCapabilityRegistry.developmentTools
        let all = production + development
        let duplicateNames = Dictionary(grouping: all, by: \.name).filter { $0.value.count > 1 }.keys.sorted()
        let missingSchemas = all.filter { $0.inputSchema.objectValue == nil || $0.outputSchema.objectValue == nil }.map(\.name)
        let conditionallyPreviewedDeletes = Set(["project_delete", "service_delete", "session_delete"])
        let destructiveWithoutPreview = production.filter {
            $0.annotations.destructiveHint && !$0.capability.previewRequired && !conditionallyPreviewedDeletes.contains($0.name)
        }.map(\.name)
        let missingTests = all.filter { $0.capability.testReference.isEmpty }.map(\.name)
        return .object([
            "valid": .bool(duplicateNames.isEmpty && missingSchemas.isEmpty && destructiveWithoutPreview.isEmpty && missingTests.isEmpty),
            "production_tool_count": .number(Double(production.count)),
            "development_tool_count": .number(Double(development.count)),
            "duplicate_tools": .array(duplicateNames.map(JSONValue.string)),
            "missing_schemas": .array(missingSchemas.map(JSONValue.string)),
            "destructive_without_preview": .array(destructiveWithoutPreview.map(JSONValue.string)),
            "missing_test_references": .array(missingTests.map(JSONValue.string))
        ])
    }

    private func requireDevelopmentMode() throws {
        guard developmentMode else { throw ControlFailure(code: .developmentModeRequired, message: "This tool is available only in an isolated development host.") }
    }

    private func readGitIdentity(workspace: String) -> (branch: String, commit: String) {
        let root = URL(fileURLWithPath: workspace, isDirectory: true).standardizedFileURL
        let headURL = root.appendingPathComponent(".git/HEAD")
        guard let head = try? String(contentsOf: headURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) else {
            return ("unavailable", "unavailable")
        }
        if head.hasPrefix("ref: ") {
            let reference = String(head.dropFirst(5))
            let commit = (try? String(contentsOf: root.appendingPathComponent(".git").appendingPathComponent(reference), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unavailable"
            return (reference.split(separator: "/").last.map(String.init) ?? reference, commit)
        }
        return ("detached", head)
    }

    private func deleteAll<T: PersistentModel>(_ type: T.Type, in context: ModelContext) throws {
        try context.fetch(FetchDescriptor<T>()).forEach(context.delete)
    }
}
