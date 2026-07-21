import Foundation

enum ManagedProcessTerminationScope: String, Codable, CaseIterable, Sendable {
    case rootProcessOnly
    case controlledProcessGroup
}

struct ManagedServiceProcessPolicy: Hashable, Codable, Sendable {
    var createsDedicatedProcessGroup: Bool
    var terminationScope: ManagedProcessTerminationScope

    static let controlledProcessGroup = ManagedServiceProcessPolicy(
        createsDedicatedProcessGroup: true,
        terminationScope: .controlledProcessGroup
    )

    static let rootProcessOnly = ManagedServiceProcessPolicy(
        createsDedicatedProcessGroup: true,
        terminationScope: .rootProcessOnly
    )
}

enum ProcessGroupMemberRole: String, Codable, Sendable {
    case leader
    case listenerOwner
    case descendant
    case escapedDescendant
    case groupMember
}

struct ProcessGroupMemberSnapshot: Hashable, Codable, Sendable, Identifiable {
    var id: ProcessFingerprint { fingerprint }
    let fingerprint: ProcessFingerprint
    let processGroupID: Int32
    let role: ProcessGroupMemberRole
    let isInControlledGroup: Bool
    let isZombie: Bool

    init(
        fingerprint: ProcessFingerprint,
        processGroupID: Int32,
        role: ProcessGroupMemberRole,
        isInControlledGroup: Bool,
        isZombie: Bool = false
    ) {
        self.fingerprint = fingerprint
        self.processGroupID = processGroupID
        self.role = role
        self.isInControlledGroup = isInControlledGroup
        self.isZombie = isZombie
    }
}

struct ProcessGroupSnapshot: Hashable, Codable, Sendable, Identifiable {
    let id: UUID
    let runtimeID: UUID
    let managedServiceID: UUID
    let processGroupID: Int32
    let leaderFingerprint: ProcessFingerprint
    let members: [ProcessGroupMemberSnapshot]
    let capturedAt: Date

    init(
        id: UUID = UUID(),
        runtimeID: UUID,
        managedServiceID: UUID,
        processGroupID: Int32,
        leaderFingerprint: ProcessFingerprint,
        members: [ProcessGroupMemberSnapshot],
        capturedAt: Date = Date()
    ) {
        self.id = id
        self.runtimeID = runtimeID
        self.managedServiceID = managedServiceID
        self.processGroupID = processGroupID
        self.leaderFingerprint = leaderFingerprint
        self.members = members.sorted { $0.fingerprint.pid < $1.fingerprint.pid }
        self.capturedAt = capturedAt
    }

    var controlledMembers: [ProcessGroupMemberSnapshot] {
        members.filter(\.isInControlledGroup)
    }

    var escapedDescendants: [ProcessGroupMemberSnapshot] {
        members.filter { !$0.isInControlledGroup }
    }

    var liveControlledMembers: [ProcessGroupMemberSnapshot] {
        members.filter { $0.isInControlledGroup && !$0.isZombie }
    }
}

struct ManagedRuntimeHandle: Hashable, Codable, Sendable, Identifiable {
    let id: UUID
    let managedServiceID: UUID
    let leaderFingerprint: ProcessFingerprint
    let processGroupID: Int32
    let processPolicy: ManagedServiceProcessPolicy
    let launchedAt: Date
}
