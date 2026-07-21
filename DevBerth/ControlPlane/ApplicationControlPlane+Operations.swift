import Darwin
import DevBerthControlContracts
import Foundation
import SwiftData

extension ApplicationControlPlane {
    private static let supportedOperationTypes: Set<String> = [
        "stop_runtime", "force_stop_runtime", "stop_service", "restart_service",
        "stop_project", "restart_project", "stop_selected_project_services",
        "restore_session", "release_occupied_port", "resolve_port_conflict",
        "stop_docker_container", "restart_docker_container",
        "stop_compose_service", "restart_compose_service",
        "stop_compose_project", "restart_compose_project",
        "stop_homebrew_service", "restart_homebrew_service",
        "stop_kubernetes_port_forward", "stop_ssh_tunnel",
        "delete_project_with_dependencies", "delete_managed_service_with_references",
        "delete_session_with_history", "clear_selected_history", "clear_selected_logs",
        "remove_local_aliases_bulk", "apply_destructive_change_set"
    ]

    func operationPreview(_ arguments: JSONValue) async throws -> JSONValue {
        pruneLeases()
        try rejectUnsafeOperationArguments(arguments)
        let type = try requiredString("operation_type", arguments)
        guard Self.supportedOperationTypes.contains(type) else {
            throw ControlFailure(code: .invalidArguments, message: "Unsupported operation type \(type).")
        }
        let targets = try operationTargets(arguments)
        guard !targets.isEmpty else {
            throw ControlFailure(code: .invalidArguments, message: "At least one stable target identifier is required.")
        }

        var fingerprints: [String: ProcessFingerprint] = [:]
        var routes: [String: RuntimeOwnershipGraph] = [:]
        var revisions: [String: Int] = [:]
        var evidence: [String: JSONValue] = [:]
        var ports = Set<UInt16>()
        var dependencies = Set<String>()
        var sessions = Set<String>()
        var unrelatedProcesses = false

        if Self.runtimeOperationTypes.contains(type) {
            for target in targets {
                let listener = try listener(stableID: target)
                if developmentMode,
                   let fixtureID = await fixtureController.fixtureID(owningProcess: listener.process.fingerprint.pid) {
                    fingerprints[target] = listener.process.fingerprint
                    evidence[target] = .object([
                        "development_fixture_id": .string(fixtureID.uuidString),
                        "process_id": .number(Double(listener.process.fingerprint.pid))
                    ])
                    ports.insert(listener.port)
                    continue
                }
                let route = await model.resolveOwnership(of: listener)
                try validateRoute(route, for: type)
                fingerprints[target] = listener.process.fingerprint
                routes[target] = route
                ports.insert(listener.port)
                dependencies.formUnion(route.managedServiceID.map { [$0.uuidString] } ?? [])
                sessions.formUnion(route.workspaceSessionIDs.map(\.uuidString))
                unrelatedProcesses = unrelatedProcesses || !listener.process.launchedByDevBerth
            }
        } else if Self.serviceOperationTypes.contains(type) {
            for target in targets {
                let id = try stableUUID(target, kind: "service")
                let value = try store.serviceValue(store.service(id: id))
                revisions["service:\(target)"] = value["revision"]?.intValue ?? 1
                evidence[target] = value
                let service = try store.service(id: id)
                ports.formUnion(service.expectedPorts.map(\.port))
                dependencies.formUnion(service.dependencyServiceIDs.map(\.uuidString))
                if type == "stop_service" || type == "restart_service" {
                    for listener in model.observedServiceStopTargets(for: service) {
                        let route = await model.resolveOwnership(of: listener)
                        try validateRoute(route, for: "stop_service")
                        fingerprints[listener.id] = listener.process.fingerprint
                        routes[listener.id] = route
                        ports.insert(listener.port)
                        unrelatedProcesses = true
                    }
                }
                for session in try store.sessions(includeArchived: true) where session.serviceSnapshots.contains(where: { $0.managedServiceID == id }) {
                    let sessionValue = try store.sessionValue(session)
                    revisions["session:\(session.id.uuidString)"] = sessionValue["revision"]?.intValue ?? 1
                    sessions.insert(session.id.uuidString)
                }
            }
        } else if Self.projectOperationTypes.contains(type) {
            for target in targets {
                let id = try stableUUID(target, kind: "project")
                let project = try store.projectValue(store.project(id: id))
                revisions["project:\(target)"] = project["revision"]?.intValue ?? 1
                evidence[target] = project
                let projectServices = try store.services(includeArchived: true).filter { $0.projectID == id }
                let selectedServiceIDs = Set(
                    arguments["options"]?["service_ids"]?.arrayValue?.compactMap {
                        $0.stringValue.flatMap(UUID.init(uuidString:))
                    } ?? []
                )
                for service in projectServices {
                    let value = try store.serviceValue(service)
                    revisions["service:\(service.id.uuidString)"] = value["revision"]?.intValue ?? 1
                    ports.formUnion(service.expectedPorts.map(\.port))
                    dependencies.formUnion(service.dependencyServiceIDs.map(\.uuidString))
                    if type == "stop_project" || type == "restart_project"
                        || (type == "stop_selected_project_services" && selectedServiceIDs.contains(service.id)) {
                        for listener in model.observedServiceStopTargets(for: service) {
                            let route = await model.resolveOwnership(of: listener)
                            try validateRoute(route, for: "stop_service")
                            fingerprints[listener.id] = listener.process.fingerprint
                            routes[listener.id] = route
                            ports.insert(listener.port)
                            unrelatedProcesses = true
                        }
                    }
                }
                let projectServiceIDs = Set(projectServices.map(\.id))
                for session in try store.sessions(includeArchived: true)
                    where session.projectIDs.contains(id) || session.serviceSnapshots.contains(where: { projectServiceIDs.contains($0.managedServiceID) }) {
                    let sessionValue = try store.sessionValue(session)
                    revisions["session:\(session.id.uuidString)"] = sessionValue["revision"]?.intValue ?? 1
                    sessions.insert(session.id.uuidString)
                }
            }
        } else if Self.sessionOperationTypes.contains(type) {
            for target in targets {
                let id = try stableUUID(target, kind: "session")
                let session = try store.sessionValue(store.session(id: id))
                revisions["session:\(target)"] = session["revision"]?.intValue ?? 1
                evidence[target] = session
                sessions.insert(target)
            }
        } else if Self.dockerOperationTypes.contains(type) {
            let containers = try await model.dockerService.runningContainers()
            for target in targets {
                guard let container = containers.first(where: { $0.id == target || $0.name == target }) else {
                    throw ControlFailure(code: .entityNotFound, message: "No running Docker container matches \(target).")
                }
                if type.contains("compose"), container.composeContext == nil {
                    throw ControlFailure(code: .ownershipChanged, message: "Compose control requires a currently verified canonical Compose context.")
                }
                evidence[target] = dockerEvidence(container)
                ports.formUnion(container.ports.map(\.hostPort))
            }
        } else if type == "clear_selected_history" {
            let existing = try store.context.fetch(FetchDescriptor<LifecycleEventRecord>())
            for target in targets {
                let id = try stableUUID(target, kind: "history event")
                guard existing.contains(where: { $0.id == id }) else {
                    throw ControlFailure(code: .entityNotFound, message: "No history event exists with ID \(target).")
                }
            }
        } else if type == "clear_selected_logs" {
            for target in targets {
                let id = try stableUUID(target, kind: "service")
                let service = try store.service(id: id)
                guard let path = service.logFile, !path.isEmpty else {
                    throw ControlFailure(code: .entityNotFound, message: "Service \(service.name) has no application-managed log file.")
                }
                let value = try store.serviceValue(service)
                revisions["service:\(target)"] = value["revision"]?.intValue ?? 1
                evidence[target] = .object(["log_path": .string(path)])
            }
        } else if type == "remove_local_aliases_bulk" {
            let aliases = try store.items(kind: "port_alias", includeArchived: true)
            for target in targets {
                guard let alias = aliases.first(where: { $0["id"]?.stringValue == target }) else {
                    throw ControlFailure(code: .entityNotFound, message: "No local alias exists with ID \(target).")
                }
                revisions["port_alias:\(target)"] = alias["revision"]?.intValue ?? 1
            }
        } else if type == "apply_destructive_change_set" {
            guard targets.count == 1, let token = UUID(uuidString: targets[0]), changeSetLeases[token] != nil else {
                throw ControlFailure(code: .entityNotFound, message: "The destructive change-set token is unavailable.")
            }
        }

        let id = UUID()
        let expiresAt = Date().addingTimeInterval(ControlProtocolConstants.operationLifetimeSeconds)
        let lease = OperationLease(
            id: id, type: type, targets: targets,
            options: arguments["options"] ?? .object([:]), fingerprints: fingerprints,
            revisions: revisions, ownershipRoutes: routes, targetEvidence: evidence,
            createdAt: Date(), expiresAt: expiresAt, stateVersion: mutationVersion, used: false
        )
        operationLeases[id] = lease
        return .object([
            "operation_id": .string(id.uuidString), "operation_type": .string(type),
            "exact_targets": .array(targets.map(JSONValue.string)),
            "entity_revisions": .object(revisions.mapValues { .number(Double($0)) }),
            "runtime_fingerprints": try JSONValue.encode(fingerprints),
            "ownership_routes": try JSONValue.encode(routes),
            "dependencies_affected": .array(dependencies.sorted().map(JSONValue.string)),
            "ports_affected": .array(ports.sorted().map { .number(Double($0)) }),
            "sessions_affected": .array(sessions.sorted().map(JSONValue.string)),
            "risks": .array(operationRisks(type: type, unrelatedProcesses: unrelatedProcesses).map(JSONValue.string)),
            "force_escalation_may_occur": .bool(type == "force_stop_runtime"),
            "unrelated_processes_involved": .bool(unrelatedProcesses),
            "compensation_plan": .string(compensationSummary(for: type)),
            "expires_at": .string(expiresAt.ISO8601Format()),
            "state_version_precondition": .number(Double(lease.stateVersion)),
            "summary": .string("\(type.replacingOccurrences(of: "_", with: " ").capitalized) for \(targets.count) exact target(s). Review and approve operation_execute before continuing.")
        ])
    }

    private static let runtimeOperationTypes: Set<String> = [
        "stop_runtime", "force_stop_runtime", "release_occupied_port", "resolve_port_conflict",
        "stop_homebrew_service", "restart_homebrew_service", "stop_kubernetes_port_forward", "stop_ssh_tunnel"
    ]
    private static let serviceOperationTypes: Set<String> = ["stop_service", "restart_service", "delete_managed_service_with_references"]
    private static let projectOperationTypes: Set<String> = ["stop_project", "restart_project", "stop_selected_project_services", "delete_project_with_dependencies"]
    private static let sessionOperationTypes: Set<String> = ["restore_session", "delete_session_with_history"]
    private static let dockerOperationTypes: Set<String> = [
        "stop_docker_container", "restart_docker_container", "stop_compose_service",
        "restart_compose_service", "stop_compose_project", "restart_compose_project"
    ]
}

extension ApplicationControlPlane {
    func operationExecute(_ arguments: JSONValue) async throws -> JSONValue {
        let id = try requiredUUID("operation_id", arguments)
        guard var lease = operationLeases[id] else {
            throw ControlFailure(code: .entityNotFound, message: "No operation preview exists with ID \(id.uuidString).")
        }
        guard lease.expiresAt > Date() else {
            operationLeases.removeValue(forKey: id)
            throw ControlFailure(code: .operationExpired, message: "The operation preview expired. Create a new preview from current state.")
        }
        guard !lease.used else {
            throw ControlFailure(code: .operationAlreadyUsed, message: "This operation preview has already been executed.")
        }
        guard mutationVersion == lease.stateVersion else {
            throw ControlFailure(code: .staleSnapshot, message: "Application configuration changed after preview. Create a new preview.")
        }
        try validateOperationRevisions(lease)
        try await validateOperationRuntimeEvidence(lease)

        lease.used = true
        operationLeases[id] = lease
        var results: [JSONValue] = []
        for target in lease.targets {
            do {
                let result = try await executeOperationTarget(lease: lease, target: target)
                results.append(.object(["target": .string(target), "status": .string("succeeded"), "result": result]))
            } catch let failure as ControlFailure {
                results.append(.object([
                    "target": .string(target), "status": .string("failed"),
                    "error": try JSONValue.encode(failure)
                ]))
                throw ControlFailure(
                    code: failure.code,
                    message: "Operation stopped at target \(target): \(failure.message)",
                    recoverySuggestion: failure.recoverySuggestion,
                    details: .object(["per_target_results": .array(results)])
                )
            } catch {
                results.append(.object(["target": .string(target), "status": .string("failed"), "message": .string(error.localizedDescription)]))
                throw ControlFailure(
                    code: .internalError,
                    message: "Operation stopped at target \(target): \(error.localizedDescription)",
                    details: .object(["per_target_results": .array(results)])
                )
            }
        }
        mutationVersion &+= 1
        return .object([
            "operation_id": .string(id.uuidString), "operation_type": .string(lease.type),
            "status": .string("succeeded"), "per_target_results": .array(results),
            "compensation_applied": .bool(false)
        ])
    }

    private func executeOperationTarget(lease: OperationLease, target: String) async throws -> JSONValue {
        if let fixtureID = lease.targetEvidence[target]?["development_fixture_id"]?.stringValue.flatMap(UUID.init(uuidString:)) {
            guard developmentMode else {
                throw ControlFailure(code: .productionDataProtected, message: "Development fixture evidence is invalid in a production host.")
            }
            try await fixtureController.stop(id: fixtureID)
            return .object([
                "stopped": .bool(true), "listener_id": .string(target),
                "development_fixture_id": .string(fixtureID.uuidString)
            ])
        }
        switch lease.type {
        case "stop_runtime", "release_occupied_port", "resolve_port_conflict",
             "stop_homebrew_service", "stop_kubernetes_port_forward", "stop_ssh_tunnel":
            let listener = try listener(stableID: target)
            try await performModelAction { await model.terminate(listener, mode: .graceful(timeoutSeconds: 5)) }
            return .object(["stopped": .bool(true), "listener_id": .string(target)])
        case "force_stop_runtime":
            let listener = try listener(stableID: target)
            try await performModelAction { await model.terminate(listener, mode: .force(confirmed: true)) }
            return .object(["stopped": .bool(true), "forced": .bool(true), "listener_id": .string(target)])
        case "restart_homebrew_service":
            let listener = try listener(stableID: target)
            try await performModelAction { await model.restartOwnedRuntime(listener) }
            return .object(["restarted": .bool(true), "listener_id": .string(target)])
        case "stop_service":
            let service = try store.service(id: stableUUID(target, kind: "service"))
            try await performModelAction {
                await model.stopProfile(service, confirmsObservedProcess: true)
            }
            return .object(["stopped": .bool(true), "service_id": .string(target)])
        case "restart_service":
            let service = try store.service(id: stableUUID(target, kind: "service"))
            if model.managedServiceActivity(for: service).state != .stopped {
                try await performModelAction {
                    await model.stopProfile(service, confirmsObservedProcess: true)
                }
            }
            try await performModelAction { await model.launchProfile(service) }
            return .object(["restarted": .bool(true), "service_id": .string(target)])
        case "stop_project", "restart_project", "stop_selected_project_services":
            let projectID = try stableUUID(target, kind: "project")
            let requestedIDs = Set(lease.options["service_ids"]?.arrayValue?.compactMap { $0.stringValue.flatMap(UUID.init(uuidString:)) } ?? [])
            let all = try store.services(includeArchived: true).filter { $0.projectID == projectID }
            let services = lease.type == "stop_selected_project_services" ? all.filter { requestedIDs.contains($0.id) } : all
            if lease.type == "stop_selected_project_services", services.count != requestedIDs.count {
                throw ControlFailure(code: .entityChanged, message: "The selected project service set changed after preview.")
            }
            try await performModelAction {
                await model.stopProject(services, confirmsObservedProcesses: true)
            }
            if lease.type == "restart_project" {
                try await performModelAction { await model.startProject(services) }
            }
            return .object(["project_id": .string(target), "service_count": .number(Double(services.count))])
        case "restore_session":
            let session = try store.session(id: stableUUID(target, kind: "session"))
            let services = try store.services(includeArchived: true)
            let options = (try? lease.options.decode(SessionRestoreOptions.self)) ?? SessionRestoreOptions()
            model.presentedError = nil
            guard let execution = await model.restoreWorkspaceSession(session, services: services, options: options) else {
                throw ControlFailure(code: .internalError, message: model.presentedError?.localizedDescription ?? "The session restore failed.")
            }
            return try JSONValue.encode(execution.result)
        case "stop_docker_container", "restart_docker_container":
            let container = try await currentContainer(matching: target)
            if lease.type == "stop_docker_container" {
                try await model.dockerService.stop(containerID: container.id)
            } else {
                try await model.dockerService.restart(containerID: container.id)
            }
            model.dockerMutationDidComplete()
            return .object(["container_id": .string(container.id), "action": .string(lease.type)])
        case "stop_compose_service", "restart_compose_service":
            let container = try await currentContainer(matching: target)
            guard let context = container.composeContext else {
                throw ControlFailure(code: .ownershipChanged, message: "The verified Compose context is no longer available.")
            }
            if lease.type == "stop_compose_service" {
                try await model.dockerService.stopComposeService(context: context)
            } else {
                try await model.dockerService.restartComposeService(context: context)
            }
            model.dockerMutationDidComplete()
            return .object(["project": .string(context.projectName), "service": .string(context.serviceName)])
        case "stop_compose_project", "restart_compose_project":
            let seed = try await currentContainer(matching: target)
            guard let seedContext = seed.composeContext else {
                throw ControlFailure(code: .ownershipChanged, message: "The verified Compose project context is no longer available.")
            }
            let containers = try await model.dockerService.runningContainers().filter {
                $0.composeContext?.projectName == seedContext.projectName
            }
            guard !containers.isEmpty, containers.allSatisfy({ $0.composeContext != nil }) else {
                throw ControlFailure(code: .ownershipChanged, message: "Compose project membership changed after preview.")
            }
            for container in containers {
                guard let context = container.composeContext else { continue }
                if lease.type == "stop_compose_project" {
                    try await model.dockerService.stopComposeService(context: context)
                } else {
                    try await model.dockerService.restartComposeService(context: context)
                }
            }
            model.dockerMutationDidComplete()
            return .object(["project": .string(seedContext.projectName), "service_count": .number(Double(containers.count))])
        case "delete_project_with_dependencies":
            try store.deleteProject(id: stableUUID(target, kind: "project"), allowReferences: true)
            return .object(["deleted": .bool(true), "project_id": .string(target)])
        case "delete_managed_service_with_references":
            let serviceID = try stableUUID(target, kind: "service")
            try store.deleteService(id: serviceID, allowReferences: true)
            await model.managedServicesWereDeleted([serviceID])
            return .object(["deleted": .bool(true), "service_id": .string(target)])
        case "delete_session_with_history":
            try store.deleteSession(id: stableUUID(target, kind: "session"), allowHistory: true)
            return .object(["deleted": .bool(true), "session_id": .string(target)])
        case "clear_selected_history":
            let id = try stableUUID(target, kind: "history event")
            try clearHistoryEvent(id: id)
            return .object(["deleted": .bool(true), "event_id": .string(target)])
        case "clear_selected_logs":
            try clearManagedLog(serviceID: stableUUID(target, kind: "service"))
            return .object(["cleared": .bool(true), "service_id": .string(target)])
        case "remove_local_aliases_bulk":
            let id = try stableUUID(target, kind: "port alias")
            try store.deleteItem(kind: "port_alias", id: id, suppliedRevision: lease.revisions["port_alias:\(target)"])
            return .object(["deleted": .bool(true), "alias_id": .string(target)])
        case "apply_destructive_change_set":
            guard let token = UUID(uuidString: target), let changeLease = changeSetLeases[token] else {
                throw ControlFailure(code: .changeSetExpired, message: "The destructive change set is unavailable.")
            }
            return try await executeChangeSetLease(changeLease, request: nil)
        default:
            throw ControlFailure(code: .unsupportedCapability, message: "No executor exists for \(lease.type).")
        }
    }

    private func performModelAction(_ body: () async -> Void) async throws {
        model.presentedError = nil
        await body()
        if let error = model.presentedError {
            throw ControlFailure(code: mapControlError(error), message: error.localizedDescription, recoverySuggestion: error.recoverySuggestion)
        }
    }

    private func mapControlError(_ error: DevBerthError) -> ControlErrorCode {
        switch error {
        case .processFingerprintChanged: return .identityMismatch
        case .listenerOwnershipChanged: return .ownershipChanged
        case .protectedProcess, .permissionDenied: return .permissionDenied
        case .restartTrustRequired: return .serviceNotVerified
        case .portConflict: return .conflictDetected
        case .dockerUnavailable: return .dockerUnavailable
        case .missingSecret: return .missingSecretReference
        default: return .internalError
        }
    }
}

extension ApplicationControlPlane {
    private func rejectUnsafeOperationArguments(_ arguments: JSONValue) throws {
        let forbidden = Set(["pid", "process_id", "command", "shell", "executable", "arguments"])
        func containsForbidden(_ value: JSONValue) -> String? {
            switch value {
            case let .object(object):
                for (key, nested) in object {
                    if forbidden.contains(key.lowercased()) { return key }
                    if let found = containsForbidden(nested) { return found }
                }
            case let .array(values):
                for value in values {
                    if let found = containsForbidden(value) { return found }
                }
            default:
                break
            }
            return nil
        }
        if let key = containsForbidden(arguments) {
            throw ControlFailure(code: .invalidArguments, message: "Operation previews do not accept raw process or command field \(key).")
        }
    }

    private func operationTargets(_ arguments: JSONValue) throws -> [String] {
        if let values = arguments["targets"]?.arrayValue {
            let targets = values.compactMap(\.stringValue)
            guard targets.count == values.count else {
                throw ControlFailure(code: .invalidArguments, message: "Every operation target must be a stable string identifier.")
            }
            return Array(Set(targets)).sorted()
        }
        for key in ["runtime_id", "listener_id", "service_id", "project_id", "session_id", "container_id", "event_id", "alias_id", "change_set_token", "target_id"] {
            if let value = arguments[key]?.stringValue { return [value] }
        }
        return []
    }

    private func stableUUID(_ value: String, kind: String) throws -> UUID {
        guard let id = UUID(uuidString: value) else {
            throw ControlFailure(code: .invalidArguments, message: "\(kind.capitalized) target \(value) is not a stable UUID.")
        }
        return id
    }

    private func listener(stableID: String) throws -> ObservedListener {
        guard let listener = model.listeners.first(where: { $0.id == stableID }) else {
            throw ControlFailure(code: .entityNotFound, message: "No current listener matches stable ID \(stableID). Refresh and inspect Runtime.")
        }
        return listener
    }

    private func validateRoute(_ route: RuntimeOwnershipGraph, for type: String) throws {
        let requiredAction: LifecycleActionKind = type == "force_stop_runtime" ? .forceStop : (type.hasPrefix("restart") ? .restart : .gracefulStop)
        guard route.recommendation.supportedActions.contains(requiredAction) else {
            throw ControlFailure(
                code: .permissionDenied,
                message: "The verified \(route.recommendation.controllerKind.rawValue) route does not authorize \(requiredAction.rawValue).",
                recoverySuggestion: route.recommendation.reason
            )
        }
        let requiredController: LifecycleControllerKind?
        switch type {
        case "stop_homebrew_service", "restart_homebrew_service": requiredController = .homebrewService
        case "stop_kubernetes_port_forward": requiredController = .kubernetesPortForward
        case "stop_ssh_tunnel": requiredController = .sshTunnel
        default: requiredController = nil
        }
        if let requiredController, route.recommendation.controllerKind != requiredController {
            throw ControlFailure(code: .ownershipChanged, message: "The target is not verified as \(requiredController.rawValue).")
        }
    }

    private func operationRisks(type: String, unrelatedProcesses: Bool) -> [String] {
        var values = ["Current state, revisions, identity, and ownership will be revalidated before execution."]
        if type.contains("delete") || type.contains("clear") || type.contains("remove") {
            values.append("The selected persistent data cannot be reconstructed automatically after execution.")
        }
        if type.contains("restart") { values.append("Restart can briefly interrupt dependent local services.") }
        if type == "force_stop_runtime" { values.append("Force stop does not permit graceful cleanup.") }
        if unrelatedProcesses { values.append("At least one target was not launched by DevBerth; exact verified ownership routing is required.") }
        return values
    }

    private func compensationSummary(for type: String) -> String {
        if type.contains("restart") { return "Report each stopped and restarted target; do not affect unrelated processes if a later target fails." }
        if type.contains("delete") || type.contains("clear") || type.contains("remove") {
            return "No automatic reconstruction is promised; execution stops at the first failed target and reports completed targets."
        }
        return "Execution stops at the first failure and leaves already stopped exact targets reported for manual restart."
    }

    private func validateOperationRevisions(_ lease: OperationLease) throws {
        for (key, expected) in lease.revisions {
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let current: Int
            switch parts[0] {
            case "project":
                current = try store.projectValue(store.project(id: stableUUID(parts[1], kind: "project")))["revision"]?.intValue ?? 1
            case "service":
                current = try store.serviceValue(store.service(id: stableUUID(parts[1], kind: "service")))["revision"]?.intValue ?? 1
            case "session":
                current = try store.sessionValue(store.session(id: stableUUID(parts[1], kind: "session")))["revision"]?.intValue ?? 1
            case "port_alias":
                let alias = try store.items(kind: "port_alias", includeArchived: true).first { $0["id"]?.stringValue == parts[1] }
                guard let alias else { throw ControlFailure(code: .entityChanged, message: "A previewed port alias no longer exists.") }
                current = alias["revision"]?.intValue ?? 1
            default:
                continue
            }
            guard current == expected else {
                throw ControlFailure(code: .entityChanged, message: "\(key) changed from revision \(expected) to \(current).")
            }
        }
    }

    private func validateOperationRuntimeEvidence(_ lease: OperationLease) async throws {
        for (target, expected) in lease.fingerprints {
            let current = try listener(stableID: target)
            guard current.process.fingerprint == expected else {
                throw ControlFailure(code: .identityMismatch, message: "The process fingerprint for \(target) changed after preview.")
            }
            if let fixtureID = lease.targetEvidence[target]?["development_fixture_id"]?.stringValue.flatMap(UUID.init(uuidString:)) {
                guard developmentMode,
                      await fixtureController.fixtureID(owningProcess: current.process.fingerprint.pid) == fixtureID else {
                    throw ControlFailure(code: .ownershipChanged, message: "The application-owned development fixture changed after preview.")
                }
                continue
            }
            let graph = await model.resolveOwnership(of: current)
            guard let old = lease.ownershipRoutes[target], ownershipSignature(graph) == ownershipSignature(old) else {
                throw ControlFailure(code: .ownershipChanged, message: "The controlling owner for \(target) changed after preview.")
            }
            let routeOperation = Self.serviceOperationTypes.contains(lease.type)
                || Self.projectOperationTypes.contains(lease.type)
                ? "stop_service"
                : lease.type
            try validateRoute(graph, for: routeOperation)
        }
        if Self.dockerOperationTypes.contains(lease.type) {
            for target in lease.targets {
                let current = try await currentContainer(matching: target)
                guard dockerEvidence(current) == lease.targetEvidence[target] else {
                    throw ControlFailure(code: .ownershipChanged, message: "Docker or Compose evidence for \(target) changed after preview.")
                }
            }
        }
    }

    private func ownershipSignature(_ graph: RuntimeOwnershipGraph) -> String {
        [
            graph.recommendation.controllerKind.rawValue,
            graph.managedRuntimeID?.uuidString ?? "-",
            graph.managedServiceID?.uuidString ?? "-",
            graph.managedConfigurationDigest ?? "-",
            graph.primaryConclusion.category.rawValue,
            graph.primaryConclusion.confidence.rawValue,
            graph.primaryConclusion.detectionMethod.rawValue
        ].joined(separator: "|")
    }

    private func dockerEvidence(_ container: DockerContainer) -> JSONValue {
        .object([
            "id": .string(container.id), "name": .string(container.name),
            "image": .string(container.image), "state": .string(container.state),
            "compose_project": container.composeProject.map(JSONValue.string) ?? .null,
            "compose_service": container.composeService.map(JSONValue.string) ?? .null,
            "compose_context": container.composeContext.flatMap { try? JSONValue.encode($0) } ?? .null,
            "ports": .array(container.ports.map { .object([
                "host": .number(Double($0.hostPort)), "container": .number(Double($0.containerPort)),
                "protocol": .string($0.protocolKind.rawValue)
            ]) })
        ])
    }

    private func currentContainer(matching target: String) async throws -> DockerContainer {
        let containers = try await model.dockerService.runningContainers()
        guard let container = containers.first(where: { $0.id == target || $0.name == target }) else {
            throw ControlFailure(code: .entityChanged, message: "The previewed Docker container is no longer running.")
        }
        return container
    }

    private func clearHistoryEvent(id: UUID) throws {
        let events = try store.context.fetch(FetchDescriptor<LifecycleEventRecord>())
        guard let event = events.first(where: { $0.id == id }) else {
            throw ControlFailure(code: .entityChanged, message: "The previewed history event no longer exists.")
        }
        let contexts = try store.context.fetch(FetchDescriptor<LifecycleEventContextRecord>())
        contexts.filter { $0.lifecycleEventID == id }.forEach(store.context.delete)
        store.context.delete(event)
        try store.context.save()
    }

    private func clearManagedLog(serviceID: UUID) throws {
        let service = try store.service(id: serviceID)
        guard let path = service.logFile, !path.isEmpty else {
            throw ControlFailure(code: .entityChanged, message: "The managed log path is no longer configured.")
        }
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw ControlFailure(code: .permissionDenied, message: "Managed logs may be cleared only when the configured target is an existing regular non-symlink file.")
        }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.truncate(atOffset: 0)
        try handle.close()
    }
}

extension ApplicationControlPlane {
    private static let changeSetTools: Set<String> = [
        "project_create", "project_update", "project_archive",
        "service_create", "service_update", "service_enable", "service_archive",
        "dependency_update", "port_watch_create", "port_watch_update", "port_watch_delete",
        "port_reservation_create", "port_reservation_update", "port_reservation_delete",
        "port_alias_create", "port_alias_update", "port_alias_delete",
        "port_ignore_rule_create", "port_ignore_rule_delete",
        "session_create", "session_update", "session_archive",
        "settings_update", "favorites_update", "tags_manage",
        "saved_filter_create", "saved_filter_update", "saved_filter_delete"
    ]

    func changeSetPreview(_ arguments: JSONValue) throws -> JSONValue {
        pruneLeases()
        guard let proposed = arguments["changes"]?.arrayValue, !proposed.isEmpty else {
            throw ControlFailure(code: .invalidArguments, message: "A non-empty changes array is required.")
        }
        guard proposed.count <= 100 else {
            throw ControlFailure(code: .resultTooLarge, message: "A change set may contain at most 100 steps.")
        }

        let currentProjects = Set(try store.projects(includeArchived: true).compactMap { $0["id"]?.stringValue })
        let currentServices = Set(try store.services(includeArchived: true).map { $0.id.uuidString })
        let currentSessions = Set(try store.sessions(includeArchived: true).map { $0.id.uuidString })
        var knownProjects = currentProjects
        var knownServices = currentServices
        var knownSessions = currentSessions
        var normalized: [(tool: String, arguments: JSONValue, originalIndex: Int)] = []
        var revisions: [String: Int] = [:]
        var compensation: [JSONValue] = []
        var warnings: [JSONValue] = []
        var reservedPorts = Set(try store.items(kind: "port_reservation", includeArchived: false).compactMap { $0["port"]?.intValue })
        let activePorts = Set(model.listeners.map { Int($0.port) })
        var dependencyGraph = Dictionary(uniqueKeysWithValues: try store.services(includeArchived: true).map { ($0.id, Set($0.dependencyServiceIDs)) })

        for (index, proposedChange) in proposed.enumerated() {
            guard var object = proposedChange.objectValue,
                  let tool = (object["tool"] ?? object["name"])?.stringValue,
                  Self.changeSetTools.contains(tool) else {
                throw ControlFailure(code: .unsupportedCapability, message: "Change-set step \(index) is not an allowed configuration tool.")
            }
            var stepArguments = object["arguments"]?.objectValue ?? [:]
            if tool == "project_create" {
                let id = stepArguments["id"]?.stringValue ?? UUID().uuidString
                guard UUID(uuidString: id) != nil, !knownProjects.contains(id) else {
                    throw ControlFailure(code: .conflictDetected, message: "Project ID in step \(index) is invalid or already exists.")
                }
                stepArguments["id"] = .string(id)
                knownProjects.insert(id)
                compensation.append(.object(["step": .number(Double(index)), "kind": .string("delete_project"), "id": .string(id)]))
            }
            if tool == "project_update" || tool == "project_archive" {
                let id = try changeSetID("project_id", arguments: stepArguments, index: index)
                guard knownProjects.contains(id) else { throw ControlFailure(code: .entityNotFound, message: "Project \(id) in step \(index) does not exist.") }
                if currentProjects.contains(id) {
                    let value = try store.projectValue(store.project(id: stableUUID(id, kind: "project")))
                    let revision = value["revision"]?.intValue ?? 1
                    try validateSuppliedRevision(stepArguments, expected: revision, kind: "project", id: id, index: index)
                    revisions["project:\(id)"] = revision
                    compensation.append(.object(["step": .number(Double(index)), "kind": .string("restore_project"), "value": value]))
                }
            }
            if tool == "service_create" {
                let id = stepArguments["id"]?.stringValue ?? stepArguments["configuration"]?["id"]?.stringValue ?? UUID().uuidString
                guard UUID(uuidString: id) != nil, !knownServices.contains(id) else {
                    throw ControlFailure(code: .conflictDetected, message: "Service ID in step \(index) is invalid or already exists.")
                }
                if var configuration = stepArguments["configuration"]?.objectValue {
                    configuration["id"] = .string(id)
                    stepArguments["configuration"] = .object(configuration)
                } else { stepArguments["id"] = .string(id) }
                if let projectID = stepArguments["project_id"]?.stringValue ?? stepArguments["configuration"]?["projectID"]?.stringValue,
                   !knownProjects.contains(projectID) {
                    throw ControlFailure(code: .missingDependency, message: "Service step \(index) references missing project \(projectID).")
                }
                let dependencies = serviceDependencyIDs(in: stepArguments)
                for dependency in dependencies where !knownServices.contains(dependency.uuidString) {
                    throw ControlFailure(code: .missingDependency, message: "Service step \(index) references missing dependency \(dependency.uuidString).")
                }
                dependencyGraph[UUID(uuidString: id)!] = Set(dependencies)
                knownServices.insert(id)
                compensation.append(.object(["step": .number(Double(index)), "kind": .string("delete_service"), "id": .string(id)]))
                if hasSecretReferences(stepArguments) {
                    warnings.append(.object(["step": .number(Double(index)), "code": .string("secret_reference_only"), "message": .string("Secret UUID references will be checked by the normal service persistence and launch gates; values are never returned.")]))
                }
            }
            if ["service_update", "service_enable", "service_archive"].contains(tool) {
                let id = try changeSetID("service_id", arguments: stepArguments, index: index)
                guard knownServices.contains(id) else { throw ControlFailure(code: .entityNotFound, message: "Service \(id) in step \(index) does not exist.") }
                if currentServices.contains(id) {
                    let service = try store.service(id: stableUUID(id, kind: "service"))
                    let value = try store.serviceValue(service)
                    let revision = value["revision"]?.intValue ?? 1
                    try validateSuppliedRevision(stepArguments, expected: revision, kind: "service", id: id, index: index)
                    revisions["service:\(id)"] = revision
                    compensation.append(.object(["step": .number(Double(index)), "kind": .string("restore_service"), "value": try JSONValue.encode(service)]))
                }
            }
            if tool == "dependency_update" {
                let serviceID = try changeSetID("service_id", arguments: stepArguments, index: index)
                let dependencyID = try changeSetID("dependency_service_id", arguments: stepArguments, index: index)
                guard knownServices.contains(serviceID), knownServices.contains(dependencyID),
                      let serviceUUID = UUID(uuidString: serviceID), let dependencyUUID = UUID(uuidString: dependencyID) else {
                    throw ControlFailure(code: .missingDependency, message: "Dependency step \(index) references a missing service.")
                }
                if stepArguments["action"]?.stringValue == "remove" { dependencyGraph[serviceUUID, default: []].remove(dependencyUUID) }
                else { dependencyGraph[serviceUUID, default: []].insert(dependencyUUID) }
            }
            if tool == "port_reservation_create", let port = stepArguments["port"]?.intValue {
                guard (1...65535).contains(port) else { throw ControlFailure(code: .invalidArguments, message: "Invalid reserved port in step \(index).") }
                guard !reservedPorts.contains(port), !activePorts.contains(port) else {
                    throw ControlFailure(code: .conflictDetected, message: "Port \(port) in step \(index) is already active or reserved.")
                }
                reservedPorts.insert(port)
            }
            if tool == "session_create" {
                let id = stepArguments["id"]?.stringValue ?? UUID().uuidString
                guard UUID(uuidString: id) != nil, !knownSessions.contains(id) else { throw ControlFailure(code: .conflictDetected, message: "Session ID in step \(index) already exists.") }
                stepArguments["id"] = .string(id)
                for serviceID in stepArguments["service_ids"]?.arrayValue?.compactMap(\.stringValue) ?? [] where !knownServices.contains(serviceID) {
                    throw ControlFailure(code: .missingDependency, message: "Session step \(index) references missing service \(serviceID).")
                }
                knownSessions.insert(id)
                compensation.append(.object(["step": .number(Double(index)), "kind": .string("delete_session"), "id": .string(id)]))
            }
            if tool == "session_update" || tool == "session_archive" {
                let id = try changeSetID("session_id", arguments: stepArguments, index: index)
                guard knownSessions.contains(id) else { throw ControlFailure(code: .entityNotFound, message: "Session \(id) in step \(index) does not exist.") }
                if currentSessions.contains(id) {
                    let session = try store.session(id: stableUUID(id, kind: "session"))
                    let value = try store.sessionValue(session)
                    let revision = value["revision"]?.intValue ?? 1
                    try validateSuppliedRevision(stepArguments, expected: revision, kind: "session", id: id, index: index)
                    revisions["session:\(id)"] = revision
                    compensation.append(.object(["step": .number(Double(index)), "kind": .string("restore_session"), "value": try JSONValue.encode(session)]))
                }
            }

            object["tool"] = .string(tool)
            object.removeValue(forKey: "name")
            object["arguments"] = .object(stepArguments)
            normalized.append((tool, .object(stepArguments), index))
        }
        try validateDependencyGraph(dependencyGraph)

        let rank: [String: Int] = ["project_create": 0, "service_create": 1, "dependency_update": 2, "port_reservation_create": 3, "session_create": 4]
        normalized.sort { (rank[$0.tool] ?? 10, $0.originalIndex) < (rank[$1.tool] ?? 10, $1.originalIndex) }
        let ordered: [JSONValue] = normalized.map { .object([
            "tool": .string($0.tool), "arguments": $0.arguments,
            "original_index": .number(Double($0.originalIndex))
        ]) }
        let token = UUID()
        let expiresAt = Date().addingTimeInterval(ControlProtocolConstants.changeSetLifetimeSeconds)
        changeSetLeases[token] = ChangeSetLease(
            id: token, changes: ordered, stateVersion: mutationVersion, revisions: revisions,
            compensation: compensation, createdAt: Date(), expiresAt: expiresAt, used: false
        )
        return .object([
            "change_set_token": .string(token.uuidString), "valid": .bool(true),
            "ordered_plan": .array(ordered), "warnings": .array(warnings),
            "runtime_operations_required": .array([]),
            "entity_revisions": .object(revisions.mapValues { .number(Double($0)) }),
            "compensation": .string("Created records are removed and updated project, service, and session records are restored if a later configuration step fails."),
            "expires_at": .string(expiresAt.ISO8601Format())
        ])
    }

    func changeSetExecute(_ arguments: JSONValue, request: ControlRequest) async throws -> JSONValue {
        let token = try requiredUUID("change_set_token", arguments)
        guard let lease = changeSetLeases[token] else {
            throw ControlFailure(code: .changeSetExpired, message: "No active change-set preview matches this token.")
        }
        return try await executeChangeSetLease(lease, request: request)
    }

    func executeChangeSetLease(_ lease: ChangeSetLease, request: ControlRequest?) async throws -> JSONValue {
        guard lease.expiresAt > Date() else {
            changeSetLeases.removeValue(forKey: lease.id)
            throw ControlFailure(code: .changeSetExpired, message: "The change-set preview expired.")
        }
        guard !lease.used else { throw ControlFailure(code: .operationAlreadyUsed, message: "This change set has already been used.") }
        guard mutationVersion == lease.stateVersion else { throw ControlFailure(code: .staleSnapshot, message: "Application configuration changed after change-set preview.") }
        try validateChangeSetRevisions(lease.revisions)
        var marked = lease
        marked.used = true
        changeSetLeases[lease.id] = marked

        let executionRequest = request ?? ControlRequest(
            handshake: ControlHandshake(client: ControlClientIdentity(name: "DevBerth control host", version: "1", developmentMode: developmentMode)),
            toolName: "change_set_execute", source: .system
        )
        var results: [JSONValue] = []
        var completedOriginalIndexes = Set<Int>()
        do {
            for (orderedIndex, change) in lease.changes.enumerated() {
                guard let tool = change["tool"]?.stringValue, let stepArguments = change["arguments"],
                      let originalIndex = change["original_index"]?.intValue else { continue }
                let value = try await dispatch(tool: tool, arguments: stepArguments, request: executionRequest)
                completedOriginalIndexes.insert(originalIndex)
                results.append(.object([
                    "ordered_index": .number(Double(orderedIndex)), "original_index": .number(Double(originalIndex)),
                    "tool": .string(tool), "status": .string("succeeded"), "result": value
                ]))
            }
            mutationVersion &+= 1
            return .object(["change_set_token": .string(lease.id.uuidString), "status": .string("succeeded"), "steps": .array(results)])
        } catch {
            let compensationResults = applyChangeSetCompensation(lease.compensation, completedOriginalIndexes: completedOriginalIndexes)
            throw ControlFailure(
                code: (error as? ControlFailure)?.code ?? .internalError,
                message: "Change-set execution failed and compensation was attempted: \(error.localizedDescription)",
                details: .object(["steps": .array(results), "compensation": .array(compensationResults)])
            )
        }
    }

    private func changeSetID(_ key: String, arguments: [String: JSONValue], index: Int) throws -> String {
        guard let value = arguments[key]?.stringValue, UUID(uuidString: value) != nil else {
            throw ControlFailure(code: .invalidArguments, message: "Change-set step \(index) requires stable UUID field \(key).")
        }
        return value
    }

    private func validateSuppliedRevision(
        _ arguments: [String: JSONValue], expected: Int, kind: String, id: String, index: Int
    ) throws {
        guard let supplied = arguments["revision"]?.intValue else {
            throw ControlFailure(code: .invalidArguments, message: "Change-set step \(index) must include the current revision for \(kind) \(id).")
        }
        guard supplied == expected else {
            throw ControlFailure(code: .entityChanged, message: "\(kind.capitalized) \(id) is revision \(expected), not \(supplied).")
        }
    }

    private func serviceDependencyIDs(in arguments: [String: JSONValue]) -> [UUID] {
        let values = arguments["dependency_service_ids"]?.arrayValue
            ?? arguments["dependencyServiceIDs"]?.arrayValue
            ?? arguments["configuration"]?["dependencyServiceIDs"]?.arrayValue
            ?? []
        return values.compactMap { $0.stringValue.flatMap(UUID.init(uuidString:)) }
    }

    private func hasSecretReferences(_ arguments: [String: JSONValue]) -> Bool {
        let references = arguments["secret_references"]?.objectValue
            ?? arguments["secretReferences"]?.objectValue
            ?? arguments["configuration"]?["secretReferences"]?.objectValue
        return references?.isEmpty == false
    }

    private func validateDependencyGraph(_ graph: [UUID: Set<UUID>]) throws {
        var visiting = Set<UUID>()
        var visited = Set<UUID>()
        func visit(_ id: UUID) throws {
            if visiting.contains(id) {
                throw ControlFailure(code: .dependencyCycle, message: "The proposed dependency changes contain a cycle at service \(id.uuidString).")
            }
            guard !visited.contains(id) else { return }
            visiting.insert(id)
            for dependency in graph[id] ?? [] {
                guard graph[dependency] != nil else {
                    throw ControlFailure(code: .missingDependency, message: "Service \(id.uuidString) references missing dependency \(dependency.uuidString).")
                }
                try visit(dependency)
            }
            visiting.remove(id)
            visited.insert(id)
        }
        for id in graph.keys { try visit(id) }
    }

    private func validateChangeSetRevisions(_ revisions: [String: Int]) throws {
        for (key, expected) in revisions {
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let current: Int
            switch parts[0] {
            case "project": current = try store.projectValue(store.project(id: stableUUID(parts[1], kind: "project")))["revision"]?.intValue ?? 1
            case "service": current = try store.serviceValue(store.service(id: stableUUID(parts[1], kind: "service")))["revision"]?.intValue ?? 1
            case "session": current = try store.sessionValue(store.session(id: stableUUID(parts[1], kind: "session")))["revision"]?.intValue ?? 1
            default: continue
            }
            guard current == expected else {
                throw ControlFailure(code: .entityChanged, message: "\(key) changed from revision \(expected) to \(current).")
            }
        }
    }

    private func applyChangeSetCompensation(
        _ actions: [JSONValue], completedOriginalIndexes: Set<Int>
    ) -> [JSONValue] {
        actions.reversed().compactMap { action in
            guard let step = action["step"]?.intValue, completedOriginalIndexes.contains(step),
                  let kind = action["kind"]?.stringValue else { return nil }
            do {
                switch kind {
                case "delete_project":
                    try store.deleteProject(id: requiredCompensationUUID(action), allowReferences: true)
                case "delete_service":
                    try store.deleteService(id: requiredCompensationUUID(action), allowReferences: true)
                case "delete_session":
                    try store.deleteSession(id: requiredCompensationUUID(action), allowHistory: true)
                case "restore_project":
                    guard let value = action["value"], let id = value["id"]?.stringValue.flatMap(UUID.init(uuidString:)) else { return nil }
                    let current = try store.projectValue(store.project(id: id))["revision"]?.intValue ?? 1
                    _ = try store.updateProject(id: id, arguments: .object(["revision": .number(Double(current)), "patch": value]))
                    if let archived = value["archived"]?.boolValue {
                        _ = try store.archive(kind: "project", id: id, archived: archived, suppliedRevision: nil)
                    }
                case "restore_service":
                    guard let value = action["value"] else { return nil }
                    let service = try value.decode(ManagedServiceConfiguration.self)
                    try ManagedServicePersistence.save(service, in: store.context)
                    try store.context.save()
                case "restore_session":
                    guard let value = action["value"] else { return nil }
                    _ = try store.saveSession(value.decode(WorkspaceSession.self))
                default:
                    return .object(["step": .number(Double(step)), "kind": .string(kind), "status": .string("not_available")])
                }
                return .object(["step": .number(Double(step)), "kind": .string(kind), "status": .string("succeeded")])
            } catch {
                return .object(["step": .number(Double(step)), "kind": .string(kind), "status": .string("failed"), "message": .string(error.localizedDescription)])
            }
        }
    }

    private func requiredCompensationUUID(_ action: JSONValue) throws -> UUID {
        guard let id = action["id"]?.stringValue.flatMap(UUID.init(uuidString:)) else {
            throw ControlFailure(code: .internalError, message: "Compensation action is missing its stable ID.")
        }
        return id
    }
}
