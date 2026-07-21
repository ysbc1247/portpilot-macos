import Darwin
import DevBerthControlContracts
import Foundation

extension ApplicationControlPlane {
    func sessionInspect(_ arguments: JSONValue) throws -> JSONValue {
        try store.sessionValue(store.session(id: requiredUUID("session_id", arguments)))
    }

    func sessionCreate(_ arguments: JSONValue) throws -> JSONValue {
        if let value = arguments["session"] { return try store.saveSession(value.decode(WorkspaceSession.self)) }
        let name = try requiredString("name", arguments)
        let id = arguments["id"]?.stringValue.flatMap(UUID.init(uuidString:)) ?? UUID()
        let projectIDs = arguments["project_ids"]?.arrayValue?.compactMap { $0.stringValue.flatMap(UUID.init(uuidString:)) } ?? []
        let expected = arguments["services"]?.arrayValue ?? []
        let configurations = try store.services(includeArchived: true)
        let snapshots = try expected.map { value -> WorkspaceSessionServiceSnapshot in
            let serviceID = try requiredUUID("service_id", value)
            guard let service = configurations.first(where: { $0.id == serviceID }) else {
                throw ControlFailure(code: .entityNotFound, message: "No managed service exists with ID \(serviceID.uuidString).")
            }
            return WorkspaceSessionServiceSnapshot(
                managedServiceID: serviceID,
                expectedState: value["expected_state"]?.stringValue.flatMap(ExpectedServiceState.init(rawValue:)) ?? .stopped,
                expectedListeners: service.expectedPorts,
                dependencyServiceIDs: service.dependencyServiceIDs,
                previousHealthState: model.runtimeStatuses[serviceID]?.healthState ?? .unknown,
                configurationDigest: ManagedServiceConfigurationDigest.make(for: service)
            )
        }
        return try store.saveSession(WorkspaceSession(
            id: id,
            name: name,
            projectIDs: projectIDs,
            serviceSnapshots: snapshots,
            notes: arguments["notes"]?.stringValue
        ))
    }

    func sessionCapture(_ arguments: JSONValue) async throws -> JSONValue {
        let configurations = try store.services()
        let projectIDs = arguments["project_ids"]?.arrayValue?.compactMap { $0.stringValue.flatMap(UUID.init(uuidString:)) }
            ?? Array(Set(configurations.compactMap(\.projectID)))
        let selectedServiceIDs = Set(arguments["service_ids"]?.arrayValue?.compactMap { $0.stringValue.flatMap(UUID.init(uuidString:)) }
            ?? configurations.filter { service in service.projectID.map(projectIDs.contains) ?? false }.map(\.id))
        let selected = configurations.filter { selectedServiceIDs.contains($0.id) }
        let roots = Set(try projectIDs.compactMap { try store.project(id: $0).folderPath })
        guard let captured = await model.captureWorkspaceSession(
            name: arguments["name"]?.stringValue ?? "Workspace \(Date().formatted(date: .abbreviated, time: .shortened))",
            projectIDs: projectIDs,
            services: selected,
            projectRootPaths: roots,
            notes: arguments["notes"]?.stringValue
        ) else {
            throw ControlFailure(code: .internalError, message: "The workspace session could not be captured.")
        }
        _ = try store.archive(kind: "session", id: captured.id, archived: false, suppliedRevision: nil)
        mutationVersion &+= 1
        return try store.sessionValue(captured)
    }

    func sessionUpdate(_ arguments: JSONValue) throws -> JSONValue {
        let id = try requiredUUID("session_id", arguments)
        if let supplied = arguments["revision"]?.intValue {
            let current = try store.revision(kind: "session", id: id.uuidString)
            guard supplied == current else {
                throw ControlFailure(code: .entityChanged, message: "The session changed from revision \(supplied) to \(current).")
            }
        }
        let existing = try store.session(id: id)
        let patch = arguments["patch"]?.objectValue ?? arguments.objectValue ?? [:]
        let name = patch["name"]?.stringValue ?? existing.name
        let notes: String? = patch.keys.contains("notes") ? patch["notes"]?.stringValue : existing.notes
        let projects = patch["project_ids"]?.arrayValue?.compactMap { $0.stringValue.flatMap(UUID.init(uuidString:)) } ?? existing.projectIDs
        var snapshots = existing.serviceSnapshots
        if let included = patch["service_ids"]?.arrayValue {
            let ids = Set(included.compactMap { $0.stringValue.flatMap(UUID.init(uuidString:)) })
            snapshots.removeAll { !ids.contains($0.managedServiceID) }
        }
        return try store.saveSession(WorkspaceSession(
            id: id,
            name: name,
            projectIDs: projects,
            serviceSnapshots: snapshots,
            capturedAt: existing.capturedAt,
            notes: notes
        ))
    }

    func sessionUpdateFromRuntime(_ arguments: JSONValue) throws -> JSONValue {
        let id = try requiredUUID("session_id", arguments)
        let session = try store.session(id: id)
        let services = try store.services(includeArchived: true)
        let selected = Set(arguments["service_ids"]?.arrayValue?.compactMap { $0.stringValue.flatMap(UUID.init(uuidString:)) }
            ?? session.serviceSnapshots.map(\.managedServiceID))
        let refreshed = session.serviceSnapshots.map { snapshot -> WorkspaceSessionServiceSnapshot in
            guard selected.contains(snapshot.managedServiceID),
                  let service = services.first(where: { $0.id == snapshot.managedServiceID }) else { return snapshot }
            return WorkspaceSessionServiceSnapshot(
                managedServiceID: service.id,
                expectedState: model.managedRunningServiceIDs.contains(service.id) ? .running : .stopped,
                expectedListeners: service.expectedPorts,
                dependencyServiceIDs: service.dependencyServiceIDs,
                previousHealthState: model.runtimeStatuses[service.id]?.healthState ?? .unknown,
                configurationDigest: ManagedServiceConfigurationDigest.make(for: service)
            )
        }
        let updated = WorkspaceSession(
            id: session.id, name: session.name, projectIDs: session.projectIDs,
            serviceSnapshots: refreshed, capturedAt: session.capturedAt, notes: session.notes
        )
        let changed = zip(session.serviceSnapshots, refreshed).filter { $0 != $1 }.map { $0.0.managedServiceID }
        guard arguments["apply"]?.boolValue == true else {
            return .object([
                "preview": try JSONValue.encode(updated),
                "changed_service_ids": .array(changed.map { .string($0.uuidString) }),
                "requires_confirmation": .bool(!changed.isEmpty)
            ])
        }
        guard arguments["confirmed"]?.boolValue == true || changed.isEmpty else {
            throw ControlFailure(code: .operationNotApproved, message: "Confirm overwriting meaningful session expectations after reviewing the preview.")
        }
        if let supplied = arguments["revision"]?.intValue {
            let current = try store.revision(kind: "session", id: id.uuidString)
            guard supplied == current else {
                throw ControlFailure(code: .entityChanged, message: "The session changed from revision \(supplied) to \(current).")
            }
        }
        return try mutated { try store.saveSession(updated) }
    }

    func sessionDuplicate(_ arguments: JSONValue) throws -> JSONValue {
        let original = try store.session(id: requiredUUID("session_id", arguments))
        return try store.saveSession(WorkspaceSession(
            name: arguments["name"]?.stringValue ?? "\(original.name) Copy",
            projectIDs: original.projectIDs,
            serviceSnapshots: original.serviceSnapshots,
            notes: original.notes
        ))
    }

    func sessionDiff(_ arguments: JSONValue) async throws -> JSONValue {
        let session = try store.session(id: requiredUUID("session_id", arguments))
        let services = try store.services(includeArchived: true)
        let roots = Set(try session.projectIDs.compactMap { try store.project(id: $0).folderPath })
        let diff = await model.compareWorkspaceSession(session, services: services, projectRootPaths: roots)
        return .object([
            "session_id": .string(session.id.uuidString),
            "change_count": .number(Double(diff.changeCount)),
            "added_service_ids": .array(diff.addedServiceIDs.map { .string($0.uuidString) }),
            "missing_service_ids": .array(diff.missingServiceIDs.map { .string($0.uuidString) }),
            "configuration_drift_service_ids": .array(diff.configurationDriftServiceIDs.map { .string($0.uuidString) }),
            "port_changes": .array(diff.portChanges.map { change in .object([
                "service_id": .string(change.serviceID.uuidString),
                "service_name": .string(change.serviceName),
                "saved_ports": .array(change.savedPorts.sorted().map { .number(Double($0)) }),
                "current_ports": .array(change.currentPorts.sorted().map { .number(Double($0)) })
            ]) }),
            "health_changes": .array(diff.healthChanges.map { change in .object([
                "service_id": .string(change.serviceID.uuidString),
                "saved": .string(change.saved.rawValue), "current": .string(change.current.rawValue)
            ]) }),
            "unexpected_listener_ids": .array(diff.unexpectedListeners.map { .string($0.id) })
        ])
    }

    func sessionExport(_ arguments: JSONValue) throws -> JSONValue {
        let session = try store.session(id: requiredUUID("session_id", arguments))
        let data = try JSONEncoder.devBerth.encode(session)
        let url = try exportURL(prefix: "session-\(safeFilename(session.name))", extension: "json")
        try data.write(to: url, options: .atomic)
        return .object(["path": .string(url.path), "format": .string("devberth-session-v1"), "secret_values_exported": .bool(false)])
    }

    func sessionImport(_ arguments: JSONValue) throws -> JSONValue {
        let session: WorkspaceSession
        if let value = arguments["session"] { session = try value.decode(WorkspaceSession.self) }
        else if let path = arguments["path"]?.stringValue {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard url.pathExtension.lowercased() == "json" else {
                throw ControlFailure(code: .invalidArguments, message: "Only a DevBerth JSON session manifest can be imported.")
            }
            var fileInfo = stat()
            guard lstat(url.path, &fileInfo) == 0, (fileInfo.st_mode & S_IFMT) == S_IFREG else {
                throw ControlFailure(code: .permissionDenied, message: "Session manifests must be regular non-symlink files.")
            }
            guard fileInfo.st_size <= 1_048_576 else {
                throw ControlFailure(code: .resultTooLarge, message: "Session manifests are limited to 1 MiB.")
            }
            session = try JSONDecoder.devBerth.decode(WorkspaceSession.self, from: Data(contentsOf: url, options: .mappedIfSafe))
        } else { throw ControlFailure(code: .invalidArguments, message: "Supply a session object or manifest path.") }
        let knownServices = Set(try store.services(includeArchived: true).map(\.id))
        let missing = session.serviceSnapshots.map(\.managedServiceID).filter { !knownServices.contains($0) }
        guard missing.isEmpty else {
            throw ControlFailure(
                code: .missingDependency,
                message: "The imported session references missing managed services.",
                details: .array(missing.map { .string($0.uuidString) })
            )
        }
        guard arguments["apply"]?.boolValue == true else {
            return .object(["preview": try JSONValue.encode(session), "requires_apply": .bool(true)])
        }
        return try store.saveSession(session)
    }

    func sessionRestorePreview(_ arguments: JSONValue) async throws -> JSONValue {
        let session = try store.session(id: requiredUUID("session_id", arguments))
        let plan = try await model.previewWorkspaceSession(session, services: store.services(includeArchived: true))
        let preview = try await operationPreview(.object([
            "operation_type": .string("restore_session"),
            "targets": .array([.string(session.id.uuidString)]),
            "options": .object([:])
        ]))
        return .object(["plan": try JSONValue.encode(plan), "operation": preview])
    }

    func portsList() throws -> JSONValue {
        let services = try store.services(includeArchived: true)
        let expected = services.flatMap { service in service.expectedPorts.map { port in
            JSONValue.object([
                "id": .string(port.id.uuidString), "port": .number(Double(port.port)),
                "protocol": .string(port.protocolKind.rawValue), "required": .bool(port.required),
                "service_id": .string(service.id.uuidString),
                "project_id": service.projectID.map { .string($0.uuidString) } ?? .null
            ])
        }}
        return .object([
            "active": .array(try model.listeners.map(runtimeListenerValue)),
            "expected": .array(expected),
            "watched": .array(try store.items(kind: "port_watch")),
            "reserved": .array(try store.items(kind: "port_reservation")),
            "aliases": .array(try store.items(kind: "port_alias")),
            "ignored": .array(try store.items(kind: "port_ignore_rule"))
        ])
    }

    func portInspect(_ arguments: JSONValue) async throws -> JSONValue {
        let listener = try requiredListener(arguments)
        let graph = await model.resolveOwnership(of: listener)
        let services = try store.services(includeArchived: true)
        let expected = services.flatMap { service in service.expectedPorts.filter { $0.port == listener.port && $0.protocolKind == listener.protocolKind }.map { (service, $0) } }
        return .object([
            "listener": try runtimeListenerValue(listener),
            "ownership": try JSONValue.encode(graph),
            "expected_owners": .array(expected.map { .object([
                "service_id": .string($0.0.id.uuidString),
                "expected_port_id": .string($0.1.id.uuidString)
            ]) }),
            "conflict": .bool(!expected.isEmpty && !expected.contains { $0.0.id == listener.process.managedServiceID }),
            "available_actions": .array([.string("watch"), .string("ignore"), .string("release_preview")])
        ])
    }
}
