import Foundation
import SwiftData

@Model
final class ManagedServiceCheckRecord {
    @Attribute(.unique) var managedServiceID: UUID
    var checksData: Data
    var updatedAt: Date

    init(
        managedServiceID: UUID,
        checks: [ServiceCheckConfiguration],
        updatedAt: Date = Date()
    ) throws {
        self.managedServiceID = managedServiceID
        checksData = try JSONEncoder().encode(checks)
        self.updatedAt = updatedAt
    }

    var checks: [ServiceCheckConfiguration] {
        (try? JSONDecoder().decode([ServiceCheckConfiguration].self, from: checksData)) ?? []
    }

    func apply(_ checks: [ServiceCheckConfiguration]) throws {
        checksData = try JSONEncoder().encode(checks)
        updatedAt = Date()
    }
}

enum DevBerthSchemaV6: VersionedSchema {
    static var versionIdentifier = Schema.Version(6, 0, 0)
    static var models: [any PersistentModel.Type] {
        DevBerthSchemaV5.models + [ManagedServiceCheckRecord.self]
    }
}
