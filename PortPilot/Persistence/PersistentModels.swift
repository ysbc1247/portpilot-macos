import Foundation
import SwiftData

@Model
final class ProjectRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    var folderPath: String?
    var gitRemoteURL: String?
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), name: String, folderPath: String? = nil, gitRemoteURL: String? = nil) {
        self.id = id
        self.name = name
        self.folderPath = folderPath
        self.gitRemoteURL = gitRemoteURL
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

@Model
final class LaunchProfileRecord {
    @Attribute(.unique) var id: UUID
    var projectID: UUID?
    var name: String
    var kindRawValue: String
    var command: String
    var argumentsData: Data
    var workingDirectory: String
    var shellData: Data
    var environmentData: Data
    var secretReferencesData: Data
    var startupTimeoutSeconds: Double
    var shutdownTimeoutSeconds: Double
    var restartPolicyRawValue: String
    var healthCheckData: Data?
    var logFile: String?
    var tagsData: Data
    var icon: String?
    var launchesAutomatically: Bool
    var isFavorite: Bool
    var isReviewed: Bool
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), name: String, command: String, workingDirectory: String) {
        self.id = id
        self.name = name
        self.command = command
        self.workingDirectory = workingDirectory
        self.projectID = nil
        self.kindRawValue = LaunchProfileKind.genericCommand.rawValue
        self.argumentsData = Data("[]".utf8)
        self.shellData = Data("{\"direct\":{}}".utf8)
        self.environmentData = Data("{}".utf8)
        self.secretReferencesData = Data("{}".utf8)
        self.startupTimeoutSeconds = 30
        self.shutdownTimeoutSeconds = 5
        self.restartPolicyRawValue = RestartPolicy.never.rawValue
        self.healthCheckData = nil
        self.logFile = nil
        self.tagsData = Data("[]".utf8)
        self.icon = nil
        self.launchesAutomatically = false
        self.isFavorite = false
        self.isReviewed = true
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

@Model
final class ProfileDependencyRecord {
    @Attribute(.unique) var id: UUID
    var profileID: UUID
    var dependencyProfileID: UUID

    init(id: UUID = UUID(), profileID: UUID, dependencyProfileID: UUID) {
        self.id = id
        self.profileID = profileID
        self.dependencyProfileID = dependencyProfileID
    }
}

@Model
final class ExpectedPortRecord {
    @Attribute(.unique) var id: UUID
    var profileID: UUID
    var port: Int
    var protocolRawValue: String
    var required: Bool

    init(id: UUID = UUID(), profileID: UUID, port: UInt16, protocolKind: ListenerProtocol, required: Bool = true) {
        self.id = id
        self.profileID = profileID
        self.port = Int(port)
        self.protocolRawValue = protocolKind.rawValue
        self.required = required
    }
}

@Model
final class ProcessHistoryEventRecord {
    @Attribute(.unique) var id: UUID
    var timestamp: Date
    var port: Int?
    var processPID: Int?
    var executablePath: String?
    var processStartTime: Date?
    var processName: String?
    var projectID: UUID?
    var profileID: UUID?
    var typeRawValue: String
    var resultRawValue: String
    var errorDetails: String?
    var durationSeconds: Double?

    init(event: HistoryEvent) {
        id = event.id
        timestamp = event.timestamp
        port = event.port.map(Int.init)
        processPID = event.processIdentity.map { Int($0.pid) }
        executablePath = event.processIdentity?.executablePath
        processStartTime = event.processIdentity?.startTime
        processName = event.processName
        projectID = event.projectID
        profileID = event.profileID
        typeRawValue = event.type.rawValue
        resultRawValue = event.result.rawValue
        errorDetails = event.errorDetails
        durationSeconds = event.durationSeconds
    }
}

@Model
final class PortObservationRecord {
    @Attribute(.unique) var id: UUID
    var port: Int
    var protocolRawValue: String
    var address: String
    var processPID: Int
    var firstDetectedAt: Date
    var lastDetectedAt: Date
    var releasedAt: Date?

    init(listener: NetworkListener) {
        id = UUID()
        port = Int(listener.port)
        protocolRawValue = listener.protocolKind.rawValue
        address = listener.address
        processPID = Int(listener.process.identity.pid)
        firstDetectedAt = listener.firstDetectedAt
        lastDetectedAt = listener.lastDetectedAt
    }
}

@Model
final class UserPreferenceRecord {
    @Attribute(.unique) var key: String
    var encodedValue: Data
    var updatedAt: Date

    init(key: String, encodedValue: Data) {
        self.key = key
        self.encodedValue = encodedValue
        self.updatedAt = Date()
    }
}

@Model
final class FavoriteItemRecord {
    @Attribute(.unique) var id: UUID
    var kind: String
    var referencedID: String
    var sortOrder: Int

    init(id: UUID = UUID(), kind: String, referencedID: String, sortOrder: Int) {
        self.id = id
        self.kind = kind
        self.referencedID = referencedID
        self.sortOrder = sortOrder
    }
}

@Model
final class StoredLogMetadataRecord {
    @Attribute(.unique) var id: UUID
    var profileID: UUID
    var filePath: String
    var byteCount: Int
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), profileID: UUID, filePath: String, byteCount: Int = 0) {
        self.id = id
        self.profileID = profileID
        self.filePath = filePath
        self.byteCount = byteCount
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

enum PortPilotSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            ProjectRecord.self,
            LaunchProfileRecord.self,
            ProfileDependencyRecord.self,
            ExpectedPortRecord.self,
            ProcessHistoryEventRecord.self,
            PortObservationRecord.self,
            UserPreferenceRecord.self,
            FavoriteItemRecord.self,
            StoredLogMetadataRecord.self
        ]
    }
}

enum PortPilotMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [PortPilotSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}
