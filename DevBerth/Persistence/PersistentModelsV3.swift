import Foundation
import SwiftData

@Model
final class ProcessFingerprintRecord {
    @Attribute(.unique) var id: UUID
    var runtimeID: UUID?
    var managedServiceID: UUID?
    var observedListenerID: String?
    var roleRawValue: String
    var processPID: Int
    var uid: Int?
    var executablePath: String?
    var executableDeviceID: String?
    var executableInode: String?
    var processStartTime: Date?
    var commandLineDigest: String?
    var parentPID: Int?
    var detectedAt: Date

    init(
        id: UUID = UUID(),
        fingerprint: ProcessFingerprint,
        runtimeID: UUID? = nil,
        managedServiceID: UUID? = nil,
        observedListenerID: String? = nil,
        role: ProcessGroupMemberRole = .groupMember
    ) {
        self.id = id
        self.runtimeID = runtimeID
        self.managedServiceID = managedServiceID
        self.observedListenerID = observedListenerID
        roleRawValue = role.rawValue
        processPID = Int(fingerprint.pid)
        uid = fingerprint.uid.map(Int.init)
        executablePath = fingerprint.executablePath
        executableDeviceID = fingerprint.executableFileIdentity.map { String($0.deviceID) }
        executableInode = fingerprint.executableFileIdentity.map { String($0.inode) }
        processStartTime = fingerprint.startTime
        commandLineDigest = fingerprint.commandLineDigest
        parentPID = fingerprint.parentPID.map(Int.init)
        detectedAt = fingerprint.detectedAt
    }
}

@Model
final class ManagedServiceProcessPolicyRecord {
    @Attribute(.unique) var managedServiceID: UUID
    var createsDedicatedProcessGroup: Bool
    var terminationScopeRawValue: String
    var updatedAt: Date

    init(
        managedServiceID: UUID,
        policy: ManagedServiceProcessPolicy,
        updatedAt: Date = Date()
    ) {
        self.managedServiceID = managedServiceID
        createsDedicatedProcessGroup = policy.createsDedicatedProcessGroup
        terminationScopeRawValue = policy.terminationScope.rawValue
        self.updatedAt = updatedAt
    }
}

@Model
final class ProcessGroupSnapshotRecord {
    @Attribute(.unique) var id: UUID
    var runtimeID: UUID
    var managedServiceID: UUID
    var processGroupID: Int
    var leaderFingerprintData: Data
    var membersData: Data
    var capturedAt: Date

    init(snapshot: ProcessGroupSnapshot) throws {
        let encoder = JSONEncoder()
        id = snapshot.id
        runtimeID = snapshot.runtimeID
        managedServiceID = snapshot.managedServiceID
        processGroupID = Int(snapshot.processGroupID)
        leaderFingerprintData = try encoder.encode(snapshot.leaderFingerprint)
        membersData = try encoder.encode(snapshot.members)
        capturedAt = snapshot.capturedAt
    }
}

enum DevBerthSchemaV3: VersionedSchema {
    static var versionIdentifier = Schema.Version(3, 0, 0)
    static var models: [any PersistentModel.Type] {
        DevBerthSchemaV2.models + [
            ProcessFingerprintRecord.self,
            ManagedServiceProcessPolicyRecord.self,
            ProcessGroupSnapshotRecord.self
        ]
    }
}
