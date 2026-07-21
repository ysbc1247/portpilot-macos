import AppKit
import SwiftUI

struct ActivePortsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection = Set<String>()
    @State private var protocolFilter: ListenerProtocol?
    @State private var sort = SortChoice.port
    @SceneStorage("activePorts.columnCustomization") private var columnCustomization: TableColumnCustomization<ObservedListener>

    private enum SortChoice: String, CaseIterable { case port = "Port", process = "Process", project = "Project", runtime = "Runtime", uptime = "Uptime" }

    private var displayedListeners: [ObservedListener] {
        model.filteredListeners
            .filter { protocolFilter == nil || $0.protocolKind == protocolFilter }
            .sorted { lhs, rhs in
                switch sort {
                case .port: lhs.port < rhs.port
                case .process: lhs.process.name.localizedCaseInsensitiveCompare(rhs.process.name) == .orderedAscending
                case .project: (lhs.process.project?.name ?? "~").localizedCaseInsensitiveCompare(rhs.process.project?.name ?? "~") == .orderedAscending
                case .runtime: lhs.process.runtime.rawValue < rhs.process.runtime.rawValue
                case .uptime: (lhs.process.fingerprint.startTime ?? .distantFuture) < (rhs.process.fingerprint.startTime ?? .distantFuture)
                }
            }
    }

    var body: some View {
        HSplitView {
            Group {
                if displayedListeners.isEmpty && !model.isRefreshing {
                    EmptyStateView(
                        symbol: model.searchText.isEmpty ? "network.slash" : "magnifyingglass",
                        title: model.searchText.isEmpty ? "No active listeners" : "No matching listeners",
                        message: model.searchText.isEmpty
                            ? "DevBerth did not find any TCP or UDP listeners."
                            : "Try a different port, process, command, or project name.",
                        actionTitle: "Refresh",
                        action: model.refreshNow
                    )
                } else {
                    Table(displayedListeners, selection: $selection, columnCustomization: $columnCustomization) {
                        activePortColumns
                    }
                    .contextMenu(forSelectionType: String.self) { ids in
                        if let listener = model.listeners.first(where: { ids.contains($0.id) }) {
                            Button("Copy Port") { copy(String(listener.port)) }
                            Button("Copy PID") { copy(String(listener.process.fingerprint.pid)) }
                            Button("Copy Command") { copy(listener.process.commandLine) }
                            Divider()
                            if let path = listener.process.currentDirectory {
                                Button("Open Working Directory") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                            }
                        }
                    } primaryAction: { ids in
                        model.selectedListenerID = ids.first
                    }
                    .overlay {
                        if model.isRefreshing { ProgressView().controlSize(.small) }
                    }
                }
            }
            .frame(minWidth: 650)

            if let listener = model.selectedListener {
                ProcessInspectorView(listener: listener)
                    .frame(minWidth: 280, idealWidth: 340, maxWidth: 420)
            }
        }
        .navigationTitle("Active Ports")
        .toolbar {
            Picker("Protocol", selection: $protocolFilter) {
                Text("TCP & UDP").tag(nil as ListenerProtocol?)
                ForEach(ListenerProtocol.allCases, id: \.self) { Text($0.rawValue).tag($0 as ListenerProtocol?) }
            }
            Picker("Sort", selection: $sort) {
                ForEach(SortChoice.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
        }
        .onChange(of: selection) { _, newValue in model.selectedListenerID = newValue.first }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    @TableColumnBuilder<ObservedListener, Never>
    private var activePortColumns: some TableColumnContent<ObservedListener, Never> {
        TableColumn("Status") { (listener: ObservedListener) in
            HStack(spacing: 6) {
                StatusDot(status: listener.process.isSystemProcess ? .warning : .healthy)
                Text(listener.protocolKind.rawValue).font(.caption).foregroundStyle(.secondary)
            }
        }
        .width(min: 70, ideal: 82, max: 95)
        .customizationID("status")
        TableColumn("Port") { (listener: ObservedListener) in PortBadge(port: listener.port) }
            .width(min: 72, ideal: 82, max: 100)
            .customizationID("port")
        TableColumn("Process") { (listener: ObservedListener) in
            Label(listener.process.name, systemImage: listener.process.runtime.symbolName).lineLimit(1)
        }
        .width(min: 130, ideal: 180)
        .customizationID("process")
        TableColumn("Project") { (listener: ObservedListener) in
            Text(listener.process.project?.name ?? "—")
                .foregroundStyle(listener.process.project == nil ? .secondary : .primary)
        }
        .width(min: 100, ideal: 150)
        .customizationID("project")
        TableColumn("PID") { (listener: ObservedListener) in
            Text(listener.process.fingerprint.pid, format: .number.grouping(.never)).monospacedDigit()
        }
        .width(min: 55, ideal: 65, max: 90)
        .customizationID("pid")
        TableColumn("Address") { (listener: ObservedListener) in
            Text(listener.address).font(.system(.body, design: .monospaced)).lineLimit(1)
        }
        .width(min: 95, ideal: 130)
        .customizationID("address")
        TableColumn("Runtime") { (listener: ObservedListener) in Text(listener.process.runtime.rawValue) }
            .width(min: 90, ideal: 120)
            .customizationID("runtime")
        TableColumn("Uptime") { (listener: ObservedListener) in
            Text(listener.process.fingerprint.startTime.map { $0.formatted(.relative(presentation: .numeric)) } ?? "Unknown")
                .foregroundStyle(.secondary)
        }
        .width(min: 90, ideal: 105)
        .customizationID("uptime")
    }
}

private struct ProcessInspectorView: View {
    @EnvironmentObject private var model: AppModel
    let listener: ObservedListener
    @State private var showsForceConfirmation = false
    @State private var showsProfileReview = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DevBerthSpacing.large) {
                HStack {
                    Image(systemName: listener.process.runtime.symbolName)
                        .font(.largeTitle)
                        .frame(width: 46, height: 46)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading) {
                        Text(listener.process.name).font(.title3.bold())
                        Text(listener.process.runtime.rawValue).foregroundStyle(.secondary)
                    }
                }

                GroupBox("Listener") {
                    VStack(spacing: 10) {
                        InspectorRow(title: "Port", value: String(listener.port))
                        InspectorRow(title: "Protocol", value: listener.protocolKind.rawValue)
                        InspectorRow(title: "Address", value: listener.address)
                        InspectorRow(title: "Scope", value: listener.addressScope.rawValue)
                    }
                }
                GroupBox("Process fingerprint") {
                    VStack(spacing: 10) {
                        InspectorRow(title: "PID", value: String(listener.process.fingerprint.pid))
                        InspectorRow(title: "Owner", value: listener.process.owner)
                        InspectorRow(
                            title: "User ID",
                            value: listener.process.fingerprint.uid.map(String.init) ?? "Unavailable"
                        )
                        InspectorRow(title: "Executable", value: listener.process.executablePath ?? "Unavailable")
                        if let fileIdentity = listener.process.fingerprint.executableFileIdentity {
                            InspectorRow(
                                title: "Executable file",
                                value: "device \(fileIdentity.deviceID), inode \(fileIdentity.inode)"
                            )
                        }
                        InspectorRow(title: "Started", value: listener.process.fingerprint.startTime?.formatted() ?? "Unavailable")
                        InspectorRow(
                            title: "Parent PID",
                            value: listener.process.fingerprint.parentPID.map(String.init) ?? "Unavailable"
                        )
                        InspectorRow(
                            title: "Command digest",
                            value: listener.process.fingerprint.commandLineDigest.map { String($0.prefix(16)) } ?? "Unavailable"
                        )
                        InspectorRow(title: "Detected", value: listener.process.fingerprint.detectedAt.formatted())
                    }
                }
                GroupBox("Observed command") {
                    Text(listener.process.commandLine)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                OwnershipExplanationView(
                    graph: model.ownershipGraphs[listener.id],
                    isLoading: model.ownershipInspectionsInProgress.contains(listener.id)
                )
                if let project = listener.process.project {
                    GroupBox("Inferred project") {
                        VStack(spacing: 10) {
                            InspectorRow(title: "Name", value: project.name)
                            InspectorRow(title: "Root", value: project.rootPath)
                            InspectorRow(title: "Evidence", value: project.evidence)
                        }
                    }
                }
                if let docker = listener.process.docker {
                    GroupBox("Docker association") {
                        VStack(spacing: 10) {
                            InspectorRow(title: "Container", value: docker.containerName)
                            InspectorRow(title: "Container ID", value: docker.containerID)
                            InspectorRow(title: "Image", value: docker.image)
                            InspectorRow(title: "Container port", value: docker.containerPort.map(String.init) ?? "Unavailable")
                            if let service = docker.composeService { InspectorRow(title: "Compose service", value: service) }
                        }
                    }
                }
                if listener.process.isSystemProcess {
                    Label("This process receives additional termination protection.", systemImage: "lock.shield")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
                VStack(spacing: DevBerthSpacing.small) {
                    Button {
                        Task { await model.terminate(listener, mode: .graceful(timeoutSeconds: 5)) }
                    } label: {
                        Label(gracefulStopTitle, systemImage: "stop.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(!canGracefullyStop || model.processesBeingControlled.contains(listener.process.fingerprint.pid))

                    HStack {
                        Button("Save as Launch Profile") { showsProfileReview = true }
                        Spacer()
                        if canRestart {
                            Button("Restart") { Task { await model.restartOwnedRuntime(listener) } }
                        }
                        Button("Force Stop", role: .destructive) { showsForceConfirmation = true }
                            .disabled(!canForceStop || model.processesBeingControlled.contains(listener.process.fingerprint.pid))
                    }
                }
            }
            .padding(DevBerthSpacing.large)
        }
        .background(.background)
        .confirmationDialog(
            "Force stop \(listener.process.name)?",
            isPresented: $showsForceConfirmation,
            titleVisibility: .visible
        ) {
            Button("Force Stop", role: .destructive) {
                Task { await model.terminate(listener, mode: .force(confirmed: true)) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("DevBerth will send SIGKILL to PID \(listener.process.fingerprint.pid). Unsaved process state may be lost. The full process fingerprint and listener ownership will be verified again immediately before signaling.")
        }
        .sheet(isPresented: $showsProfileReview) {
            DiscoveredProfileReviewView(listener: listener)
        }
        .task(id: ownershipInspectionKey) {
            await model.inspectOwnership(of: listener)
        }
    }

    private var ownershipInspectionKey: String {
        [
            listener.id,
            listener.process.fingerprint.commandLineDigest ?? "weak",
            listener.process.docker?.containerID ?? "host"
        ].joined(separator: ":")
    }

    private var ownershipGraph: RuntimeOwnershipGraph? {
        model.ownershipGraphs[listener.id]
    }

    private var canGracefullyStop: Bool {
        guard let graph = ownershipGraph else { return false }
        if usesPIDController(graph.recommendation.controllerKind) && listener.process.isSystemProcess {
            return false
        }
        return graph.recommendation.supportedActions.contains(.gracefulStop)
    }

    private var canForceStop: Bool {
        guard let graph = ownershipGraph else { return false }
        if listener.process.isSystemProcess { return false }
        return graph.recommendation.supportedActions.contains(.forceStop)
    }

    private var canRestart: Bool {
        ownershipGraph?.recommendation.supportedActions.contains(.restart) == true
    }

    private func usesPIDController(_ controller: LifecycleControllerKind) -> Bool {
        switch controller {
        case .guardedExternalProcess, .kubernetesPortForward, .sshTunnel:
            true
        case .managedProcess, .dockerContainer, .dockerComposeService, .homebrewService,
             .launchdService, .unavailable:
            false
        }
    }

    private var gracefulStopTitle: String {
        switch ownershipGraph?.recommendation.controllerKind {
        case .managedProcess: "Stop Managed Service"
        case .dockerContainer: "Stop Container"
        case .kubernetesPortForward: "Stop Port Forward"
        case .sshTunnel: "Stop SSH Tunnel"
        default: "Graceful Stop"
        }
    }
}

private struct OwnershipExplanationView: View {
    let graph: RuntimeOwnershipGraph?
    let isLoading: Bool

    var body: some View {
        GroupBox("Why is this running?") {
            if let graph {
                VStack(alignment: .leading, spacing: DevBerthSpacing.medium) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(graph.primaryConclusion.category.title).font(.headline)
                            Text(graph.primaryConclusion.value).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(graph.primaryConclusion.confidence.title)
                            .font(.caption.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.quaternary, in: Capsule())
                    }
                    InspectorRow(
                        title: "Detection method",
                        value: graph.primaryConclusion.detectionMethod.title
                    )
                    InspectorRow(
                        title: "Process group",
                        value: graph.processGroupID.map(String.init) ?? "Unavailable"
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        Text(graph.recommendation.title).font(.subheadline.bold())
                        Text(graph.recommendation.reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !graph.processLineage.isEmpty {
                        Divider()
                        Text("Process lineage").font(.caption.bold()).foregroundStyle(.secondary)
                        ForEach(Array(graph.processLineage.enumerated()), id: \.element.id) { index, node in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: index == 0 ? "circle.fill" : "arrow.turn.up.right")
                                    .font(.caption2)
                                    .foregroundStyle(index == 0 ? .primary : .secondary)
                                    .frame(width: 12)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("\(node.name) · PID \(node.fingerprint.pid)")
                                        .font(.system(.caption, design: .monospaced))
                                    if let command = node.commandLine {
                                        Text(command)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                            }
                        }
                    }

                    if !graph.primaryConclusion.evidence.isEmpty {
                        Divider()
                        Text("Supporting evidence").font(.caption.bold()).foregroundStyle(.secondary)
                        ForEach(graph.primaryConclusion.evidence) { evidence in
                            VStack(alignment: .leading, spacing: 1) {
                                HStack {
                                    Image(systemName: evidence.isVerified ? "checkmark.seal.fill" : "questionmark.diamond")
                                        .foregroundStyle(evidence.isVerified ? .green : .secondary)
                                    Text(evidence.field.capitalized).font(.caption.bold())
                                    Spacer()
                                    Text(evidence.isVerified ? "Observed" : "Inferred")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Text(evidence.value).font(.caption)
                                Text(evidence.source).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if isLoading {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Resolving process lineage and controlling owner…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Ownership evidence has not been inspected yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct DiscoveredProfileReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let listener: ObservedListener
    @State private var name: String
    @State private var command: String
    @State private var argumentsText: String
    @State private var workingDirectory: String
    @State private var reviewed = false

    init(listener: ObservedListener) {
        self.listener = listener
        _name = State(initialValue: listener.process.project?.name ?? listener.process.name)
        _command = State(initialValue: listener.process.executablePath ?? listener.process.name)
        let tokens = listener.process.commandLine.split(separator: " ").dropFirst().map(String.init)
        _argumentsText = State(initialValue: tokens.joined(separator: "\n"))
        _workingDirectory = State(initialValue: listener.process.currentDirectory ?? NSHomeDirectory())
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Verified and inferred values") {
                    TextField("Profile name", text: $name)
                    TextField("Executable", text: $command)
                    TextField("Working directory", text: $workingDirectory)
                    TextField("Arguments (one per line)", text: $argumentsText, axis: .vertical)
                        .lineLimit(3...8)
                    LabeledContent("Expected port") { Text("\(listener.protocolKind.rawValue) \(listener.port)") }
                }
                Section("Review required") {
                    Text("The operating system does not expose the original shell state or complete environment. Arguments above are a best-effort split of process output; correct quoting and add required environment values before relying on this profile.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Toggle("I reviewed the executable, arguments, directory, and expected port", isOn: $reviewed)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save Profile") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!reviewed || name.isEmpty || command.isEmpty || workingDirectory.isEmpty)
            }
            .padding().background(.bar)
        }
        .frame(width: 640, height: 560)
    }

    private func save() {
        let profile = LaunchProfileRecord(name: name, command: command, workingDirectory: workingDirectory)
        profile.kindRawValue = LaunchMechanism.executable.rawValue
        profile.isReviewed = reviewed
        let arguments = argumentsText.split(whereSeparator: \.isNewline).map(String.init)
        profile.argumentsData = (try? JSONEncoder().encode(arguments)) ?? Data("[]".utf8)
        context.insert(profile)
        context.insert(ExpectedPortRecord(
            profileID: profile.id,
            port: listener.port,
            protocolKind: listener.protocolKind
        ))
        try? context.save()
        dismiss()
    }
}
