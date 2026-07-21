import Foundation
import SwiftData

@Model
final class EntityRevisionRecord {
    @Attribute(.unique) var key: String
    var entityID: String
    var entityKind: String
    var revision: Int
    var isArchived: Bool
    var metadataData: Data
    var createdAt: Date
    var updatedAt: Date

    init(
        entityID: String,
        entityKind: String,
        revision: Int = 1,
        isArchived: Bool = false,
        metadataData: Data = Data("{}".utf8),
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        key = "\(entityKind):\(entityID)"
        self.entityID = entityID
        self.entityKind = entityKind
        self.revision = revision
        self.isArchived = isArchived
        self.metadataData = metadataData
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model
final class ControlPlaneItemRecord {
    @Attribute(.unique) var id: UUID
    var kind: String
    var name: String
    var revision: Int
    var payloadData: Data
    var isArchived: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        kind: String,
        name: String,
        revision: Int = 1,
        payloadData: Data,
        isArchived: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.revision = revision
        self.payloadData = payloadData
        self.isArchived = isArchived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model
final class MCPAuditEventRecord {
    @Attribute(.unique) var id: UUID
    var timestamp: Date
    var requestID: String
    var correlationID: String
    var toolName: String
    var operationID: String?
    var clientID: String
    var result: String

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        requestID: String,
        correlationID: String,
        toolName: String,
        operationID: String?,
        clientID: String,
        result: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.requestID = requestID
        self.correlationID = correlationID
        self.toolName = toolName
        self.operationID = operationID
        self.clientID = clientID
        self.result = result
    }
}

enum DevBerthSchemaV7: VersionedSchema {
    static var versionIdentifier = Schema.Version(7, 0, 0)
    static var models: [any PersistentModel.Type] {
        DevBerthSchemaV6.models + [
            EntityRevisionRecord.self,
            ControlPlaneItemRecord.self,
            MCPAuditEventRecord.self
        ]
    }
}

