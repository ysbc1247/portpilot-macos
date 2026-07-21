import Foundation

actor OwnerAwareLifecycleRouter: OwnerAwareLifecycleRouting {
    private let processController: any ProcessControlling
    private let managedServiceController: any LaunchProfileServing
    private let dockerController: any DockerServing
    private let runtimeRegistry: ManagedRuntimeRegistry
    private let lifecycleRecorder: (any RuntimeLifecycleRecording)?

    init(
        processController: any ProcessControlling,
        managedServiceController: any LaunchProfileServing,
        dockerController: any DockerServing,
        runtimeRegistry: ManagedRuntimeRegistry,
        lifecycleRecorder: (any RuntimeLifecycleRecording)? = nil
    ) {
        self.processController = processController
        self.managedServiceController = managedServiceController
        self.dockerController = dockerController
        self.runtimeRegistry = runtimeRegistry
        self.lifecycleRecorder = lifecycleRecorder
    }

    func perform(
        _ action: LifecycleActionKind,
        on graph: RuntimeOwnershipGraph,
        forceConfirmed: Bool = false
    ) async throws -> OwnerAwareLifecycleResult {
        let startedAt = Date()
        guard graph.recommendation.supportedActions.contains(action) else {
            throw DevBerthError.ownerActionUnavailable(
                owner: graph.primaryConclusion.category.title,
                reason: graph.recommendation.reason
            )
        }

        switch graph.recommendation.controllerKind {
        case .managedProcess:
            guard
                action == .gracefulStop || action == .restart,
                let serviceID = graph.managedServiceID,
                let runtimeID = graph.managedRuntimeID,
                let registration = await runtimeRegistry.registration(serviceID: serviceID),
                registration.runtime.id == runtimeID
            else {
                throw DevBerthError.ownerActionUnavailable(
                    owner: graph.primaryConclusion.value,
                    reason: "The managed runtime registration changed. Refresh ownership before acting."
                )
            }
            try await managedServiceController.stop(
                profileID: serviceID,
                timeoutSeconds: registration.configuration.shutdownTimeoutSeconds
            )
            if action == .restart {
                try await managedServiceController.launch(registration.configuration)
            }
            return result(
                controller: .managedProcess,
                action: action,
                didStop: true,
                summary: action == .restart
                    ? "Restarted the exact verified managed-service definition."
                    : "Stopped the verified managed process scope.",
                startedAt: startedAt
            )

        case .dockerContainer:
            guard let docker = graph.listener.process.docker else {
                throw DevBerthError.ownerActionUnavailable(
                    owner: graph.primaryConclusion.value,
                    reason: "The Docker container association is no longer present."
                )
            }
            switch action {
            case .gracefulStop:
                try await dockerController.stop(containerID: docker.containerID)
                await recordDockerEvent(
                    category: .dockerContainerStopped,
                    summary: "Docker stopped container \(docker.containerName).",
                    docker: docker,
                    graph: graph,
                    startedAt: startedAt
                )
                return result(
                    controller: .dockerContainer,
                    action: action,
                    didStop: true,
                    summary: "Docker stopped container \(docker.containerName).",
                    startedAt: startedAt
                )
            case .restart:
                try await dockerController.restart(containerID: docker.containerID)
                await recordDockerEvent(
                    category: .dockerContainerStarted,
                    summary: "Docker restarted container \(docker.containerName).",
                    docker: docker,
                    graph: graph,
                    startedAt: startedAt
                )
                return result(
                    controller: .dockerContainer,
                    action: action,
                    didStop: false,
                    summary: "Docker restarted container \(docker.containerName).",
                    startedAt: startedAt
                )
            case .remove:
                try await dockerController.remove(containerID: docker.containerID)
                await recordDockerEvent(
                    category: .dockerContainerStopped,
                    summary: "Docker removed container \(docker.containerName).",
                    docker: docker,
                    graph: graph,
                    startedAt: startedAt
                )
                return result(
                    controller: .dockerContainer,
                    action: action,
                    didStop: true,
                    summary: "Docker removed exact container \(docker.containerName).",
                    startedAt: startedAt
                )
            case .inspect, .forceStop:
                throw DevBerthError.ownerActionUnavailable(
                    owner: graph.primaryConclusion.value,
                    reason: "Use Docker lifecycle actions rather than a host PID signal."
                )
            }

        case .guardedExternalProcess, .kubernetesPortForward, .sshTunnel:
            let mode: TerminationMode
            switch action {
            case .gracefulStop:
                mode = .graceful(timeoutSeconds: 5)
            case .forceStop:
                mode = .force(confirmed: forceConfirmed)
            case .inspect, .restart, .remove:
                throw DevBerthError.ownerActionUnavailable(
                    owner: graph.primaryConclusion.value,
                    reason: "External observations do not provide a verified restart definition."
                )
            }
            let outcome = try await processController.terminate(
                ProcessActionTarget(listener: graph.listener),
                mode: mode
            )
            return result(
                controller: graph.recommendation.controllerKind,
                action: action,
                didStop: outcome.didExit,
                summary: outcome.didExit
                    ? "The revalidated external process exited."
                    : "The external process did not exit before the graceful timeout.",
                startedAt: startedAt
            )

        case .dockerComposeService:
            guard let docker = graph.listener.process.docker,
                  let context = docker.composeContext else {
                throw DevBerthError.ownerActionUnavailable(
                    owner: graph.primaryConclusion.value,
                    reason: "Compose project files, working directory, configuration hash, environment context, and exact container membership must be verified before a scoped action. No host PID signal was sent."
                )
            }
            switch action {
            case .gracefulStop:
                try await dockerController.stopComposeService(context: context)
            case .restart:
                try await dockerController.restartComposeService(context: context)
            case .remove:
                try await dockerController.removeComposeService(context: context)
            case .inspect, .forceStop:
                throw DevBerthError.ownerActionUnavailable(
                    owner: graph.primaryConclusion.value,
                    reason: "Use the verified Compose service actions rather than a host PID signal."
                )
            }
            await recordDockerEvent(
                category: .dockerComposeChanged,
                summary: "Compose \(context.projectName)/\(context.serviceName) completed \(action.rawValue).",
                docker: docker,
                graph: graph,
                startedAt: startedAt
            )
            return result(
                controller: .dockerComposeService,
                action: action,
                didStop: action != .restart,
                summary: "Docker Compose completed \(action.rawValue) for exact service \(context.projectName)/\(context.serviceName).",
                startedAt: startedAt
            )
        case .homebrewService:
            throw DevBerthError.ownerActionUnavailable(
                owner: graph.primaryConclusion.value,
                reason: "A Homebrew service name and user/system domain must be verified before running brew services. No PID signal was sent."
            )
        case .launchdService:
            throw DevBerthError.ownerActionUnavailable(
                owner: graph.primaryConclusion.value,
                reason: "A launchd domain and label must be verified and explicitly approved before a controlling-service action. No child PID signal was sent."
            )
        case .unavailable:
            throw DevBerthError.ownerActionUnavailable(
                owner: graph.primaryConclusion.value,
                reason: graph.recommendation.reason
            )
        }
    }

    private func result(
        controller: LifecycleControllerKind,
        action: LifecycleActionKind,
        didStop: Bool,
        summary: String,
        startedAt: Date
    ) -> OwnerAwareLifecycleResult {
        OwnerAwareLifecycleResult(
            controllerKind: controller,
            action: action,
            didStop: didStop,
            summary: summary,
            durationSeconds: Date().timeIntervalSince(startedAt)
        )
    }

    private func recordDockerEvent(
        category: LifecycleEventCategory,
        summary: String,
        docker: DockerAssociation,
        graph: RuntimeOwnershipGraph,
        startedAt: Date
    ) async {
        guard let lifecycleRecorder else { return }
        try? await lifecycleRecorder.record(LifecycleEvent(
            timestamp: Date(),
            managedServiceID: graph.managedServiceID,
            projectID: graph.projectID,
            category: category,
            outcome: .succeeded,
            source: .docker,
            trigger: .userAction,
            summary: summary,
            details: [
                "containerID": docker.containerID,
                "containerName": docker.containerName,
                "composeProject": docker.composeProject ?? "",
                "composeService": docker.composeService ?? ""
            ],
            listenerID: graph.listenerID,
            durationSeconds: Date().timeIntervalSince(startedAt)
        ))
    }
}
