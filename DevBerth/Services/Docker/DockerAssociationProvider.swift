import Foundation

actor DockerAssociationProvider {
    private let client: any DockerServing
    private let lifecycleRecorder: (any RuntimeLifecycleRecording)?
    private var mappings: [String: DockerAssociation] = [:]
    private var lastRefresh = Date.distantPast
    private var previousContainers: [String: DockerContainer]?
    private let refreshInterval: TimeInterval

    init(
        client: any DockerServing,
        lifecycleRecorder: (any RuntimeLifecycleRecording)? = nil,
        refreshInterval: TimeInterval = 5
    ) {
        self.client = client
        self.lifecycleRecorder = lifecycleRecorder
        self.refreshInterval = refreshInterval
    }

    func correlate(_ listeners: [ObservedListener]) async -> [ObservedListener] {
        if Date().timeIntervalSince(lastRefresh) > refreshInterval {
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
        await recordTransitions(to: containers)
        var values: [String: DockerAssociation] = [:]
        for container in containers {
            for port in container.ports {
                values["\(port.protocolKind.rawValue):\(port.hostPort)"] = DockerAssociation(
                    containerID: container.id,
                    containerName: container.name,
                    image: container.image,
                    composeProject: container.composeProject,
                    composeService: container.composeService,
                    containerPort: port.containerPort,
                    state: container.state,
                    healthStatus: container.healthStatus,
                    restartPolicy: container.restartPolicy,
                    composeContext: container.composeContext,
                    composeContextIssue: container.composeContextIssue
                )
            }
        }
        mappings = values
    }

    private func recordTransitions(to containers: [DockerContainer]) async {
        let current = Dictionary(uniqueKeysWithValues: containers.map { ($0.id, $0) })
        guard let previousContainers else {
            self.previousContainers = current
            return
        }
        for container in containers where previousContainers[container.id] == nil {
            await record(
                category: .dockerContainerStarted,
                summary: "Docker container \(container.name) appeared.",
                container: container,
                change: "appeared"
            )
            if container.composeProject != nil {
                await recordComposeChange(container: container, change: "service container appeared")
            }
        }
        for container in previousContainers.values where current[container.id] == nil {
            await record(
                category: .dockerContainerStopped,
                summary: "Docker container \(container.name) disappeared.",
                container: container,
                change: "disappeared"
            )
            if container.composeProject != nil {
                await recordComposeChange(container: container, change: "service container disappeared")
            }
        }
        for container in containers {
            guard let previous = previousContainers[container.id] else { continue }
            let oldScope = [previous.composeProject, previous.composeService, previous.composeContext?.configurationHash]
            let newScope = [container.composeProject, container.composeService, container.composeContext?.configurationHash]
            if oldScope != newScope {
                await recordComposeChange(container: container, change: "project context changed")
            }
        }
        self.previousContainers = current
    }

    private func record(
        category: LifecycleEventCategory,
        summary: String,
        container: DockerContainer,
        change: String
    ) async {
        guard let lifecycleRecorder else { return }
        try? await lifecycleRecorder.record(LifecycleEvent(
            category: category,
            outcome: .observed,
            source: .docker,
            trigger: .observation,
            summary: summary,
            details: [
                "change": change,
                "containerID": container.id,
                "containerName": container.name,
                "image": container.image,
                "composeProject": container.composeProject ?? "",
                "composeService": container.composeService ?? ""
            ]
        ))
    }

    private func recordComposeChange(container: DockerContainer, change: String) async {
        await record(
            category: .dockerComposeChanged,
            summary: "Compose \(container.composeProject ?? "project")/\(container.composeService ?? "service") \(change).",
            container: container,
            change: change
        )
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
