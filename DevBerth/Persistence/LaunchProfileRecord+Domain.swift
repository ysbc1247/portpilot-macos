import Foundation

extension LaunchProfileRecord {
    func configuration(
        dependencies: [ProfileDependencyRecord],
        expectedPorts: [ExpectedPortRecord]
    ) -> ManagedServiceConfiguration? {
        guard let kind = LaunchMechanism(rawValue: kindRawValue) else { return nil }
        let decoder = JSONDecoder()
        let arguments = (try? decoder.decode([String].self, from: argumentsData)) ?? []
        let shell = (try? decoder.decode(ShellSelection.self, from: shellData)) ?? .direct
        let environment = (try? decoder.decode([String: String].self, from: environmentData)) ?? [:]
        let secretReferences = (try? decoder.decode([String: UUID].self, from: secretReferencesData)) ?? [:]
        let healthCheck = healthCheckData.flatMap { try? decoder.decode(HealthCheckConfiguration.self, from: $0) }
        let tags = (try? decoder.decode([String].self, from: tagsData)) ?? []
        let ports = expectedPorts
            .filter { $0.profileID == id }
            .compactMap { record -> ExpectedListenerConfiguration? in
                guard let port = UInt16(exactly: record.port), let kind = ListenerProtocol(rawValue: record.protocolRawValue) else { return nil }
                return .init(id: record.id, port: port, protocolKind: kind, required: record.required)
            }
        return ManagedServiceConfiguration(
            id: id,
            name: name,
            projectID: projectID,
            launchMechanism: kind,
            command: command,
            arguments: arguments,
            workingDirectory: workingDirectory,
            shell: shell,
            environment: environment,
            secretReferences: secretReferences,
            expectedPorts: ports,
            startupTimeoutSeconds: startupTimeoutSeconds,
            shutdownTimeoutSeconds: shutdownTimeoutSeconds,
            restartPolicy: RestartPolicy(rawValue: restartPolicyRawValue) ?? .never,
            healthCheck: healthCheck,
            dependencyServiceIDs: dependencies.filter { $0.profileID == id }.map(\.dependencyProfileID),
            logFile: logFile,
            tags: tags,
            icon: icon,
            launchesAutomatically: launchesAutomatically,
            isFavorite: isFavorite,
            isReviewed: isReviewed
        )
    }
}
