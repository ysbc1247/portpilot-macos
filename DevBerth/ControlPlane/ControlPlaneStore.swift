import DevBerthControlContracts
import Foundation
import SwiftData

@MainActor
final class ControlPlaneStore {
    let context: ModelContext

    init(container: ModelContainer) {
        context = container.mainContext
    }

    func projects(includeArchived: Bool = false) throws -> [JSONValue] {
        try context.fetch(FetchDescriptor<ProjectRecord>(sortBy: [SortDescriptor(\.name)]))
            .compactMap { record in
                let revision = try revisionRecord(kind: "project", id: record.id.uuidString, create: false)
                guard includeArchived || revision?.isArchived != true else { return nil }
                return try projectValue(record, revision: revision)
            }
    }

    func project(id: UUID) throws -> ProjectRecord {
        let records = try context.fetch(FetchDescriptor<ProjectRecord>())
        guard let value = records.first(where: { $0.id == id }) else {
            throw ControlFailure(code: .entityNotFound, message: "No project exists with ID \(id.uuidString).")
        }
        return value
    }

    func projectValue(_ record: ProjectRecord) throws -> JSONValue {
        try projectValue(record, revision: revisionRecord(kind: "project", id: record.id.uuidString, create: false))
    }

    func createProject(arguments: JSONValue) throws -> JSONValue {
        let values = mergedValues(arguments)
        let name = try requiredString("name", in: values)
        let record = ProjectRecord(
            id: uuid("id", in: values) ?? UUID(),
            name: name,
            folderPath: values["folder_path"]?.stringValue,
            gitRemoteURL: values["git_remote_url"]?.stringValue
        )
        context.insert(record)
        let metadata = metadataValue(from: values, excluding: ["id", "name", "folder_path", "git_remote_url"])
        _ = try bumpRevision(kind: "project", id: record.id.uuidString, metadata: metadata, archived: false)
        try context.save()
        return try projectValue(record)
    }

    func updateProject(id: UUID, arguments: JSONValue) throws -> JSONValue {
        let record = try project(id: id)
        try requireRevision(kind: "project", id: id.uuidString, supplied: arguments["revision"]?.intValue)
        let patch = arguments["patch"]?.objectValue ?? arguments.objectValue ?? [:]
        if let name = patch["name"]?.stringValue { record.name = name }
        if patch.keys.contains("folder_path") { record.folderPath = nullableString(patch["folder_path"]) }
        if patch.keys.contains("git_remote_url") { record.gitRemoteURL = nullableString(patch["git_remote_url"]) }
        record.updatedAt = Date()
        let metadata = metadataValue(from: patch, excluding: ["name", "folder_path", "git_remote_url"])
        _ = try bumpRevision(kind: "project", id: id.uuidString, metadata: metadata, archived: nil)
        try context.save()
        return try projectValue(record)
    }

    func duplicateProject(id: UUID, arguments: JSONValue) throws -> JSONValue {
        let original = try project(id: id)
        let values = mergedValues(arguments)
        let duplicate = ProjectRecord(
            name: values["name"]?.stringValue ?? "\(original.name) Copy",
            folderPath: original.folderPath,
            gitRemoteURL: original.gitRemoteURL
        )
        context.insert(duplicate)
        let originalRevision = try revisionRecord(kind: "project", id: id.uuidString, create: false)
        _ = try bumpRevision(
            kind: "project",
            id: duplicate.id.uuidString,
            metadata: originalRevision.flatMap { try? JSONDecoder.devBerth.decode(JSONValue.self, from: $0.metadataData) },
            archived: false
        )
        if values["services"]?.boolValue == true {
            let services = try ManagedServicePersistence.configurations(in: context).filter { $0.projectID == id }
            var mapped: [UUID: UUID] = [:]
            services.forEach { mapped[$0.id] = UUID() }
            for service in services {
                var copy = service
                copy = ManagedServiceConfiguration(
                    id: mapped[service.id]!,
                    name: service.name,
                    projectID: duplicate.id,
                    launchMechanism: service.launchMechanism,
                    command: service.command,
                    arguments: service.arguments,
                    workingDirectory: service.workingDirectory,
                    shell: service.shell,
                    environment: service.environment,
                    secretReferences: values["copy_secret_references"]?.boolValue == true ? service.secretReferences : [:],
                    expectedPorts: service.expectedPorts.map { .init(id: UUID(), port: $0.port, protocolKind: $0.protocolKind, required: $0.required) },
                    startupTimeoutSeconds: service.startupTimeoutSeconds,
                    shutdownTimeoutSeconds: service.shutdownTimeoutSeconds,
                    restartPolicy: service.restartPolicy,
                    processPolicy: service.processPolicy,
                    healthCheck: service.healthCheck,
                    serviceChecks: service.serviceChecks,
                    dependencyServiceIDs: service.dependencyServiceIDs.compactMap { mapped[$0] },
                    logFile: service.logFile,
                    tags: service.tags,
                    icon: service.icon,
                    launchesAutomatically: false,
                    isFavorite: false,
                    isReviewed: service.isReviewed
                )
                try ManagedServicePersistence.save(copy, in: context)
                _ = try bumpRevision(kind: "service", id: copy.id.uuidString, metadata: nil, archived: false)
            }
        }
        try context.save()
        return try projectValue(duplicate)
    }

    func archive(kind: String, id: UUID, archived: Bool, suppliedRevision: Int?) throws -> JSONValue {
        try requireRevision(kind: kind, id: id.uuidString, supplied: suppliedRevision)
        let record = try bumpRevision(kind: kind, id: id.uuidString, metadata: nil, archived: archived)
        try context.save()
        return revisionValue(record)
    }

    func deleteProject(id: UUID, allowReferences: Bool) throws {
        let record = try project(id: id)
        let services = try ManagedServicePersistence.configurations(in: context).filter { $0.projectID == id }
        let sessions = try self.sessions(includeArchived: true).filter {
            $0.projectIDs.contains(id) || !$0.serviceSnapshots.filter { snapshot in services.contains { $0.id == snapshot.managedServiceID } }.isEmpty
        }
        guard allowReferences || (services.isEmpty && sessions.isEmpty) else {
            throw ControlFailure(
                code: .operationNotApproved,
                message: "This project has managed services or sessions and requires operation_preview.",
                recoverySuggestion: "Preview delete_project_with_dependencies and execute the returned operation ID."
            )
        }
        if allowReferences {
            let removedServiceIDs = Set(services.map(\.id))
            for session in sessions {
                _ = try saveSession(WorkspaceSession(
                    id: session.id,
                    name: session.name,
                    projectIDs: session.projectIDs.filter { $0 != id },
                    serviceSnapshots: session.serviceSnapshots.filter { !removedServiceIDs.contains($0.managedServiceID) },
                    capturedAt: session.capturedAt,
                    notes: session.notes
                ))
            }
            for service in services {
                try ManagedServicePersistence.delete(id: service.id, in: context)
                try deleteRevision(kind: "service", id: service.id.uuidString)
            }
        }
        context.delete(record)
        try deleteRevision(kind: "project", id: id.uuidString)
        try context.save()
    }

    func services(includeArchived: Bool = false) throws -> [ManagedServiceConfiguration] {
        try ManagedServicePersistence.configurations(in: context).filter { service in
            includeArchived || (try? revisionRecord(kind: "service", id: service.id.uuidString, create: false)?.isArchived) != true
        }
    }

    func serviceValue(_ configuration: ManagedServiceConfiguration) throws -> JSONValue {
        var object = try JSONValue.encode(configuration).objectValue ?? [:]
        let revision = try revisionRecord(kind: "service", id: configuration.id.uuidString, create: false)
        let revisionMetadata = revision.flatMap { try? JSONDecoder.devBerth.decode(JSONValue.self, from: $0.metadataData) }
        object["revision"] = .number(Double(revision?.revision ?? 1))
        object["archived"] = .bool(revision?.isArchived ?? false)
        object["enabled"] = revisionMetadata?["enabled"] ?? .bool(true)
        object.removeValue(forKey: "secretReferences")
        object["secret_references"] = .object(configuration.secretReferences.mapValues { _ in .object(["configured": .bool(true)]) })
        object["environment"] = .object(configuration.environment.mapValues(JSONValue.string))
        return .object(object)
    }

    func service(id: UUID) throws -> ManagedServiceConfiguration {
        guard let value = try ManagedServicePersistence.configuration(id: id, in: context) else {
            throw ControlFailure(code: .entityNotFound, message: "No managed service exists with ID \(id.uuidString).")
        }
        return value
    }

    func createService(arguments: JSONValue) throws -> JSONValue {
        let values = mergedValues(arguments)
        let newConfiguration: ManagedServiceConfiguration
        if let encoded = values["configuration"] {
            newConfiguration = try encoded.decode(ManagedServiceConfiguration.self)
        } else {
            newConfiguration = try configuration(from: values, id: uuid("id", in: values) ?? UUID())
        }
        try validateEnvironment(newConfiguration.environment)
        try ManagedServicePersistence.save(newConfiguration, in: context)
        _ = try bumpRevision(kind: "service", id: newConfiguration.id.uuidString, metadata: nil, archived: false)
        try context.save()
        return try serviceValue(newConfiguration)
    }

    func updateService(id: UUID, arguments: JSONValue) throws -> JSONValue {
        try requireRevision(kind: "service", id: id.uuidString, supplied: arguments["revision"]?.intValue)
        let existing = try service(id: id)
        let patch = arguments["patch"]?.objectValue ?? arguments.objectValue ?? [:]
        var encoded = try JSONValue.encode(existing).objectValue ?? [:]
        for (key, value) in patch where key != "revision" && key != "service_id" { encoded[key] = value }
        encoded["id"] = .string(id.uuidString)
        let updated = try JSONValue.object(encoded).decode(ManagedServiceConfiguration.self)
        try validateEnvironment(updated.environment)
        try ManagedServicePersistence.save(updated, in: context)
        _ = try bumpRevision(kind: "service", id: id.uuidString, metadata: nil, archived: nil)
        try context.save()
        return try serviceValue(updated)
    }

    func duplicateService(id: UUID, arguments: JSONValue) throws -> JSONValue {
        let original = try service(id: id)
        let values = mergedValues(arguments)
        let duplicate = ManagedServiceConfiguration(
            id: UUID(),
            name: values["name"]?.stringValue ?? "\(original.name) Copy",
            projectID: uuid("project_id", in: values) ?? original.projectID,
            launchMechanism: original.launchMechanism,
            command: original.command,
            arguments: original.arguments,
            workingDirectory: original.workingDirectory,
            shell: original.shell,
            environment: original.environment,
            secretReferences: values["copy_secret_references"]?.boolValue == true ? original.secretReferences : [:],
            expectedPorts: original.expectedPorts.map { .init(id: UUID(), port: $0.port, protocolKind: $0.protocolKind, required: $0.required) },
            startupTimeoutSeconds: original.startupTimeoutSeconds,
            shutdownTimeoutSeconds: original.shutdownTimeoutSeconds,
            restartPolicy: original.restartPolicy,
            processPolicy: original.processPolicy,
            healthCheck: original.healthCheck,
            serviceChecks: original.serviceChecks,
            dependencyServiceIDs: original.dependencyServiceIDs,
            logFile: original.logFile,
            tags: original.tags,
            icon: original.icon,
            launchesAutomatically: false,
            isFavorite: false,
            isReviewed: original.isReviewed
        )
        try ManagedServicePersistence.save(duplicate, in: context)
        _ = try bumpRevision(kind: "service", id: duplicate.id.uuidString, metadata: nil, archived: false)
        try context.save()
        return try serviceValue(duplicate)
    }

    func deleteService(id: UUID, allowReferences: Bool) throws {
        _ = try service(id: id)
        let referencedSessions = try sessions(includeArchived: true).filter {
            $0.serviceSnapshots.contains { $0.managedServiceID == id }
        }
        let referenced = !referencedSessions.isEmpty
        guard allowReferences || !referenced else {
            throw ControlFailure(code: .operationNotApproved, message: "The managed service is referenced by a session and requires operation_preview.")
        }
        if allowReferences {
            for session in referencedSessions {
                _ = try saveSession(WorkspaceSession(
                    id: session.id,
                    name: session.name,
                    projectIDs: session.projectIDs,
                    serviceSnapshots: session.serviceSnapshots.filter { $0.managedServiceID != id },
                    capturedAt: session.capturedAt,
                    notes: session.notes
                ))
            }
        }
        try ManagedServicePersistence.delete(id: id, in: context)
        try deleteRevision(kind: "service", id: id.uuidString)
        try context.save()
    }

    func setServiceEnabled(id: UUID, enabled: Bool, suppliedRevision: Int?) throws -> JSONValue {
        let service = try service(id: id)
        try requireRevision(kind: "service", id: id.uuidString, supplied: suppliedRevision)
        _ = try bumpRevision(
            kind: "service",
            id: id.uuidString,
            metadata: .object(["enabled": .bool(enabled)]),
            archived: nil
        )
        try context.save()
        return try serviceValue(service)
    }

    func serviceIsEnabled(id: UUID) throws -> Bool {
        let revision = try revisionRecord(kind: "service", id: id.uuidString, create: false)
        let metadata = revision.flatMap { try? JSONDecoder.devBerth.decode(JSONValue.self, from: $0.metadataData) }
        return metadata?["enabled"]?.boolValue ?? true
    }

    func sessions(includeArchived: Bool = false) throws -> [WorkspaceSession] {
        let snapshots = try context.fetch(FetchDescriptor<WorkspaceSessionServiceRecord>())
        return try context.fetch(FetchDescriptor<WorkspaceSessionRecord>(sortBy: [SortDescriptor(\.capturedAt, order: .reverse)]))
            .compactMap { record in
                guard includeArchived || (try? revisionRecord(kind: "session", id: record.id.uuidString, create: false)?.isArchived) != true else { return nil }
                return record.session(serviceRecords: snapshots)
            }
    }

    func session(id: UUID) throws -> WorkspaceSession {
        guard let session = try sessions(includeArchived: true).first(where: { $0.id == id }) else {
            throw ControlFailure(code: .entityNotFound, message: "No workspace session exists with ID \(id.uuidString).")
        }
        return session
    }

    func sessionValue(_ session: WorkspaceSession) throws -> JSONValue {
        var value = try JSONValue.encode(session).objectValue ?? [:]
        let revision = try revisionRecord(kind: "session", id: session.id.uuidString, create: false)
        value["revision"] = .number(Double(revision?.revision ?? 1))
        value["archived"] = .bool(revision?.isArchived ?? false)
        let restores = try context.fetch(FetchDescriptor<SessionRestoreRecord>())
            .filter { $0.sessionID == session.id }.compactMap(\.result)
        value["restore_history"] = try JSONValue.encode(restores)
        return .object(value)
    }

    func sessionValues() throws -> [JSONValue] { try sessions().map(sessionValue) }

    func saveSession(_ session: WorkspaceSession) throws -> JSONValue {
        let existingRecords = try context.fetch(FetchDescriptor<WorkspaceSessionRecord>())
        if let existing = existingRecords.first(where: { $0.id == session.id }) {
            existing.name = session.name
            existing.projectIDsData = try JSONEncoder().encode(session.projectIDs)
            existing.notes = session.notes
            existing.updatedAt = Date()
            try context.fetch(FetchDescriptor<WorkspaceSessionServiceRecord>())
                .filter { $0.sessionID == session.id }.forEach(context.delete)
            session.serviceSnapshots.forEach { snapshot in
                if let record = try? WorkspaceSessionServiceRecord(sessionID: session.id, snapshot: snapshot) {
                    context.insert(record)
                }
            }
        } else {
            context.insert(try WorkspaceSessionRecord(session: session))
            for snapshot in session.serviceSnapshots {
                context.insert(try WorkspaceSessionServiceRecord(sessionID: session.id, snapshot: snapshot))
            }
        }
        _ = try bumpRevision(kind: "session", id: session.id.uuidString, metadata: nil, archived: false)
        try context.save()
        return try sessionValue(session)
    }

    func deleteSession(id: UUID, allowHistory: Bool) throws {
        let records = try context.fetch(FetchDescriptor<WorkspaceSessionRecord>())
        guard let record = records.first(where: { $0.id == id }) else {
            throw ControlFailure(code: .entityNotFound, message: "No workspace session exists with ID \(id.uuidString).")
        }
        let history = try context.fetch(FetchDescriptor<SessionRestoreRecord>()).filter { $0.sessionID == id }
        guard allowHistory || history.isEmpty else {
            throw ControlFailure(code: .operationNotApproved, message: "The session has restore history and requires operation_preview.")
        }
        try context.fetch(FetchDescriptor<WorkspaceSessionServiceRecord>())
            .filter { $0.sessionID == id }.forEach(context.delete)
        if allowHistory { history.forEach(context.delete) }
        context.delete(record)
        try deleteRevision(kind: "session", id: id.uuidString)
        try context.save()
    }

    func items(kind: String, includeArchived: Bool = false) throws -> [JSONValue] {
        try context.fetch(FetchDescriptor<ControlPlaneItemRecord>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))
            .filter { $0.kind == kind && (includeArchived || !$0.isArchived) }
            .map(itemValue)
    }

    func createItem(kind: String, arguments: JSONValue) throws -> JSONValue {
        let values = mergedValues(arguments)
        let id = uuid("id", in: values) ?? UUID()
        let name = values["name"]?.stringValue ?? "\(kind)-\(id.uuidString.prefix(8))"
        let record = ControlPlaneItemRecord(
            id: id,
            kind: kind,
            name: name,
            payloadData: try JSONEncoder.devBerth.encode(JSONValue.object(values))
        )
        context.insert(record)
        try context.save()
        return try itemValue(record)
    }

    func updateItem(kind: String, id: UUID, arguments: JSONValue) throws -> JSONValue {
        let records = try context.fetch(FetchDescriptor<ControlPlaneItemRecord>())
        guard let record = records.first(where: { $0.kind == kind && $0.id == id }) else {
            throw ControlFailure(code: .entityNotFound, message: "No \(kind) exists with ID \(id.uuidString).")
        }
        if let supplied = arguments["revision"]?.intValue, supplied != record.revision {
            throw ControlFailure(code: .entityChanged, message: "The \(kind) changed from revision \(supplied) to \(record.revision).")
        }
        var payload = (try? JSONDecoder.devBerth.decode(JSONValue.self, from: record.payloadData).objectValue) ?? [:]
        let patch = arguments["patch"]?.objectValue ?? arguments.objectValue ?? [:]
        patch.forEach { payload[$0.key] = $0.value }
        if let name = patch["name"]?.stringValue { record.name = name }
        record.payloadData = try JSONEncoder.devBerth.encode(JSONValue.object(payload))
        record.revision += 1
        record.updatedAt = Date()
        try context.save()
        return try itemValue(record)
    }

    func deleteItem(kind: String, id: UUID, suppliedRevision: Int?) throws {
        let records = try context.fetch(FetchDescriptor<ControlPlaneItemRecord>())
        guard let record = records.first(where: { $0.kind == kind && $0.id == id }) else {
            throw ControlFailure(code: .entityNotFound, message: "No \(kind) exists with ID \(id.uuidString).")
        }
        if let suppliedRevision, suppliedRevision != record.revision {
            throw ControlFailure(code: .entityChanged, message: "The \(kind) changed from revision \(suppliedRevision) to \(record.revision).")
        }
        context.delete(record)
        try context.save()
    }

    func recordAudit(request: ControlRequest, result: String, operationID: String? = nil) {
        context.insert(MCPAuditEventRecord(
            requestID: request.requestID,
            correlationID: request.correlationID,
            toolName: request.toolName,
            operationID: operationID,
            clientID: request.handshake.client.instanceID.uuidString,
            result: result
        ))
        try? context.save()
    }

    func revision(kind: String, id: String) throws -> Int {
        try revisionRecord(kind: kind, id: id, create: false)?.revision ?? 1
    }

    private func projectValue(_ record: ProjectRecord, revision: EntityRevisionRecord?) throws -> JSONValue {
        let metadata = revision.flatMap { try? JSONDecoder.devBerth.decode(JSONValue.self, from: $0.metadataData) } ?? .object([:])
        return .object([
            "id": .string(record.id.uuidString),
            "name": .string(record.name),
            "folder_path": record.folderPath.map(JSONValue.string) ?? .null,
            "git_remote_url": record.gitRemoteURL.map(JSONValue.string) ?? .null,
            "revision": .number(Double(revision?.revision ?? 1)),
            "archived": .bool(revision?.isArchived ?? false),
            "created_at": .string(record.createdAt.ISO8601Format()),
            "updated_at": .string(record.updatedAt.ISO8601Format()),
            "metadata": metadata
        ])
    }

    private func itemValue(_ record: ControlPlaneItemRecord) throws -> JSONValue {
        .object([
            "id": .string(record.id.uuidString),
            "kind": .string(record.kind),
            "name": .string(record.name),
            "revision": .number(Double(record.revision)),
            "archived": .bool(record.isArchived),
            "created_at": .string(record.createdAt.ISO8601Format()),
            "updated_at": .string(record.updatedAt.ISO8601Format()),
            "payload": try JSONDecoder.devBerth.decode(JSONValue.self, from: record.payloadData)
        ])
    }

    private func configuration(from values: [String: JSONValue], id: UUID) throws -> ManagedServiceConfiguration {
        let environment = values["environment"]?.objectValue?.compactMapValues(\.stringValue) ?? [:]
        let secretReferences = values["secret_references"]?.objectValue?.compactMapValues { value in
            value.stringValue.flatMap(UUID.init(uuidString:))
        } ?? [:]
        let expectedPorts: [ExpectedListenerConfiguration] = try values["expected_ports"]?.decode([ExpectedListenerConfiguration].self) ?? []
        let projectID = uuid("project_id", in: values)
        return ManagedServiceConfiguration(
            id: id,
            name: try requiredString("name", in: values),
            projectID: projectID,
            launchMechanism: values["launch_mechanism"]?.stringValue.flatMap(LaunchMechanism.init(rawValue:)) ?? .genericCommand,
            command: try requiredString("command", in: values),
            arguments: values["arguments"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            workingDirectory: try requiredString("working_directory", in: values),
            shell: try values["shell"]?.decode(ShellSelection.self) ?? .direct,
            environment: environment,
            secretReferences: secretReferences,
            expectedPorts: expectedPorts,
            startupTimeoutSeconds: Double(values["startup_timeout_seconds"]?.intValue ?? 30),
            shutdownTimeoutSeconds: Double(values["shutdown_timeout_seconds"]?.intValue ?? 5),
            restartPolicy: values["restart_policy"]?.stringValue.flatMap(RestartPolicy.init(rawValue:)) ?? .never,
            processPolicy: .controlledProcessGroup,
            healthCheck: try values["health_check"]?.decode(HealthCheckConfiguration.self),
            serviceChecks: try values["service_checks"]?.decode([ServiceCheckConfiguration].self) ?? [],
            dependencyServiceIDs: values["dependency_service_ids"]?.arrayValue?.compactMap { $0.stringValue.flatMap(UUID.init(uuidString:)) } ?? [],
            logFile: values["log_file"]?.stringValue,
            tags: values["tags"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            icon: values["icon"]?.stringValue,
            launchesAutomatically: values["launches_automatically"]?.boolValue ?? false,
            isFavorite: values["is_favorite"]?.boolValue ?? false,
            isReviewed: values["is_reviewed"]?.boolValue ?? false
        )
    }

    private func validateEnvironment(_ environment: [String: String]) throws {
        if let secretName = environment.keys.first(where: SensitiveEnvironmentKeyPolicy.isSensitive) {
            throw ControlFailure(
                code: .invalidArguments,
                message: "Environment field \(secretName) appears secret-like and must use an opaque Keychain reference."
            )
        }
    }

    private func revisionRecord(kind: String, id: String, create: Bool) throws -> EntityRevisionRecord? {
        let key = "\(kind):\(id)"
        let records = try context.fetch(FetchDescriptor<EntityRevisionRecord>())
        if let record = records.first(where: { $0.key == key }) { return record }
        guard create else { return nil }
        let record = EntityRevisionRecord(entityID: id, entityKind: kind)
        context.insert(record)
        return record
    }

    private func requireRevision(kind: String, id: String, supplied: Int?) throws {
        guard let supplied else { return }
        let current = try revision(kind: kind, id: id)
        guard supplied == current else {
            throw ControlFailure(code: .entityChanged, message: "The \(kind) changed from revision \(supplied) to \(current).")
        }
    }

    @discardableResult
    private func bumpRevision(
        kind: String,
        id: String,
        metadata: JSONValue?,
        archived: Bool?
    ) throws -> EntityRevisionRecord {
        let existing = try revisionRecord(kind: kind, id: id, create: false)
        let record = try existing ?? revisionRecord(kind: kind, id: id, create: true)!
        if existing != nil { record.revision += 1 }
        if let metadata, case let .object(newValues) = metadata {
            var existing = (try? JSONDecoder.devBerth.decode(JSONValue.self, from: record.metadataData).objectValue) ?? [:]
            newValues.forEach { existing[$0.key] = $0.value }
            record.metadataData = try JSONEncoder.devBerth.encode(JSONValue.object(existing))
        }
        if let archived { record.isArchived = archived }
        record.updatedAt = Date()
        return record
    }

    private func deleteRevision(kind: String, id: String) throws {
        let key = "\(kind):\(id)"
        try context.fetch(FetchDescriptor<EntityRevisionRecord>())
            .filter { $0.key == key }.forEach(context.delete)
    }

    private func revisionValue(_ record: EntityRevisionRecord) -> JSONValue {
        .object([
            "id": .string(record.entityID),
            "kind": .string(record.entityKind),
            "revision": .number(Double(record.revision)),
            "archived": .bool(record.isArchived),
            "updated_at": .string(record.updatedAt.ISO8601Format())
        ])
    }

    private func mergedValues(_ arguments: JSONValue) -> [String: JSONValue] {
        var values = arguments.objectValue ?? [:]
        if let patch = values["patch"]?.objectValue { patch.forEach { values[$0.key] = $0.value } }
        return values
    }

    private func metadataValue(from values: [String: JSONValue], excluding: Set<String>) -> JSONValue {
        .object(values.filter { !excluding.contains($0.key) })
    }

    private func requiredString(_ key: String, in values: [String: JSONValue]) throws -> String {
        guard let value = values[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            throw ControlFailure(code: .invalidArguments, message: "A non-empty \(key) is required.")
        }
        return value
    }

    private func uuid(_ key: String, in values: [String: JSONValue]) -> UUID? {
        values[key]?.stringValue.flatMap(UUID.init(uuidString:))
    }

    private func nullableString(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        if case .null = value { return nil }
        return value.stringValue
    }
}
