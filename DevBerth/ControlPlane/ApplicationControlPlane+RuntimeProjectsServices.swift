import DevBerthControlContracts
import Foundation
import SwiftData

extension ApplicationControlPlane {
    func runtimeSnapshot() throws -> JSONValue {
        let listeners = try model.listeners.map(runtimeListenerValue)
        let services = try store.services()
        let projects = try store.projects()
        let unhealthy = model.runtimeStatuses.compactMap { id, status in
            status.healthState == .unhealthy || status.lifecycleState == .failed ? id.uuidString : nil
        }
        let conflicts = services.flatMap { service in
            PortConflictDetector.conflicts(for: service, listeners: model.listeners).map { conflict in
                JSONValue.object([
                    "service_id": .string(service.id.uuidString),
                    "listener_id": .string(conflict.listener.id),
                    "port": .number(Double(conflict.expectedPort.port))
                ])
            }
        }
        let managedPorts = Set(services.flatMap { $0.expectedPorts.map(\.port) })
        let unexpected = model.listeners.filter { !managedPorts.contains($0.port) }
        return .object([
            "snapshot_version": .number(Double(snapshotVersion)),
            "captured_at": .string((model.lastRefresh ?? Date()).ISO8601Format()),
            "monitoring_enabled": .bool(model.isMonitoring),
            "listeners": .array(listeners),
            "counts": .object([
                "active_listeners": .number(Double(model.listeners.count)),
                "observed_processes": .number(Double(Set(model.listeners.map { $0.process.fingerprint }).count)),
                "managed_runtimes": .number(Double(model.managedRunningServiceIDs.count)),
                "projects": .number(Double(projects.count)),
                "managed_services": .number(Double(services.count)),
                "unhealthy_services": .number(Double(unhealthy.count)),
                "conflicts": .number(Double(conflicts.count)),
                "unexpected_listeners": .number(Double(unexpected.count))
            ]),
            "unhealthy_service_ids": .array(unhealthy.map(JSONValue.string)),
            "conflicts": .array(conflicts),
            "unexpected_listener_ids": .array(unexpected.map { .string($0.id) }),
            "recent_changes": .array(try model.recentChanges.map(runtimeListenerValue))
        ])
    }

    func runtimeSearch(_ arguments: JSONValue) throws -> JSONValue {
        let values = arguments.objectValue ?? [:]
        let query = values["query"]?.stringValue?.lowercased() ?? ""
        let filters = values["filters"]?.objectValue ?? values
        let port = filters["port"]?.intValue.flatMap(UInt16.init(exactly:))
        let pid = filters["pid"]?.intValue.flatMap(Int32.init(exactly:))
        let project = filters["project"]?.stringValue?.lowercased()
        let serviceID = filters["service_id"]?.stringValue.flatMap(UUID.init(uuidString:))
        let docker = filters["docker"]?.boolValue
        let matched = model.listeners.filter { listener in
            let haystack = [
                String(listener.port), String(listener.process.fingerprint.pid), listener.process.name,
                listener.process.commandLine, listener.process.executablePath ?? "",
                listener.process.project?.name ?? "", listener.process.managedServiceID?.uuidString ?? ""
            ].joined(separator: " ").lowercased()
            return (query.isEmpty || haystack.contains(query))
                && (port == nil || listener.port == port)
                && (pid == nil || listener.process.fingerprint.pid == pid)
                && (project == nil || listener.process.project?.name.lowercased().contains(project!) == true)
                && (serviceID == nil || listener.process.managedServiceID == serviceID)
                && (docker == nil || (listener.process.docker != nil) == docker)
        }
        return .object(["results": .array(try matched.map(runtimeListenerValue)), "count": .number(Double(matched.count))])
    }

    func runtimeInspect(_ arguments: JSONValue) async throws -> JSONValue {
        let listener = try requiredListener(arguments)
        let graph = await model.resolveOwnership(of: listener)
        var value = try runtimeListenerValue(listener).objectValue ?? [:]
        value["ownership"] = try JSONValue.encode(graph)
        value["resource_usage"] = try model.processResourceUsage[listener.process.fingerprint.pid].map(JSONValue.encode) ?? .null
        value["allowed_actions"] = .array(graph.recommendation.supportedActions.map { .string($0.rawValue) }.sorted { $0.stringValue! < $1.stringValue! })
        if let serviceID = listener.process.managedServiceID,
           let service = try? store.service(id: serviceID) {
            value["managed_service"] = try store.serviceValue(service)
        }
        return .object(value)
    }

    func runtimeExplain(_ arguments: JSONValue) async throws -> JSONValue {
        let listener = try requiredListener(arguments)
        let graph = await model.resolveOwnership(of: listener)
        let verifiedRestart = graph.recommendation.supportedActions.contains(.restart)
            && graph.managedServiceID != nil
            && graph.managedConfigurationDigest != nil
        return .object([
            "listener_id": .string(listener.id),
            "why_running": .string(graph.primaryConclusion.value),
            "launched_by": .string(graph.primaryConclusion.category.title),
            "controlled_by": .string(graph.recommendation.controllerKind.rawValue),
            "may_return_after_stop": .bool([.homebrewService, .launchAgent, .launchDaemon, .supervisorManagedProcess].contains(graph.primaryConclusion.category)),
            "safest_action": .string(graph.recommendation.title),
            "safety_reason": .string(graph.recommendation.reason),
            "restart_reliable": .bool(verifiedRestart),
            "confidence": .string(graph.primaryConclusion.confidence.rawValue),
            "detection_method": .string(graph.primaryConclusion.detectionMethod.rawValue),
            "evidence": try JSONValue.encode(graph.primaryConclusion.evidence),
            "process_lineage": try JSONValue.encode(graph.processLineage),
            "observed_at": .string(graph.resolvedAt.ISO8601Format())
        ])
    }

    func projectInspect(_ arguments: JSONValue) throws -> JSONValue {
        let id = try requiredUUID("project_id", arguments)
        let project = try store.project(id: id)
        let services = try store.services(includeArchived: true).filter { $0.projectID == id }
        let serviceValues = try services.map(store.serviceValue)
        let activeListeners = model.listeners.filter { listener in
            services.contains { $0.id == listener.process.managedServiceID }
                || listener.process.project?.rootPath == project.folderPath
        }
        let conflicts = services.flatMap { PortConflictDetector.conflicts(for: $0, listeners: model.listeners) }
        let sessions = try store.sessions(includeArchived: true).filter { $0.projectIDs.contains(id) }
        var value = try store.projectValue(project).objectValue ?? [:]
        value["services"] = .array(serviceValues)
        value["runtime_listeners"] = .array(try activeListeners.map(runtimeListenerValue))
        value["expected_ports"] = .array(services.flatMap { $0.expectedPorts }.map { .number(Double($0.port)) })
        value["conflict_listener_ids"] = .array(conflicts.map { .string($0.listener.id) })
        value["session_ids"] = .array(sessions.map { .string($0.id.uuidString) })
        value["available_actions"] = .array([.string("validate"), .string("start"), .string("stop_preview"), .string("restart_preview")])
        return .object(value)
    }

    func projectDiscover(_ arguments: JSONValue) async throws -> JSONValue {
        let root = try requiredString("root_path", arguments)
        let report = try await model.discoverProject(at: root)
        let id = UUID()
        discoveryLeases[id] = DiscoveryLease(report: report, expiresAt: Date().addingTimeInterval(600))
        pruneLeases()
        return .object([
            "discovery_id": .string(id.uuidString),
            "expires_at": .string(Date().addingTimeInterval(600).ISO8601Format()),
            "report": try JSONValue.encode(report),
            "warning": .string("Candidates are inferred, unreviewed, and have not been saved or executed.")
        ])
    }

    func projectApplyDiscovery(_ arguments: JSONValue) throws -> JSONValue {
        let discoveryID = try requiredUUID("discovery_id", arguments)
        guard let lease = discoveryLeases[discoveryID], lease.expiresAt > Date() else {
            throw ControlFailure(code: .staleSnapshot, message: "The discovery result expired; run project_discover again.")
        }
        let projectID: UUID
        if let value = arguments["project_id"]?.stringValue.flatMap(UUID.init(uuidString:)) {
            _ = try store.project(id: value)
            projectID = value
        } else {
            let project = try store.createProject(arguments: .object([
                "name": arguments["project_name"] ?? .string(URL(fileURLWithPath: lease.report.rootPath).lastPathComponent),
                "folder_path": .string(lease.report.rootPath)
            ]))
            projectID = UUID(uuidString: project["id"]!.stringValue!)!
        }
        let selectedIDs = Set(arguments["candidate_ids"]?.arrayValue?.compactMap { $0.stringValue.flatMap(UUID.init(uuidString:)) } ?? lease.report.candidates.map(\.id))
        let candidates = lease.report.candidates.filter { selectedIDs.contains($0.id) }
        guard !candidates.isEmpty else { throw ControlFailure(code: .invalidArguments, message: "Select at least one current discovery candidate.") }
        let result = try ProjectDiscoveryImporter.importCandidates(
            candidates,
            report: lease.report,
            projectID: projectID,
            into: store.context
        )
        for id in result.importedServiceIDs {
            _ = try store.archive(kind: "service", id: id, archived: false, suppliedRevision: nil)
        }
        mutationVersion &+= 1
        return .object([
            "project_id": .string(projectID.uuidString),
            "imported_service_ids": .array(result.importedServiceIDs.map { .string($0.uuidString) }),
            "unresolved_dependencies": .array(result.unresolvedDependencies.map(JSONValue.string)),
            "review_required": .bool(true)
        ])
    }

    func projectImport(_ arguments: JSONValue) async throws -> JSONValue {
        let discovered = try await projectDiscover(arguments)
        guard arguments["apply"]?.boolValue == true else {
            return .object([
                "preview": discovered,
                "requires_apply": .bool(true),
                "next_tool": .string("project_apply_discovery")
            ])
        }
        guard let discoveryID = discovered["discovery_id"] else { return discovered }
        var values = arguments.objectValue ?? [:]
        values["discovery_id"] = discoveryID
        return try mutated { try projectApplyDiscovery(.object(values)) }
    }

    func projectExport(_ arguments: JSONValue) throws -> JSONValue {
        let id = try requiredUUID("project_id", arguments)
        let project = try store.project(id: id)
        guard let root = project.folderPath else {
            throw ControlFailure(code: .invalidArguments, message: "The project needs a working directory before export.")
        }
        let services = try store.services().filter { $0.projectID == id }
        let data = try DevBerthManifestCodec().encode(
            projectName: project.name,
            projectRoot: URL(fileURLWithPath: root, isDirectory: true),
            services: services
        )
        let url = try exportURL(prefix: "project-\(safeFilename(project.name))", extension: "json")
        try data.write(to: url, options: .atomic)
        return .object([
            "path": .string(url.path),
            "format": .string("devberth-runtime-v1"),
            "service_count": .number(Double(services.count)),
            "lost_semantics": .array([])
        ])
    }

    func projectValidate(_ arguments: JSONValue) throws -> JSONValue {
        let id = try requiredUUID("project_id", arguments)
        _ = try store.project(id: id)
        let services = try store.services().filter { $0.projectID == id }
        var issues = services.flatMap { service in
            ManagedServiceValidator.validate(service).map { issue in
                JSONValue.object([
                    "service_id": .string(service.id.uuidString),
                    "field": .string(issue.field),
                    "message": .string(issue.message),
                    "severity": .string(issue.severity == .error ? "error" : "warning")
                ])
            }
        }
        do { _ = try DependencyPlanner.orderedLayers(for: services) }
        catch { issues.append(.object(["field": .string("dependencies"), "message": .string(error.localizedDescription), "severity": .string("error")])) }
        for service in services {
            for conflict in PortConflictDetector.conflicts(for: service, listeners: model.listeners) {
                issues.append(.object([
                    "service_id": .string(service.id.uuidString),
                    "field": .string("expected_ports"),
                    "message": .string("Port \(conflict.expectedPort.port) is occupied by listener \(conflict.listener.id)."),
                    "severity": .string("warning")
                ]))
            }
        }
        return .object(["valid": .bool(!issues.contains { $0["severity"]?.stringValue == "error" }), "issues": .array(issues)])
    }

    func serviceInspect(_ arguments: JSONValue) async throws -> JSONValue {
        let id = try requiredUUID("service_id", arguments)
        let service = try store.service(id: id)
        var value = try store.serviceValue(service).objectValue ?? [:]
        let validations = try store.context.fetch(FetchDescriptor<ManagedServiceValidationRecord>())
        value["validation"] = try validations.first { $0.managedServiceID == id }?.result.map(JSONValue.encode) ?? .null
        value["runtime_status"] = try model.runtimeStatuses[id].map(JSONValue.encode) ?? .null
        value["running"] = .bool(model.managedRunningServiceIDs.contains(id))
        value["configuration_digest"] = .string(ManagedServiceConfigurationDigest.make(for: service))
        let resolution = await model.secretReferenceResolution(for: service.secretReferences)
        value["secret_references"] = .object(resolution.mapValues { .object([
            "configured": .bool(true), "resolves": .bool($0)
        ]) })
        value["allowed_actions"] = .array([
            .string("update"), .string("duplicate"), .string("verify"), .string("start"),
            .string("stop_preview"), .string("restart_preview")
        ])
        return .object(value)
    }

    func serviceAdoptRuntime(_ arguments: JSONValue) throws -> JSONValue {
        let listener = try requiredListener(arguments)
        guard listener.process.managedServiceID == nil else {
            throw ControlFailure(code: .conflictDetected, message: "This runtime is already associated with a managed service.")
        }
        let command = listener.process.executablePath ?? listener.process.name
        let configuration = ManagedServiceConfiguration(
            name: arguments["name"]?.stringValue ?? listener.process.name,
            projectID: arguments["project_id"]?.stringValue.flatMap(UUID.init(uuidString:)),
            launchMechanism: .executable,
            command: command,
            arguments: [],
            workingDirectory: listener.process.currentDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path,
            expectedPorts: [.init(id: UUID(), port: listener.port, protocolKind: listener.protocolKind, required: true)],
            restartPolicy: .never,
            tags: ["adopted", "inferred"],
            launchesAutomatically: false,
            isFavorite: false,
            isReviewed: false
        )
        return try store.createService(arguments: .object(["configuration": try JSONValue.encode(configuration)]))
    }

    func serviceVerify(_ arguments: JSONValue) async throws -> JSONValue {
        let id = try requiredUUID("service_id", arguments)
        let service = try store.service(id: id)
        let result = await model.validateManagedService(service)
        if result.succeeded {
            let refreshRequestedAt = Date()
            model.refreshNow()
            for _ in 0..<50 where model.lastRefresh.map({ $0 < refreshRequestedAt }) ?? true {
                try await Task.sleep(for: .milliseconds(100))
            }
            guard model.lastRefresh.map({ $0 >= refreshRequestedAt }) == true else {
                throw ControlFailure(
                    code: .timeout,
                    message: "Service verification succeeded, but the runtime snapshot did not refresh after the isolated service stopped. Retry verification."
                )
            }
            try await model.recordRestartTrust(for: service, validation: result)
        }
        return .object([
            "service_id": .string(id.uuidString),
            "succeeded": .bool(result.succeeded),
            "validation": try JSONValue.encode(result),
            "verified_restartable": .bool(result.succeeded && result.configurationDigest == ManagedServiceConfigurationDigest.make(for: service))
        ])
    }

    func serviceStart(_ arguments: JSONValue) async throws -> JSONValue {
        let id = try requiredUUID("service_id", arguments)
        let service = try store.service(id: id)
        guard try store.serviceIsEnabled(id: id) else {
            throw ControlFailure(code: .permissionDenied, message: "The managed service is disabled. Enable it before starting.")
        }
        if model.managedRunningServiceIDs.contains(id) {
            return .object(["service_id": .string(id.uuidString), "already_running": .bool(true)])
        }
        await model.launchProfile(service)
        guard model.presentedError == nil, model.pendingLaunchConflict == nil else {
            if let conflict = model.pendingLaunchConflict {
                throw ControlFailure(
                    code: .conflictDetected,
                    message: "Port \(conflict.conflict.expectedPort.port) is occupied; preview conflict resolution before starting."
                )
            }
            throw ControlFailure(code: .serviceNotVerified, message: model.presentedError?.localizedDescription ?? "The service did not start.")
        }
        return .object([
            "service_id": .string(id.uuidString),
            "started": .bool(true),
            "wait_level": arguments["wait_level"] ?? .string("ready")
        ])
    }

    func serviceRecover(_ arguments: JSONValue) async throws -> JSONValue {
        let id = try requiredUUID("service_id", arguments)
        let service = try store.service(id: id)
        guard service.restartPolicy != .never else {
            throw ControlFailure(code: .unsupportedCapability, message: "The service has no configured recovery action.")
        }
        if model.managedRunningServiceIDs.contains(id) { await model.stopProfile(service) }
        return try await serviceStart(.object(["service_id": .string(id.uuidString), "wait_level": .string("healthy")]))
    }

    func dependencyGraph() throws -> JSONValue {
        let services = try store.services(includeArchived: true)
        return .object([
            "nodes": .array(try services.map(store.serviceValue)),
            "edges": .array(services.flatMap { service in service.dependencyServiceIDs.map { dependency in
                .object(["service_id": .string(service.id.uuidString), "depends_on": .string(dependency.uuidString), "required": .bool(true)])
            }})
        ])
    }

    func dependencyUpdate(_ arguments: JSONValue) throws -> JSONValue {
        let id = try requiredUUID("service_id", arguments)
        var service = try store.service(id: id)
        let action = arguments["action"]?.stringValue ?? "add"
        let dependencyID = try requiredUUID("dependency_service_id", arguments)
        _ = try store.service(id: dependencyID)
        if action == "remove" { service.dependencyServiceIDs.removeAll { $0 == dependencyID } }
        else if !service.dependencyServiceIDs.contains(dependencyID) { service.dependencyServiceIDs.append(dependencyID) }
        var all = try store.services(includeArchived: true).filter { $0.id != id }
        all.append(service)
        do { _ = try DependencyPlanner.orderedLayers(for: all) }
        catch { throw ControlFailure(code: .dependencyCycle, message: error.localizedDescription) }
        let encodedDependencies = try JSONValue.encode(service.dependencyServiceIDs)
        let updated = try store.updateService(
            id: id,
            arguments: .object([
                "revision": arguments["revision"] ?? .number(Double(try store.revision(kind: "service", id: id.uuidString))),
                "patch": .object(["dependencyServiceIDs": encodedDependencies])
            ])
        )
        mutationVersion &+= 1
        return updated
    }

    func dependencyValidate(_ arguments: JSONValue) throws -> JSONValue {
        let services: [ManagedServiceConfiguration]
        if let projectID = arguments["project_id"]?.stringValue.flatMap(UUID.init(uuidString:)) {
            services = try store.services(includeArchived: true).filter { $0.projectID == projectID }
        } else { services = try store.services(includeArchived: true) }
        do {
            let layers = try DependencyPlanner.orderedLayers(for: services)
            return .object([
                "valid": .bool(true),
                "layers": .array(layers.map { .array($0.map { .string($0.id.uuidString) }) }),
                "cycles": .array([]), "missing_services": .array([]), "warnings": .array([])
            ])
        } catch let error as DependencyGraphError {
            return .object(["valid": .bool(false), "error": .string(error.localizedDescription), "cycles": .array([])])
        }
    }

    func runtimeListenerValue(_ listener: ObservedListener) throws -> JSONValue {
        var value = try JSONValue.encode(listener).objectValue ?? [:]
        if let usage = model.processResourceUsage[listener.process.fingerprint.pid] {
            value["resource_usage"] = try JSONValue.encode(usage)
        }
        if let serviceID = listener.process.managedServiceID, let status = model.runtimeStatuses[serviceID] {
            value["runtime_status"] = try JSONValue.encode(status)
        }
        value["stable_id"] = .string(listener.id)
        return .object(value)
    }

    func requiredListener(_ arguments: JSONValue) throws -> ObservedListener {
        let values = arguments.objectValue ?? [:]
        let identifier = values["listener_id"]?.stringValue
            ?? values["runtime_id"]?.stringValue
            ?? values["port_id"]?.stringValue
            ?? values["id"]?.stringValue
        if let identifier, let listener = model.listeners.first(where: { $0.id == identifier }) { return listener }
        if let port = values["port"]?.intValue.flatMap(UInt16.init(exactly:)),
           let listener = model.listeners.first(where: { $0.port == port }) { return listener }
        throw ControlFailure(code: .entityNotFound, message: "No current listener matches the supplied stable identifier.")
    }

    func requiredUUID(_ key: String, _ arguments: JSONValue) throws -> UUID {
        let fallback = arguments["id"]?.stringValue
        guard let raw = arguments[key]?.stringValue ?? fallback, let value = UUID(uuidString: raw) else {
            throw ControlFailure(code: .invalidArguments, message: "A valid \(key) is required.")
        }
        return value
    }

    func requiredString(_ key: String, _ arguments: JSONValue) throws -> String {
        guard let value = arguments[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            throw ControlFailure(code: .invalidArguments, message: "A non-empty \(key) is required.")
        }
        return value
    }

    func exportURL(prefix: String, extension pathExtension: String) throws -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(ProductIdentity.currentSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(prefix)-\(UUID().uuidString).\(pathExtension)")
    }

    func safeFilename(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let transformed = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        return String(transformed).prefix(60).lowercased()
    }

    func pruneLeases() {
        let now = Date()
        discoveryLeases = discoveryLeases.filter { $0.value.expiresAt > now }
        operationLeases = operationLeases.filter { $0.value.expiresAt > now || $0.value.used }
        changeSetLeases = changeSetLeases.filter { $0.value.expiresAt > now || $0.value.used }
    }
}
