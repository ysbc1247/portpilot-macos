import Foundation
import SwiftData

enum ManagedServicePersistence {
    @MainActor
    static func configurations(in context: ModelContext) throws -> [ManagedServiceConfiguration] {
        let profiles = try context.fetch(FetchDescriptor<LaunchProfileRecord>())
        let dependencies = try context.fetch(FetchDescriptor<ProfileDependencyRecord>())
        let ports = try context.fetch(FetchDescriptor<ExpectedPortRecord>())
        let policies = try context.fetch(FetchDescriptor<ManagedServiceProcessPolicyRecord>())
        let checks = try context.fetch(FetchDescriptor<ManagedServiceCheckRecord>())
        return profiles.compactMap {
            $0.configuration(
                dependencies: dependencies,
                expectedPorts: ports,
                processPolicies: policies,
                serviceChecks: checks
            )
        }
    }

    @MainActor
    static func configuration(id: UUID, in context: ModelContext) throws -> ManagedServiceConfiguration? {
        try configurations(in: context).first { $0.id == id }
    }

    @MainActor
    static func save(_ candidate: ManagedServiceConfiguration, in context: ModelContext) throws {
        let serviceID = candidate.id
        let profileDescriptor = FetchDescriptor<LaunchProfileRecord>(
            predicate: #Predicate { $0.id == serviceID }
        )
        let existing = try context.fetch(profileDescriptor).first
        let target = existing ?? LaunchProfileRecord(
            id: candidate.id,
            name: candidate.name,
            command: candidate.command,
            workingDirectory: candidate.workingDirectory
        )
        let encoder = JSONEncoder()
        target.projectID = candidate.projectID
        target.name = candidate.name
        target.kindRawValue = candidate.launchMechanism.rawValue
        target.command = candidate.command
        target.argumentsData = try encoder.encode(candidate.arguments)
        target.workingDirectory = candidate.workingDirectory
        target.shellData = try encoder.encode(candidate.shell)
        target.environmentData = try encoder.encode(candidate.environment)
        target.secretReferencesData = try encoder.encode(candidate.secretReferences)
        target.startupTimeoutSeconds = candidate.startupTimeoutSeconds
        target.shutdownTimeoutSeconds = candidate.shutdownTimeoutSeconds
        target.restartPolicyRawValue = candidate.restartPolicy.rawValue
        target.healthCheckData = try candidate.healthCheck.map(encoder.encode)
        target.logFile = candidate.logFile
        target.tagsData = try encoder.encode(candidate.tags)
        target.icon = candidate.icon
        target.isFavorite = candidate.isFavorite
        target.launchesAutomatically = candidate.launchesAutomatically
        target.isReviewed = candidate.isReviewed
        target.updatedAt = Date()
        if existing == nil { context.insert(target) }

        let dependencies = try context.fetch(FetchDescriptor<ProfileDependencyRecord>())
            .filter { $0.profileID == serviceID }
        dependencies.forEach(context.delete)
        candidate.dependencyServiceIDs.forEach {
            context.insert(ProfileDependencyRecord(profileID: serviceID, dependencyProfileID: $0))
        }

        let ports = try context.fetch(FetchDescriptor<ExpectedPortRecord>())
            .filter { $0.profileID == serviceID }
        ports.forEach(context.delete)
        candidate.expectedPorts.forEach {
            context.insert(ExpectedPortRecord(
                id: $0.id,
                profileID: serviceID,
                port: $0.port,
                protocolKind: $0.protocolKind,
                required: $0.required
            ))
        }

        let policies = try context.fetch(FetchDescriptor<ManagedServiceProcessPolicyRecord>())
        if let policy = policies.first(where: { $0.managedServiceID == serviceID }) {
            policy.createsDedicatedProcessGroup = candidate.processPolicy.createsDedicatedProcessGroup
            policy.terminationScopeRawValue = candidate.processPolicy.terminationScope.rawValue
            policy.updatedAt = Date()
        } else {
            context.insert(ManagedServiceProcessPolicyRecord(
                managedServiceID: serviceID,
                policy: candidate.processPolicy
            ))
        }

        let checks = try context.fetch(FetchDescriptor<ManagedServiceCheckRecord>())
        if let checkRecord = checks.first(where: { $0.managedServiceID == serviceID }) {
            try checkRecord.apply(candidate.serviceChecks)
        } else if !candidate.serviceChecks.isEmpty {
            context.insert(try ManagedServiceCheckRecord(
                managedServiceID: serviceID,
                checks: candidate.serviceChecks
            ))
        }
        try context.save()
    }

    @MainActor
    static func delete(id: UUID, in context: ModelContext) throws {
        let serviceID = id
        let profiles = try context.fetch(FetchDescriptor<LaunchProfileRecord>())
        guard let profile = profiles.first(where: { $0.id == serviceID }) else { return }
        try context.fetch(FetchDescriptor<ProfileDependencyRecord>())
            .filter { $0.profileID == serviceID || $0.dependencyProfileID == serviceID }
            .forEach(context.delete)
        try context.fetch(FetchDescriptor<ExpectedPortRecord>())
            .filter { $0.profileID == serviceID }.forEach(context.delete)
        try context.fetch(FetchDescriptor<ManagedServiceProcessPolicyRecord>())
            .filter { $0.managedServiceID == serviceID }.forEach(context.delete)
        try context.fetch(FetchDescriptor<ManagedServiceCheckRecord>())
            .filter { $0.managedServiceID == serviceID }.forEach(context.delete)
        context.delete(profile)
        try context.save()
    }
}
