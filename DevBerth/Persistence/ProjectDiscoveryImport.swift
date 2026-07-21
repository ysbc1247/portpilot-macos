import Foundation
import SwiftData

struct ProjectDiscoveryImportResult {
    let importedServiceIDs: [UUID]
    let unresolvedDependencies: [String]
}

enum ProjectDiscoveryImporter {
    @MainActor
    static func importCandidates(
        _ candidates: [DiscoveredServiceCandidate],
        report: ProjectDiscoveryReport,
        projectID: UUID,
        into context: ModelContext,
        importedAt: Date = Date()
    ) throws -> ProjectDiscoveryImportResult {
        let encoder = JSONEncoder()
        let selectedNames = Dictionary(grouping: candidates, by: \.name)
        let uniqueIDsByName = selectedNames.compactMapValues { values in
            values.count == 1 ? values[0].id : nil
        }
        var unresolved = Set<String>()

        for candidate in candidates {
            let configuration = candidate.unreviewedConfiguration(projectID: projectID)
            let record = LaunchProfileRecord(
                id: configuration.id,
                name: configuration.name,
                command: configuration.command,
                workingDirectory: configuration.workingDirectory
            )
            record.projectID = projectID
            record.kindRawValue = configuration.launchMechanism.rawValue
            record.argumentsData = try encoder.encode(configuration.arguments)
            record.shellData = try encoder.encode(configuration.shell)
            record.environmentData = try encoder.encode(configuration.environment)
            record.secretReferencesData = try encoder.encode(configuration.secretReferences)
            record.startupTimeoutSeconds = configuration.startupTimeoutSeconds
            record.shutdownTimeoutSeconds = configuration.shutdownTimeoutSeconds
            record.restartPolicyRawValue = configuration.restartPolicy.rawValue
            record.tagsData = try encoder.encode(configuration.tags)
            record.isReviewed = false
            record.updatedAt = importedAt
            context.insert(record)
            context.insert(ManagedServiceProcessPolicyRecord(
                managedServiceID: configuration.id,
                policy: configuration.processPolicy,
                updatedAt: importedAt
            ))
            for listener in configuration.expectedPorts {
                context.insert(ExpectedPortRecord(
                    id: listener.id,
                    profileID: configuration.id,
                    port: listener.port,
                    protocolKind: listener.protocolKind,
                    required: listener.required
                ))
            }
            for dependencyName in candidate.dependencyCandidateNames {
                if let dependencyID = uniqueIDsByName[dependencyName] {
                    context.insert(ProfileDependencyRecord(
                        profileID: configuration.id,
                        dependencyProfileID: dependencyID
                    ))
                } else {
                    unresolved.insert(dependencyName)
                }
            }
        }

        for finding in report.findings {
            let metadata = ProjectDiscoveryMetadata(
                id: UUID(),
                projectID: projectID,
                rootPath: report.rootPath,
                adapterIdentifier: finding.adapterIdentifier,
                projectType: finding.projectType,
                evidence: finding.evidence,
                confidence: finding.confidence,
                discoveredAt: report.discoveredAt,
                importedAt: importedAt
            )
            context.insert(try ProjectDiscoveryRecord(metadata: metadata))
        }
        try context.save()
        return ProjectDiscoveryImportResult(
            importedServiceIDs: candidates.map(\.id),
            unresolvedDependencies: unresolved.sorted()
        )
    }
}
