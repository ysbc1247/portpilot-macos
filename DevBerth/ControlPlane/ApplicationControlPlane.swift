import AppKit
import DevBerthControlContracts
import Foundation
import ServiceManagement
import SwiftData

@MainActor
final class ApplicationControlPlane {
    struct DiscoveryLease {
        let report: ProjectDiscoveryReport
        let expiresAt: Date
    }

    struct OperationLease {
        let id: UUID
        let type: String
        let targets: [String]
        let options: JSONValue
        let fingerprints: [String: ProcessFingerprint]
        let revisions: [String: Int]
        let ownershipRoutes: [String: RuntimeOwnershipGraph]
        let targetEvidence: [String: JSONValue]
        let createdAt: Date
        let expiresAt: Date
        let stateVersion: UInt64
        var used: Bool
    }

    struct ChangeSetLease {
        let id: UUID
        let changes: [JSONValue]
        let stateVersion: UInt64
        let revisions: [String: Int]
        let compensation: [JSONValue]
        let createdAt: Date
        let expiresAt: Date
        var used: Bool
    }

    let model: AppModel
    let store: ControlPlaneStore
    let developmentMode: Bool
    let fixtureController: DevelopmentFixtureController
    let startedAt = Date()
    var mutationVersion: UInt64 = 1
    var discoveryLeases: [UUID: DiscoveryLease] = [:]
    var operationLeases: [UUID: OperationLease] = [:]
    var changeSetLeases: [UUID: ChangeSetLease] = [:]
    var idempotentResults: [String: JSONValue] = [:]
    var recentErrors: [JSONValue] = []
    var developmentAcceptanceRoots: [URL] = []

    init(
        model: AppModel,
        container: ModelContainer,
        developmentMode: Bool,
        fixtureController: DevelopmentFixtureController = DevelopmentFixtureController()
    ) {
        self.model = model
        store = ControlPlaneStore(container: container)
        self.developmentMode = developmentMode
        self.fixtureController = fixtureController
    }

    func handle(_ request: ControlRequest) async -> ControlResponse {
        let snapshot = snapshotVersion
        do {
            guard request.handshake.protocolVersion == ControlProtocolConstants.version,
                  request.handshake.toolSchemaVersion == ControlProtocolConstants.toolSchemaVersion else {
                throw ControlFailure(
                    code: .unsupportedCapability,
                    message: "Control protocol negotiation failed.",
                    details: .object([
                        "host_protocol": .string(ControlProtocolConstants.version),
                        "host_schema": .string(ControlProtocolConstants.toolSchemaVersion)
                    ])
                )
            }
            guard request.handshake.client.developmentMode == developmentMode else {
                throw ControlFailure(
                    code: .productionDataProtected,
                    message: "The client and control host isolation modes do not match."
                )
            }
            guard request.deadline > Date() else {
                throw ControlFailure(code: .timeout, message: "The request deadline expired before dispatch.")
            }
            guard ControlCapabilityRegistry.tool(named: request.toolName, developmentMode: developmentMode) != nil else {
                let code: ControlErrorCode = request.toolName.hasPrefix("dev_") ? .developmentModeRequired : .unsupportedCapability
                throw ControlFailure(code: code, message: "Tool \(request.toolName) is not available in this host build.")
            }
            let idempotencyNamespace = "\(request.handshake.client.instanceID.uuidString):\(request.toolName)"
            if let key = request.idempotencyKey, let cached = idempotentResults["\(idempotencyNamespace):\(key)"] {
                return ControlResponse(requestID: request.requestID, snapshotVersion: snapshotVersion, data: cached)
            }
            let data = try await dispatch(tool: request.toolName, arguments: request.arguments, request: request)
            if let key = request.idempotencyKey {
                idempotentResults["\(idempotencyNamespace):\(key)"] = data
                if idempotentResults.count > 500 { idempotentResults.removeValue(forKey: idempotentResults.keys.sorted().first!) }
            }
            store.recordAudit(request: request, result: "succeeded", operationID: operationID(in: request.arguments))
            return ControlResponse(requestID: request.requestID, snapshotVersion: snapshotVersion, data: data)
        } catch let failure as ControlFailure {
            record(error: failure, request: request)
            store.recordAudit(request: request, result: failure.code.rawValue, operationID: operationID(in: request.arguments))
            return ControlResponse(requestID: request.requestID, snapshotVersion: snapshot, failure: failure)
        } catch let error as DevBerthError {
            let failure = ControlFailure(
                code: map(error),
                message: error.localizedDescription,
                recoverySuggestion: error.recoverySuggestion
            )
            record(error: failure, request: request)
            store.recordAudit(request: request, result: failure.code.rawValue, operationID: operationID(in: request.arguments))
            return ControlResponse(requestID: request.requestID, snapshotVersion: snapshot, failure: failure)
        } catch {
            let failure = ControlFailure(code: .internalError, message: error.localizedDescription)
            record(error: failure, request: request)
            store.recordAudit(request: request, result: failure.code.rawValue, operationID: operationID(in: request.arguments))
            return ControlResponse(requestID: request.requestID, snapshotVersion: snapshot, failure: failure)
        }
    }

    func dispatch(tool: String, arguments: JSONValue, request: ControlRequest) async throws -> JSONValue {
        switch tool {
        case "runtime_snapshot": return try runtimeSnapshot()
        case "runtime_search": return try runtimeSearch(arguments)
        case "runtime_inspect": return try await runtimeInspect(arguments)
        case "runtime_explain": return try await runtimeExplain(arguments)
        case "runtime_update_metadata": return try genericMutation(tool: tool, kind: "runtime_metadata", arguments: arguments)

        case "projects_list": return .object(["projects": .array(try store.projects())])
        case "project_inspect": return try projectInspect(arguments)
        case "project_create": return try mutated { try store.createProject(arguments: arguments) }
        case "project_update": return try mutated { try store.updateProject(id: requiredUUID("project_id", arguments), arguments: arguments) }
        case "project_duplicate": return try mutated { try store.duplicateProject(id: requiredUUID("project_id", arguments), arguments: arguments) }
        case "project_discover": return try await projectDiscover(arguments)
        case "project_apply_discovery": return try mutated { try projectApplyDiscovery(arguments) }
        case "project_import": return try await projectImport(arguments)
        case "project_export": return try projectExport(arguments)
        case "project_archive": return try mutated {
            try store.archive(
                kind: "project", id: requiredUUID("project_id", arguments),
                archived: arguments["archived"]?.boolValue ?? true,
                suppliedRevision: arguments["revision"]?.intValue
            )
        }
        case "project_delete": return try mutated {
            let id = try requiredUUID("project_id", arguments)
            try store.deleteProject(id: id, allowReferences: false)
            return .object(["deleted": .string(id.uuidString)])
        }
        case "project_validate": return try projectValidate(arguments)

        case "services_list": return .object(["services": .array(try store.services().map(store.serviceValue))])
        case "service_inspect": return try await serviceInspect(arguments)
        case "service_create": return try mutated { try store.createService(arguments: arguments) }
        case "service_update": return try mutated { try store.updateService(id: requiredUUID("service_id", arguments), arguments: arguments) }
        case "service_duplicate": return try mutated { try store.duplicateService(id: requiredUUID("service_id", arguments), arguments: arguments) }
        case "service_adopt_runtime": return try mutated { try serviceAdoptRuntime(arguments) }
        case "service_verify": return try await serviceVerify(arguments)
        case "service_enable": return try mutated {
            try store.setServiceEnabled(
                id: requiredUUID("service_id", arguments),
                enabled: arguments["enabled"]?.boolValue ?? true,
                suppliedRevision: arguments["revision"]?.intValue
            )
        }
        case "service_archive": return try mutated {
            try store.archive(
                kind: "service", id: requiredUUID("service_id", arguments),
                archived: arguments["archived"]?.boolValue ?? true,
                suppliedRevision: arguments["revision"]?.intValue
            )
        }
        case "service_delete": return try mutated {
            let id = try requiredUUID("service_id", arguments)
            guard !model.managedRunningServiceIDs.contains(id) else {
                throw ControlFailure(code: .conflictDetected, message: "Stop the active managed service through operation_preview before deletion.")
            }
            try store.deleteService(id: id, allowReferences: false)
            return .object(["deleted": .string(id.uuidString)])
        }
        case "service_start": return try await serviceStart(arguments)
        case "service_recover": return try await serviceRecover(arguments)

        case "dependency_graph_get": return try dependencyGraph()
        case "dependency_update": return try mutated { try dependencyUpdate(arguments) }
        case "dependency_validate": return try dependencyValidate(arguments)

        case "sessions_list": return .object(["sessions": .array(try store.sessionValues())])
        case "session_inspect": return try sessionInspect(arguments)
        case "session_create": return try mutated { try sessionCreate(arguments) }
        case "session_capture": return try await sessionCapture(arguments)
        case "session_update": return try mutated { try sessionUpdate(arguments) }
        case "session_update_from_runtime": return try sessionUpdateFromRuntime(arguments)
        case "session_duplicate": return try mutated { try sessionDuplicate(arguments) }
        case "session_diff": return try await sessionDiff(arguments)
        case "session_export": return try sessionExport(arguments)
        case "session_import": return try mutated { try sessionImport(arguments) }
        case "session_archive": return try mutated {
            try store.archive(
                kind: "session", id: requiredUUID("session_id", arguments),
                archived: arguments["archived"]?.boolValue ?? true,
                suppliedRevision: arguments["revision"]?.intValue
            )
        }
        case "session_delete": return try mutated {
            let id = try requiredUUID("session_id", arguments)
            try store.deleteSession(id: id, allowHistory: false)
            return .object(["deleted": .string(id.uuidString)])
        }
        case "session_restore_preview": return try await sessionRestorePreview(arguments)

        case "ports_list": return try portsList()
        case "port_inspect": return try await portInspect(arguments)
        case "port_watch_create": return try genericMutation(tool: tool, kind: "port_watch", arguments: arguments)
        case "port_watch_update": return try genericMutation(tool: tool, kind: "port_watch", arguments: arguments)
        case "port_watch_delete": return try genericMutation(tool: tool, kind: "port_watch", arguments: arguments)
        case "port_reservation_create": return try genericMutation(tool: tool, kind: "port_reservation", arguments: arguments)
        case "port_reservation_update": return try genericMutation(tool: tool, kind: "port_reservation", arguments: arguments)
        case "port_reservation_delete": return try genericMutation(tool: tool, kind: "port_reservation", arguments: arguments)
        case "port_alias_create": return try genericMutation(tool: tool, kind: "port_alias", arguments: arguments)
        case "port_alias_update": return try genericMutation(tool: tool, kind: "port_alias", arguments: arguments)
        case "port_alias_delete": return try genericMutation(tool: tool, kind: "port_alias", arguments: arguments)
        case "port_ignore_rule_create": return try genericMutation(tool: tool, kind: "port_ignore_rule", arguments: arguments)
        case "port_ignore_rule_delete": return try genericMutation(tool: tool, kind: "port_ignore_rule", arguments: arguments)

        case "docker_status": return try await dockerStatus()
        case "docker_containers_list": return try await dockerContainers()
        case "docker_container_inspect": return try await dockerContainerInspect(arguments)
        case "docker_compose_projects_list": return try await dockerComposeProjects()
        case "docker_compose_project_inspect": return try await dockerComposeProjectInspect(arguments)
        case "docker_association_update": return try genericMutation(tool: tool, kind: "docker_association", arguments: arguments)
        case "docker_import_compose_project": return try genericMutation(tool: tool, kind: "docker_association", arguments: arguments)

        case "service_logs": return try await serviceLogs(arguments)
        case "logs_export": return try await logsExport(arguments)
        case "history_query": return try historyQuery(arguments)
        case "history_event_inspect": return try historyEventInspect(arguments)
        case "history_export": return try historyExport(arguments)
        case "diagnostics_analyze": return try diagnosticsAnalyze(arguments)

        case "settings_get": return settingsGet()
        case "settings_update": return try await settingsUpdate(arguments)
        case "favorites_update": return try favoritesUpdate(arguments)
        case "tags_manage": return try genericMutation(tool: tool, kind: "tag", arguments: arguments)
        case "saved_filter_create": return try genericMutation(tool: tool, kind: "saved_filter", arguments: arguments)
        case "saved_filter_update": return try genericMutation(tool: tool, kind: "saved_filter", arguments: arguments)
        case "saved_filter_delete": return try genericMutation(tool: tool, kind: "saved_filter", arguments: arguments)

        case "operation_preview": return try await operationPreview(arguments)
        case "operation_execute": return try await operationExecute(arguments)
        case "change_set_preview": return try changeSetPreview(arguments)
        case "change_set_execute": return try await changeSetExecute(arguments, request: request)

        case "dev_build_info": return try developmentBuildInfo()
        case "dev_internal_state": return try await developmentInternalState()
        case "dev_fixture_list": return try await developmentFixtureList()
        case "dev_fixture_start", "dev_fixture_stop": return try await developmentFixtureMutation(tool: tool, arguments: arguments)
        case "dev_acceptance_scenario_run", "dev_acceptance_suite_run": return try await developmentAcceptance(tool: tool, arguments: arguments)
        case "dev_migration_validate": return developmentMigrationValidation()
        case "dev_performance_measure": return try await developmentPerformance(arguments)
        case "dev_recent_errors": return .object(["errors": .array(recentErrors)])
        case "dev_test_store_reset": return try await developmentStoreReset(arguments)
        case "dev_capability_parity_validate": return parityValidation()
        default: throw ControlFailure(code: .unsupportedCapability, message: "No dispatcher is registered for \(tool).")
        }
    }

    var snapshotVersion: UInt64 {
        let captured = UInt64(max(0, (model.lastRefresh ?? startedAt).timeIntervalSince1970 * 1_000))
        return captured &+ mutationVersion
    }

    func mutated(_ body: () throws -> JSONValue) rethrows -> JSONValue {
        let value = try body()
        mutationVersion &+= 1
        return value
    }

    private func operationID(in arguments: JSONValue) -> String? {
        arguments["operation_id"]?.stringValue ?? arguments["change_set_token"]?.stringValue
    }

    private func record(error: ControlFailure, request: ControlRequest) {
        recentErrors.append(.object([
            "timestamp": .string(Date().ISO8601Format()),
            "request_id": .string(request.requestID),
            "tool": .string(request.toolName),
            "code": .string(error.code.rawValue),
            "message": .string(error.message)
        ]))
        if recentErrors.count > 100 { recentErrors.removeFirst(recentErrors.count - 100) }
    }

    private func map(_ error: DevBerthError) -> ControlErrorCode {
        switch error {
        case .processFingerprintChanged:
            return .identityMismatch
        case .listenerOwnershipChanged:
            return .ownershipChanged
        case .protectedProcess:
            return .permissionDenied
        case .restartTrustRequired:
            return .serviceNotVerified
        case .portConflict:
            return .conflictDetected
        case .dockerUnavailable:
            return .dockerUnavailable
        default:
            return .internalError
        }
    }
}
