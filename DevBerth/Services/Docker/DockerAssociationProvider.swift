import Foundation

actor DockerAssociationProvider {
    private let client: any DockerServing
    private var mappings: [String: DockerAssociation] = [:]
    private var lastRefresh = Date.distantPast

    init(client: any DockerServing) {
        self.client = client
    }

    func correlate(_ listeners: [ObservedListener]) async -> [ObservedListener] {
        if Date().timeIntervalSince(lastRefresh) > 5 {
            await refresh()
        }
        return listeners.map { listener in
            let key = "\(listener.protocolKind.rawValue):\(listener.port)"
            guard let association = mappings[key] else { return listener }
            return listener.associatingDocker(association)
        }
    }

    private func refresh() async {
        lastRefresh = Date()
        guard case .available = await client.availability(), let containers = try? await client.runningContainers() else {
            mappings = [:]
            return
        }
        var values: [String: DockerAssociation] = [:]
        for container in containers {
            for port in container.ports {
                values["\(port.protocolKind.rawValue):\(port.hostPort)"] = DockerAssociation(
                    containerID: container.id,
                    containerName: container.name,
                    image: container.image,
                    composeProject: container.composeProject,
                    composeService: container.composeService,
                    containerPort: port.containerPort
                )
            }
        }
        mappings = values
    }
}

private extension ObservedListener {
    func associatingDocker(_ association: DockerAssociation) -> ObservedListener {
        let value = ObservedProcess(
            fingerprint: process.fingerprint,
            name: process.name,
            commandLine: process.commandLine,
            owner: process.owner,
            currentDirectory: process.currentDirectory,
            parentName: process.parentName,
            runtime: .docker,
            project: process.project,
            isSystemProcess: process.isSystemProcess,
            docker: association,
            launchedByDevBerth: process.launchedByDevBerth,
            managedServiceID: process.managedServiceID
        )
        return ObservedListener(
            protocolKind: protocolKind,
            address: address,
            port: port,
            process: value,
            firstDetectedAt: firstDetectedAt,
            lastDetectedAt: lastDetectedAt
        )
    }
}
