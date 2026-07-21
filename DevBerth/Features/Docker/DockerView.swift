import SwiftUI

@MainActor
final class DockerViewModel: ObservableObject {
    @Published private(set) var availability: DockerAvailability = .checking
    @Published private(set) var containers: [DockerContainer] = []
    @Published private(set) var isLoadingContainers = false
    @Published var error: DevBerthError?
    @Published var logs = ""
    @Published var logsContainerName = ""
    private let client: any DockerServing
    private let lifecycleRecorder: (any RuntimeLifecycleRecording)?

    init(client: any DockerServing, lifecycleRecorder: (any RuntimeLifecycleRecording)? = nil) {
        self.client = client
        self.lifecycleRecorder = lifecycleRecorder
    }

    func refresh() async {
        availability = await client.availability()
        guard case .available = availability else { containers = []; return }
        isLoadingContainers = true
        defer { isLoadingContainers = false }
        do {
            containers = try await client.runningContainers()
        } catch {
            handle(error)
        }
    }

    func perform(_ action: DockerMutationAction, on container: DockerContainer) async {
        let startedAt = Date()
        do {
            if let context = container.composeContext {
                switch action {
                case .stop: try await client.stopComposeService(context: context)
                case .restart: try await client.restartComposeService(context: context)
                case .remove: try await client.removeComposeService(context: context)
                }
            } else {
                switch action {
                case .stop: try await client.stop(containerID: container.id)
                case .restart: try await client.restart(containerID: container.id)
                case .remove: try await client.remove(containerID: container.id)
                }
            }
            await record(action: action, container: container, startedAt: startedAt)
            await refresh()
        } catch {
            await recordRefusal(action: action, container: container, error: error, startedAt: startedAt)
            handle(error)
        }
    }

    func openLogs(_ container: DockerContainer) async {
        do {
            logs = try await client.recentLogs(containerID: container.id, lines: 300)
            logsContainerName = container.name
        } catch {
            handle(error)
        }
    }

    private func record(
        action: DockerMutationAction,
        container: DockerContainer,
        startedAt: Date
    ) async {
        guard let lifecycleRecorder else { return }
        let category: LifecycleEventCategory
        if container.composeContext != nil {
            category = .dockerComposeChanged
        } else {
            category = action == .restart ? .dockerContainerStarted : .dockerContainerStopped
        }
        try? await lifecycleRecorder.record(LifecycleEvent(
            category: category,
            outcome: .succeeded,
            source: .docker,
            trigger: .userAction,
            summary: "Docker \(action.pastTense) \(container.actionTargetDescription).",
            details: container.lifecycleDetails,
            durationSeconds: Date().timeIntervalSince(startedAt)
        ))
    }

    private func recordRefusal(
        action: DockerMutationAction,
        container: DockerContainer,
        error: Error,
        startedAt: Date
    ) async {
        guard let lifecycleRecorder else { return }
        try? await lifecycleRecorder.record(LifecycleEvent(
            category: .safetyRefusal,
            outcome: .failed,
            severity: .warning,
            source: .docker,
            trigger: .userAction,
            summary: "Docker refused to \(action.rawValue) \(container.actionTargetDescription).",
            details: container.lifecycleDetails.merging(["error": error.localizedDescription]) { _, new in new },
            durationSeconds: Date().timeIntervalSince(startedAt)
        ))
    }

    private func handle(_ error: Error) {
        if let value = error as? DevBerthError {
            self.error = value
        } else {
            self.error = .unexpected(error.localizedDescription)
        }
    }
}

enum DockerMutationAction: String, Identifiable {
    case stop
    case restart
    case remove

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var pastTense: String {
        switch self {
        case .stop: "stopped"
        case .restart: "restarted"
        case .remove: "removed"
        }
    }
}

private struct PendingDockerMutation: Identifiable {
    let action: DockerMutationAction
    let container: DockerContainer
    var id: String { "\(action.rawValue):\(container.id)" }
}

struct DockerView: View {
    @StateObject private var model: DockerViewModel
    @State private var selectedContainerID: String?
    @State private var pendingMutation: PendingDockerMutation?

    init(
        client: any DockerServing = DockerCLIClient(runner: FoundationCommandRunner()),
        lifecycleRecorder: (any RuntimeLifecycleRecording)? = nil
    ) {
        _model = StateObject(wrappedValue: DockerViewModel(
            client: client,
            lifecycleRecorder: lifecycleRecorder
        ))
    }

    var body: some View {
        Group {
            switch model.availability {
            case .checking:
                ProgressView("Checking Docker…")
            case .notInstalled:
                EmptyStateView(
                    symbol: "shippingbox",
                    title: "Docker is not installed",
                    message: "Port monitoring remains available. Install a Docker-compatible runtime to enable exact container controls.",
                    actionTitle: "Check Again",
                    action: { Task { await model.refresh() } }
                )
            case let .daemonUnavailable(details):
                EmptyStateView(
                    symbol: "shippingbox.and.arrow.backward",
                    title: "Docker daemon is unavailable",
                    message: LocalizedStringKey(details),
                    actionTitle: "Retry",
                    action: { Task { await model.refresh() } }
                )
            case let .available(version):
                if model.isLoadingContainers && model.containers.isEmpty {
                    ProgressView("Inspecting running containers…")
                } else if model.containers.isEmpty {
                    EmptyStateView(
                        symbol: "shippingbox",
                        title: "No running containers",
                        message: "Docker \(version) is available. Published ports will appear here when containers are running.",
                        actionTitle: "Refresh",
                        action: { Task { await model.refresh() } }
                    )
                } else {
                    containerBrowser(version: version)
                }
            }
        }
        .navigationTitle("Docker")
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
        }
        .task {
            await model.refresh()
            ensureSelection(model.containers.map(\.id))
        }
        .onChange(of: model.containers.map(\.id)) { _, identifiers in
            ensureSelection(identifiers)
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(
                get: { pendingMutation != nil },
                set: { if !$0 { pendingMutation = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pendingMutation {
                Button(
                    confirmationButtonTitle(pendingMutation),
                    role: pendingMutation.action == .restart ? nil : .destructive
                ) {
                    Task { await model.perform(pendingMutation.action, on: pendingMutation.container) }
                    self.pendingMutation = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingMutation = nil }
        } message: {
            Text(confirmationMessage)
        }
        .sheet(isPresented: Binding(
            get: { !model.logsContainerName.isEmpty },
            set: { if !$0 { model.logsContainerName = "" } }
        )) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Recent logs — \(model.logsContainerName)").font(.headline).padding()
                Divider()
                ScrollView([.horizontal, .vertical]) {
                    Text(model.logs)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding()
                }
            }
            .frame(width: 760, height: 480)
        }
        .alert(item: $model.error) { value in
            Alert(
                title: Text("Docker action failed"),
                message: Text([value.errorDescription, value.recoverySuggestion].compactMap { $0 }.joined(separator: "\n\n"))
            )
        }
    }

    private func containerBrowser(version: String) -> some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Label("Running containers", systemImage: "shippingbox.fill")
                            .font(.headline)
                        Spacer()
                        if model.isLoadingContainers {
                            ProgressView().controlSize(.small)
                        }
                        Text("\(model.containers.count)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .padding()
                    Divider()
                    List(model.containers, selection: $selectedContainerID) { container in
                        DockerContainerRow(container: container)
                            .tag(container.id)
                    }
                }
                .frame(width: min(max(geometry.size.width * 0.36, 300), 420))

                Divider()

                if let container = selectedContainer {
                    DockerContainerInspector(
                        container: container,
                        requestMutation: { action in pendingMutation = .init(action: action, container: container) },
                        openLogs: { Task { await model.openLogs(container) } }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("Select a container", systemImage: "shippingbox")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("Docker Engine \(version)")
                Spacer()
                Text("Compose actions require verified files, hash, and exact membership")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    private var selectedContainer: DockerContainer? {
        model.containers.first { $0.id == selectedContainerID }
    }

    private func ensureSelection(_ identifiers: [String]) {
        if selectedContainerID == nil || !identifiers.contains(selectedContainerID ?? "") {
            selectedContainerID = identifiers.first
        }
    }

    private var confirmationTitle: String {
        guard let pendingMutation else { return "Confirm Docker action" }
        return "\(pendingMutation.action.title) \(pendingMutation.container.actionTargetDescription)?"
    }

    private var confirmationMessage: String {
        guard let pendingMutation else { return "" }
        switch pendingMutation.action {
        case .stop:
            return "Docker will gracefully stop only the selected \(pendingMutation.container.scopeNoun)."
        case .restart:
            return "Docker will restart only the selected \(pendingMutation.container.scopeNoun). Compose dependencies will not be restarted."
        case .remove:
            return "Docker will stop and permanently remove the selected \(pendingMutation.container.scopeNoun). This cannot be undone."
        }
    }

    private func confirmationButtonTitle(_ pending: PendingDockerMutation) -> String {
        "\(pending.action.title) \(pending.container.scopeNoun.capitalized)"
    }
}

private struct DockerContainerRow: View {
    let container: DockerContainer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(container.name).font(.headline)
                Spacer()
                StatusDot(status: container.healthStatus == "unhealthy" ? .failed : .healthy)
            }
            Text(container.image)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 8) {
                Text(container.state.capitalized)
                if let context = container.composeContext {
                    Label("\(context.projectName)/\(context.serviceName)", systemImage: "checkmark.shield")
                        .foregroundStyle(.green)
                } else if container.composeProject != nil {
                    Label("Compose inspect-only", systemImage: "exclamationmark.shield")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption2)
        }
        .padding(.vertical, 4)
    }
}

private struct DockerContainerInspector: View {
    let container: DockerContainer
    let requestMutation: (DockerMutationAction) -> Void
    let openLogs: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DevBerthSpacing.large) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(container.name).font(.title2.bold())
                        Text(container.image).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    Label(container.state.capitalized, systemImage: "circle.fill")
                        .foregroundStyle(container.healthStatus == "unhealthy" ? .red : .green)
                }

                HStack {
                    Button("Logs", systemImage: "doc.plaintext", action: openLogs)
                    Button("Restart", systemImage: "arrow.clockwise") { requestMutation(.restart) }
                        .disabled(hasUnverifiedComposeContext)
                    Button("Stop", systemImage: "stop.fill", role: .destructive) { requestMutation(.stop) }
                        .disabled(hasUnverifiedComposeContext)
                    Button("Remove", systemImage: "trash", role: .destructive) { requestMutation(.remove) }
                        .disabled(hasUnverifiedComposeContext)
                }

                GroupBox("Container") {
                    VStack(spacing: 10) {
                        InspectorRow(title: "ID", value: container.id)
                        InspectorRow(title: "State", value: container.state)
                        InspectorRow(title: "Health", value: container.healthStatus ?? "No health check")
                        InspectorRow(title: "Restart policy", value: container.restartPolicy)
                    }
                }

                GroupBox("Published ports") {
                    if container.ports.isEmpty {
                        Text("No host ports are published.").foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 10) {
                            ForEach(container.ports) { port in
                                InspectorRow(
                                    title: "\(port.protocolKind.rawValue) container :\(port.containerPort)",
                                    value: "\(port.hostAddress):\(port.hostPort)"
                                )
                            }
                        }
                    }
                }

                if container.composeProject != nil || container.composeService != nil {
                    composeInspector
                }
            }
            .padding(DevBerthSpacing.large)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 440, idealWidth: 620)
    }

    @ViewBuilder
    private var composeInspector: some View {
        GroupBox("Docker Compose") {
            VStack(alignment: .leading, spacing: 10) {
                InspectorRow(title: "Project", value: container.composeProject ?? "Unavailable")
                InspectorRow(title: "Service", value: container.composeService ?? "Unavailable")
                if let context = container.composeContext {
                    Label("Exact action scope verified", systemImage: "checkmark.shield.fill")
                        .foregroundStyle(.green)
                    InspectorRow(title: "Working directory", value: context.workingDirectory.path)
                    InspectorRow(title: "Configuration files", value: context.configurationFilePaths.joined(separator: "\n"))
                    InspectorRow(
                        title: "Environment files",
                        value: context.environmentFilePaths.isEmpty ? "None" : context.environmentFilePaths.joined(separator: "\n")
                    )
                    InspectorRow(title: "Configuration hash", value: context.configurationHash)
                    InspectorRow(title: "Verified", value: context.verifiedAt.formatted(date: .abbreviated, time: .standard))
                } else {
                    Label("Inspection only", systemImage: "exclamationmark.shield.fill")
                        .foregroundStyle(.orange)
                    Text(container.composeContextIssue ?? "The exact Compose action scope could not be verified.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var hasUnverifiedComposeContext: Bool {
        (container.composeProject != nil || container.composeService != nil) && container.composeContext == nil
    }
}

private extension DockerContainer {
    var scopeNoun: String { composeContext == nil ? "container" : "Compose service" }
    var actionTargetDescription: String {
        if let composeContext {
            return "Compose service \(composeContext.projectName)/\(composeContext.serviceName)"
        }
        return "container \(name)"
    }
    var lifecycleDetails: [String: String] {
        [
            "containerID": id,
            "containerName": name,
            "image": image,
            "composeProject": composeProject ?? "",
            "composeService": composeService ?? ""
        ]
    }
}
