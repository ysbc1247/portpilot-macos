import Foundation

actor DockerAssociationProvider {
    private let client: any DockerServing
    private var mappings: [String: DockerAssociation] = [:]
    private var lastRefresh = Date.distantPast

    init(client: any DockerServing) {
        self.client = client
    }

    func correlate(_ listeners: [NetworkListener]) async -> [NetworkListener] {
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

private extension NetworkListener {
    func associatingDocker(_ association: DockerAssociation) -> NetworkListener {
        let value = ProcessMetadata(
            identity: process.identity,
            parentPID: process.parentPID,
            name: process.name,
            executablePath: process.executablePath,
            commandLine: process.commandLine,
            owner: process.owner,
            currentDirectory: process.currentDirectory,
            parentName: process.parentName,
            runtime: .docker,
            project: process.project,
            isSystemProcess: process.isSystemProcess,
            docker: association,
            launchedByDevBerth: process.launchedByDevBerth,
            launchProfileID: process.launchProfileID
        )
        return NetworkListener(
            protocolKind: protocolKind,
            address: address,
            port: port,
            process: value,
            firstDetectedAt: firstDetectedAt,
            lastDetectedAt: lastDetectedAt
        )
    }
}

