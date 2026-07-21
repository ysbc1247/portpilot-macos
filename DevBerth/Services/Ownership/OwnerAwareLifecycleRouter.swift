import Foundation

actor OwnerAwareLifecycleRouter: OwnerAwareLifecycleRouting {
    private let processController: any ProcessControlling
    private let managedServiceController: any LaunchProfileServing
    private let dockerController: any DockerServing
    private let runtimeRegistry: ManagedRuntimeRegistry

    init(
        processController: any ProcessControlling,
        managedServiceController: any LaunchProfileServing,
        dockerController: any DockerServing,
        runtimeRegistry: ManagedRuntimeRegistry
    ) {
        self.processController = processController
        self.managedServiceController = managedServiceController
        self.dockerController = dockerController
        self.runtimeRegistry = runtimeRegistry
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
                return result(
                    controller: .dockerContainer,
                    action: action,
                    didStop: true,
                    summary: "Docker stopped container \(docker.containerName).",
                    startedAt: startedAt
                )
            case .restart:
                try await dockerController.restart(containerID: docker.containerID)
                return result(
                    controller: .dockerContainer,
                    action: action,
                    didStop: false,
                    summary: "Docker restarted container \(docker.containerName).",
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
            case .inspect, .restart:
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
            throw DevBerthError.ownerActionUnavailable(
                owner: graph.primaryConclusion.value,
                reason: "Compose project files, working directory, and environment context must be verified before a scoped Compose action. No host PID signal was sent."
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
}
