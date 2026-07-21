import Foundation

protocol RuntimeOwnershipResolving: Sendable {
    func resolve(listener: ObservedListener) async -> RuntimeOwnershipGraph
}

struct RuntimeOwnershipResolver: RuntimeOwnershipResolving, Sendable {
    private let runtimeRegistry: ManagedRuntimeRegistry
    private let lineageProvider: any ProcessLineageProviding
    private let groupOperator: any ProcessGroupOperating
    private let clock: @Sendable () -> Date

    init(
        runtimeRegistry: ManagedRuntimeRegistry,
        lineageProvider: any ProcessLineageProviding,
        groupOperator: any ProcessGroupOperating = DarwinProcessGroupOperator(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.runtimeRegistry = runtimeRegistry
        self.lineageProvider = lineageProvider
        self.groupOperator = groupOperator
        self.clock = clock
    }

    func resolve(listener: ObservedListener) async -> RuntimeOwnershipGraph {
        let resolvedAt = clock()
        let processGroupID = groupOperator.processGroupID(for: listener.process.fingerprint.pid)
        let lineage = await lineageProvider.lineage(for: listener.process)
        let registration = await runtimeRegistry.registration(
            matching: listener.process.fingerprint,
            processGroupID: processGroupID
        )
        let classification: OwnershipClassification
        if let registration {
            classification = Self.managedClassification(
                registration: registration,
                listener: listener,
                processGroupID: processGroupID
            )
        } else if let docker = listener.process.docker {
            classification = Self.dockerClassification(docker: docker, listener: listener)
        } else {
            classification = OwnershipRuleEngine.classify(listener: listener, lineage: lineage)
        }
        let conclusion = OwnershipConclusion(
            subject: .listener(id: listener.id),
            category: classification.category,
            value: classification.value,
            confidence: classification.confidence,
            evidence: classification.evidence,
            detectionMethod: classification.detectionMethod,
            observedAt: resolvedAt
        )
        return RuntimeOwnershipGraph(
            listenerID: listener.id,
            listener: listener,
            processGroupID: processGroupID,
            processLineage: lineage,
            primaryConclusion: conclusion,
            additionalConclusions: [],
            managedRuntimeID: registration?.runtime.id,
            managedServiceID: registration?.configuration.id,
            managedConfigurationDigest: registration.map {
                ManagedServiceConfigurationDigest.make(for: $0.configuration)
            },
            projectID: registration?.configuration.projectID,
            workspaceSessionIDs: [],
            recommendation: classification.recommendation,
            resolvedAt: resolvedAt
        )
    }

    private static func managedClassification(
        registration: ManagedRuntimeRegistration,
        listener: ObservedListener,
        processGroupID: Int32?
    ) -> OwnershipClassification {
        var evidence = [
            OwnershipEvidenceItem(
                field: "managed service",
                value: registration.configuration.name,
                source: "DevBerth runtime registry",
                isVerified: true
            ),
            OwnershipEvidenceItem(
                field: "runtime ID",
                value: registration.runtime.id.uuidString,
                source: "DevBerth runtime registry",
                isVerified: true
            ),
            OwnershipEvidenceItem(
                field: "process group",
                value: String(registration.runtime.processGroupID),
                source: "managed launch registration",
                isVerified: processGroupID == registration.runtime.processGroupID
            )
        ]
        if registration.latestSnapshot.members.contains(where: {
            $0.fingerprint.pid == listener.process.fingerprint.pid && $0.role == .listenerOwner
        }) {
            evidence.append(OwnershipEvidenceItem(
                field: "listener owner",
                value: "PID \(listener.process.fingerprint.pid)",
                source: "managed process-group snapshot",
                isVerified: true
            ))
        }
        return OwnershipClassification(
            category: .applicationManagedProcess,
            value: registration.configuration.name,
            confidence: .verified,
            evidence: evidence,
            detectionMethod: .managedRuntimeRegistry,
            recommendation: .init(
                controllerKind: .managedProcess,
                title: "Use the managed service policy",
                reason: "DevBerth launched and registered this runtime, so it can stop or restart the reviewed process scope instead of guessing from a PID.",
                supportedActions: [.inspect, .gracefulStop, .restart]
            )
        )
    }

    private static func dockerClassification(
        docker: DockerAssociation,
        listener: ObservedListener
    ) -> OwnershipClassification {
        let isCompose = docker.composeProject != nil && docker.composeService != nil
        let value = isCompose
            ? "\(docker.composeProject!)/\(docker.composeService!)"
            : docker.containerName
        var evidence = [
            OwnershipEvidenceItem(
                field: "container",
                value: docker.containerName,
                source: "Docker container metadata",
                isVerified: true
            ),
            OwnershipEvidenceItem(
                field: "image",
                value: docker.image,
                source: "Docker container metadata",
                isVerified: true
            ),
            OwnershipEvidenceItem(
                field: "published listener",
                value: "\(listener.protocolKind.rawValue) :\(listener.port)",
                source: "Docker published-port mapping",
                isVerified: true
            )
        ]
        if let containerPort = docker.containerPort {
            evidence.append(.init(
                field: "container port",
                value: String(containerPort),
                source: "Docker published-port mapping",
                isVerified: true
            ))
        }
        if let state = docker.state {
            evidence.append(.init(
                field: "container state",
                value: state,
                source: "Docker Engine inspection",
                isVerified: true
            ))
        }
        if let health = docker.healthStatus {
            evidence.append(.init(
                field: "container health",
                value: health,
                source: "Docker Engine inspection",
                isVerified: true
            ))
        }
        if let restartPolicy = docker.restartPolicy {
            evidence.append(.init(
                field: "restart policy",
                value: restartPolicy,
                source: "Docker Engine inspection",
                isVerified: true
            ))
        }
        if let context = docker.composeContext {
            evidence += [
                .init(
                    field: "Compose working directory",
                    value: context.workingDirectory.path,
                    source: "canonical Compose labels + config hash verification",
                    isVerified: true
                ),
                .init(
                    field: "Compose configuration",
                    value: context.configurationFilePaths.joined(separator: ", "),
                    source: "canonical Compose labels + exact container membership",
                    isVerified: true
                ),
                .init(
                    field: "Compose environment files",
                    value: context.environmentFilePaths.joined(separator: ", ").nilIfEmpty ?? "None",
                    source: "canonical Compose labels",
                    isVerified: true
                )
            ]
        } else if let issue = docker.composeContextIssue {
            evidence.append(.init(
                field: "Compose action scope",
                value: issue,
                source: "Compose context verifier",
                isVerified: false
            ))
        }
        let hasVerifiedComposeContext = docker.composeContext != nil
        let controller: LifecycleControllerKind = isCompose && hasVerifiedComposeContext
            ? .dockerComposeService
            : .dockerContainer
        let actions: Set<LifecycleActionKind> = isCompose && !hasVerifiedComposeContext
            ? [.inspect, .gracefulStop, .restart]
            : [.inspect, .gracefulStop, .restart, .remove]
        return OwnershipClassification(
            category: isCompose ? .dockerComposeService : .dockerContainer,
            value: value,
            confidence: .verified,
            evidence: evidence,
            detectionMethod: isCompose ? .composeMetadata : .dockerMetadata,
            recommendation: .init(
                controllerKind: controller,
                title: isCompose && hasVerifiedComposeContext
                    ? "Use the Compose service controller"
                    : "Use the exact Docker container controller",
                reason: isCompose && docker.composeContext == nil
                    ? "\(docker.composeContextIssue ?? "The exact Compose action scope is not verified.") DevBerth can still stop or restart container \(docker.containerName) by its exact Engine ID without targeting the shared Docker host process."
                    : "The listener is published by Docker. Killing the observed host-side process would target the wrong ownership layer.",
                supportedActions: actions
            )
        )
    }
}

struct OwnershipClassification: Sendable {
    let category: OwnershipCategory
    let value: String
    let confidence: EvidenceConfidence
    let evidence: [OwnershipEvidenceItem]
    let detectionMethod: OwnershipDetectionMethod
    let recommendation: OwnershipActionRecommendation
}

enum OwnershipRuleEngine {
    static func classify(
        listener: ObservedListener,
        lineage: [ProcessLineageNode]
    ) -> OwnershipClassification {
        let process = listener.process
        let command = process.commandLine
        let commandLower = command.lowercased()
        let executable = process.executablePath?.lowercased() ?? ""
        let lineageText = lineage.dropFirst().map {
            "\($0.name) \($0.commandLine ?? "")"
        }.joined(separator: " ").lowercased()
        let parentNames = lineage.dropFirst().map { $0.name.lowercased() }

        if (executable.hasSuffix("/kubectl") || commandLower.contains("kubectl"))
            && commandLower.contains("port-forward") {
            return inferred(
                category: .kubernetesPortForward,
                value: "kubectl port-forward on :\(listener.port)",
                confidence: .stronglyInferred,
                method: .commandSignature,
                evidence: signatureEvidence("kubectl port-forward", source: "observed process command"),
                controller: .kubernetesPortForward,
                actionTitle: "Stop the port-forward process",
                reason: "The local forwarding process owns this listener; the Kubernetes workload should not be stopped."
            )
        }
        if (executable.hasSuffix("/ssh") || process.name.lowercased() == "ssh")
            && hasSSHForwardingFlag(command) {
            return inferred(
                category: .sshTunnel,
                value: "SSH tunnel on :\(listener.port)",
                confidence: .stronglyInferred,
                method: .commandSignature,
                evidence: signatureEvidence("SSH forwarding flag", source: "observed process command"),
                controller: .sshTunnel,
                actionTitle: "Stop the tunnel process",
                reason: "The SSH client process is the lifecycle owner of this local forwarding listener."
            )
        }
        if containsAny(lineageText, ["codex", "claude", "aider", "copilot agent", "cline", "roo-code"]) {
            return lineageClassification(
                category: .codingAgentLaunchedProcess,
                value: firstMatchingName(in: lineage, signatures: ["codex", "claude", "aider", "copilot", "cline", "roo"]) ?? "Coding agent",
                evidenceValue: "coding-agent ancestor",
                controller: .guardedExternalProcess,
                reason: "A coding-agent ancestor is inferred from process lineage; stopping the child may cause the agent to recreate it."
            )
        }
        if containsAny(lineageText, ["pm2", "nodemon", "supervisord", "foreman", "overmind", "watchexec", "cargo-watch"]) {
            return lineageClassification(
                category: .supervisorManagedProcess,
                value: firstMatchingName(in: lineage, signatures: ["pm2", "nodemon", "supervisord", "foreman", "overmind", "watchexec", "cargo-watch"]) ?? "Supervisor",
                evidenceValue: "supervisor ancestor",
                controller: .guardedExternalProcess,
                reason: "The parent supervisor may immediately recreate this child. DevBerth can still stop the exact revalidated process instance, but restart requires a reviewed managed-service definition."
            )
        }
        let hasLaunchdParent = parentNames.contains("launchd") || process.fingerprint.parentPID == 1
        let looksHomebrewInstalled = executable.contains("/homebrew/") || executable.contains("/cellar/")
        if hasLaunchdParent && looksHomebrewInstalled {
            return inferred(
                category: .homebrewService,
                value: process.name,
                confidence: .stronglyInferred,
                method: .serviceManager,
                evidence: [
                    .init(field: "executable", value: process.executablePath ?? process.name, source: "process fingerprint", isVerified: true),
                    .init(field: "parent", value: "launchd", source: "process lineage", isVerified: true)
                ],
                controller: .guardedExternalProcess,
                actionTitle: "Stop this observed process instance",
                reason: "The executable is under a Homebrew prefix and has launchd as its current parent, but no exact formula or service domain is verified. DevBerth can stop this exact revalidated process instance without guessing a brew service."
            )
        }
        if hasLaunchdParent {
            let daemon = process.fingerprint.uid == 0
            return inferred(
                category: daemon ? .launchDaemon : .launchAgent,
                value: process.name,
                confidence: .stronglyInferred,
                method: .launchdMetadata,
                evidence: [
                    .init(field: "parent", value: "launchd", source: "process lineage", isVerified: true),
                    .init(field: "UID", value: process.fingerprint.uid.map(String.init) ?? "Unavailable", source: "process fingerprint", isVerified: process.fingerprint.uid != nil)
                ],
                controller: daemon ? .launchdService : .guardedExternalProcess,
                actionTitle: daemon ? "Inspect the launch daemon" : "Stop this observed process instance",
                reason: daemon
                    ? "A root launch daemon requires an exact launchd domain and label before control is safe."
                    : "Parent PID 1 does not prove that launchd owns this process as a job. DevBerth can stop the exact revalidated user process instance; restart requires a reviewed managed-service definition."
            )
        }
        if containsAny(lineageText, ["xcode", "visual studio code", "code helper", "cursor", "windsurf", "intellij", "webstorm", "pycharm", "goland", "rubymine", "nova", "zed"]) {
            return lineageClassification(
                category: .ideLaunchedProcess,
                value: firstMatchingName(in: lineage, signatures: ["xcode", "code", "cursor", "windsurf", "intellij", "webstorm", "pycharm", "goland", "rubymine", "nova", "zed"]) ?? "IDE",
                evidenceValue: "IDE ancestor",
                controller: .guardedExternalProcess,
                reason: "An IDE ancestor is inferred from process lineage; the IDE may own or recreate the task."
            )
        }
        if containsAny(lineageText, ["terminal.app", "/terminal", "iterm", "warp", "ghostty", "wezterm", "kitty"]) {
            return lineageClassification(
                category: .terminalLaunchedProcess,
                value: firstMatchingName(in: lineage, signatures: ["terminal", "iterm", "warp", "ghostty", "wezterm", "kitty"]) ?? "Terminal",
                evidenceValue: "terminal ancestor",
                controller: .guardedExternalProcess,
                reason: "A terminal ancestor is inferred. DevBerth can guard a process signal but cannot reconstruct the original shell session."
            )
        }
        if let shell = parentNames.first(where: { ["zsh", "bash", "fish", "sh", "dash", "nu"].contains($0) }) {
            return lineageClassification(
                category: .shellLaunchedProcess,
                value: shell,
                evidenceValue: "shell ancestor",
                controller: .guardedExternalProcess,
                reason: "A shell ancestor is observed. DevBerth can guard a process signal but does not claim a reliable restart recipe."
            )
        }
        if process.fingerprint.isStrong {
            return inferred(
                category: .standaloneHostProcess,
                value: process.name,
                confidence: .weaklyInferred,
                method: .processLineage,
                evidence: [
                    .init(field: "executable", value: process.executablePath ?? process.name, source: "process fingerprint", isVerified: true),
                    .init(field: "recognized controller", value: "None", source: "deterministic ownership rules", isVerified: false)
                ],
                controller: .guardedExternalProcess,
                actionTitle: "Use guarded process control",
                reason: "No higher-level controller was recognized. A restart action is not guaranteed."
            )
        }
        return inferred(
            category: .unknown,
            value: "Unknown controller",
            confidence: .unknown,
            method: .unknown,
            evidence: [
                .init(field: "metadata", value: "Incomplete process fingerprint", source: "process inspection", isVerified: false)
            ],
            controller: .unavailable,
            actionTitle: "Inspect before acting",
            reason: "DevBerth could not identify a controlling owner from a complete fingerprint. Process actions remain unavailable until the target can be revalidated."
        )
    }

    private static func lineageClassification(
        category: OwnershipCategory,
        value: String,
        evidenceValue: String,
        controller: LifecycleControllerKind,
        reason: String
    ) -> OwnershipClassification {
        inferred(
            category: category,
            value: value,
            confidence: .stronglyInferred,
            method: .processLineage,
            evidence: [
                .init(field: "lineage", value: evidenceValue, source: "parent process chain", isVerified: true)
            ],
            controller: controller,
            actionTitle: controller == .unavailable ? "Inspect the controlling owner" : "Use guarded process control",
            reason: reason
        )
    }

    private static func inferred(
        category: OwnershipCategory,
        value: String,
        confidence: EvidenceConfidence,
        method: OwnershipDetectionMethod,
        evidence: [OwnershipEvidenceItem],
        controller: LifecycleControllerKind,
        actionTitle: String,
        reason: String
    ) -> OwnershipClassification {
        OwnershipClassification(
            category: category,
            value: value,
            confidence: confidence,
            evidence: evidence,
            detectionMethod: method,
            recommendation: .init(controllerKind: controller, title: actionTitle, reason: reason)
                .withSupportedActions(supportedActions(for: controller))
        )
    }

    private static func signatureEvidence(_ value: String, source: String) -> [OwnershipEvidenceItem] {
        [.init(field: "command signature", value: value, source: source, isVerified: true)]
    }

    private static func containsAny(_ text: String, _ signatures: [String]) -> Bool {
        signatures.contains { text.contains($0) }
    }

    private static func hasSSHForwardingFlag(_ command: String) -> Bool {
        command.split(whereSeparator: \.isWhitespace).dropFirst().contains { token in
            let value = String(token)
            return value == "-L" || value == "-R" || value == "-D"
                || (value.count > 2 && (value.hasPrefix("-L") || value.hasPrefix("-R") || value.hasPrefix("-D")))
        }
    }

    private static func supportedActions(for controller: LifecycleControllerKind) -> Set<LifecycleActionKind> {
        switch controller {
        case .guardedExternalProcess, .kubernetesPortForward, .sshTunnel:
            [.inspect, .gracefulStop, .forceStop]
        case .dockerContainer:
            [.inspect, .gracefulStop, .restart, .remove]
        case .managedProcess:
            [.inspect, .gracefulStop]
        case .dockerComposeService, .homebrewService, .launchdService, .unavailable:
            [.inspect]
        }
    }

    private static func firstMatchingName(
        in lineage: [ProcessLineageNode],
        signatures: [String]
    ) -> String? {
        lineage.dropFirst().first { node in
            let value = "\(node.name) \(node.commandLine ?? "")".lowercased()
            return signatures.contains { value.contains($0) }
        }?.name
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension OwnershipActionRecommendation {
    func withSupportedActions(_ actions: Set<LifecycleActionKind>) -> OwnershipActionRecommendation {
        OwnershipActionRecommendation(
            controllerKind: controllerKind,
            title: title,
            reason: reason,
            supportedActions: actions
        )
    }
}
