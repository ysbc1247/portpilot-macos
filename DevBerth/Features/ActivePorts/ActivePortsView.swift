import AppKit
import SwiftData
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
    @Query private var profiles: [LaunchProfileRecord]
    @Query private var dependencies: [ProfileDependencyRecord]
    @Query private var expectedPorts: [ExpectedPortRecord]
    @Query private var processPolicies: [ManagedServiceProcessPolicyRecord]
    @Query private var validationRecords: [ManagedServiceValidationRecord]
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
                RestartTrustExplanationView(summary: restartTrustSummary)
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
                        if canConvertToManagedService {
                            Button("Convert to Managed Service") { showsProfileReview = true }
                        }
                        Spacer()
                        if canRestart {
                            Button("Restart") {
                                Task {
                                    await model.restartOwnedRuntime(
                                        listener,
                                        verifiedConfiguration: managedConfiguration
                                    )
                                }
                            }
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
        guard let graph = ownershipGraph,
              graph.recommendation.supportedActions.contains(.restart) else { return false }
        guard graph.recommendation.controllerKind == .managedProcess else { return true }
        guard let managedConfiguration else { return false }
        return restartTrustSummary.state == .verifiedRestartable
            && graph.managedConfigurationDigest == ManagedServiceConfigurationDigest.make(
                for: managedConfiguration
            )
    }

    private var canConvertToManagedService: Bool {
        listener.process.managedServiceID == nil && listener.process.docker == nil
    }

    private var restartTrustSummary: RestartTrustSummary {
        guard let managedConfiguration else {
            return RestartTrustEvaluator.observedSummary(for: listener)
        }
        let validation = validationRecords.first {
            $0.managedServiceID == managedConfiguration.id
        }?.result
        return RestartTrustEvaluator.summary(for: managedConfiguration, validation: validation)
    }

    private var managedConfiguration: ManagedServiceConfiguration? {
        guard let managedServiceID = listener.process.managedServiceID,
              let profile = profiles.first(where: { $0.id == managedServiceID }) else { return nil }
        return profile.configuration(
            dependencies: dependencies,
            expectedPorts: expectedPorts,
            processPolicies: processPolicies
        )
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

private struct RestartTrustExplanationView: View {
    let summary: RestartTrustSummary

    var body: some View {
        GroupBox("Can DevBerth restart this reliably?") {
            VStack(alignment: .leading, spacing: DevBerthSpacing.small) {
                Label(summary.state.title, systemImage: summary.state.symbol)
                    .font(.headline)
                    .foregroundStyle(color)
                ForEach(summary.reasons, id: \.self) { reason in
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let lastValidatedAt = summary.lastValidatedAt {
                    InspectorRow(title: "Last validated", value: lastValidatedAt.formatted())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Restart trust: \(summary.state.title)")
        }
    }

    private var color: Color {
        switch summary.state {
        case .verifiedRestartable: .green
        case .conditionallyRestartable: .orange
        case .inferredRestartCandidate: .blue
        case .notRestartable: .red
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
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let listener: ObservedListener
    private let profileID = UUID()
    private let expectedPortID = UUID()
    private let secretLifecycle = SecretLifecycleCoordinator()
    private let stepTitles = [
        "Command", "Directory & shell", "Environment", "Keychain",
        "Readiness", "Review", "Validate"
    ]

    @State private var step = 0
    @State private var name: String
    @State private var command: String
    @State private var argumentsText = ""
    @State private var workingDirectory: String
    @State private var usesLoginShell = false
    @State private var shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    @State private var environmentText = ""
    @State private var secretReplacements: [String: String] = [:]
    @State private var secretName = ""
    @State private var secretValue = ""
    @State private var expectedPort: String
    @State private var healthURL = ""
    @State private var expectedStatus = 200
    @State private var reviewed = false
    @State private var stopConfirmed = false
    @State private var isWorking = false
    @State private var errorMessage: String?

    init(listener: ObservedListener) {
        self.listener = listener
        _name = State(initialValue: listener.process.project?.name ?? listener.process.name)
        _command = State(initialValue: listener.process.executablePath ?? "")
        _workingDirectory = State(initialValue: listener.process.currentDirectory ?? "")
        _expectedPort = State(initialValue: String(listener.port))
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: DevBerthSpacing.small) {
                Text("Convert to Managed Service").font(.title2.bold())
                Text("Step \(step + 1) of \(stepTitles.count): \(stepTitles[step])")
                    .foregroundStyle(.secondary)
                ProgressView(value: Double(step + 1), total: Double(stepTitles.count))
                    .accessibilityLabel("Conversion progress")
                    .accessibilityValue("Step \(step + 1) of \(stepTitles.count)")
            }
            .padding()

            Divider()
            Form { stepContent }
                .formStyle(.grouped)

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }

            HStack {
                if isWorking { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                if step > 0 {
                    Button("Back") { step -= 1; errorMessage = nil }
                        .disabled(isWorking)
                }
                if step < stepTitles.count - 1 {
                    Button("Continue") { step += 1; errorMessage = nil }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canContinue || isWorking)
                } else {
                    Button("Stop, Test & Save Verified") {
                        Task { await validateAndSave() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!stopConfirmed || !reviewed || isWorking)
                }
            }
            .padding()
            .background(.bar)
        }
        .frame(width: 700, height: 680)
        .interactiveDismissDisabled(isWorking)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case 0:
            Section("Observed evidence") {
                Text(listener.process.commandLine)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Text("The operating system exposes a command string, not trustworthy original argument boundaries. DevBerth does not split it automatically.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Reviewed launch command") {
                TextField("Service name", text: $name)
                TextField("Executable path", text: $command)
                TextField("Exact arguments (one argument per line)", text: $argumentsText, axis: .vertical)
                    .lineLimit(4...9)
            }
        case 1:
            Section("Working directory") {
                TextField("Absolute directory", text: $workingDirectory)
                Text("Observed value: \(listener.process.currentDirectory ?? "Unavailable")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Shell behavior") {
                Toggle("Run through a login shell", isOn: $usesLoginShell)
                if usesLoginShell { TextField("Shell path", text: $shellPath) }
                Text("Direct execution is safer when the executable and arguments are known. Select a shell only when startup depends on shell initialization.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case 2:
            Section("Non-secret environment") {
                TextField("KEY=value, one per line", text: $environmentText, axis: .vertical)
                    .lineLimit(6...12)
                Text("The original environment cannot be recovered reliably. Secret-like names are rejected here and must be stored in Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case 3:
            Section("Keychain environment") {
                ForEach(secretReplacements.keys.sorted(), id: \.self) { name in
                    HStack {
                        Label(name, systemImage: "key.fill")
                        Spacer()
                        Text("Value staged in memory").font(.caption).foregroundStyle(.secondary)
                        Button("Remove", role: .destructive) { secretReplacements.removeValue(forKey: name) }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Variable name", text: $secretName)
                    SecureField("Value", text: $secretValue)
                    Button("Add") { addSecret() }
                        .disabled(secretName.isEmpty || secretValue.isEmpty)
                }
                Text("Values are never placed in SwiftData, logs, validation evidence, or this form after conversion closes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case 4:
            Section("Required listener") {
                Picker("Protocol", selection: .constant(listener.protocolKind)) {
                    Text(listener.protocolKind.rawValue).tag(listener.protocolKind)
                }
                .disabled(true)
                TextField("Port", text: $expectedPort)
                Text("A successful validation must observe this listener before the startup timeout.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Optional HTTP health check") {
                TextField("http://127.0.0.1:port/path", text: $healthURL)
                Stepper("Expected status: \(expectedStatus)", value: $expectedStatus, in: 100...599)
            }
        case 5:
            Section("Review inferred and reconstructed fields") {
                LabeledContent("Executable") { Text(command).font(.system(.caption, design: .monospaced)) }
                LabeledContent("Arguments") { Text("\(argumentCount) exact value(s)") }
                LabeledContent("Working directory") { Text(workingDirectory) }
                LabeledContent("Shell") { Text(usesLoginShell ? shellPath : "Direct execution") }
                LabeledContent("Non-secret fields") { Text("\(parsedEnvironment.values.count)") }
                LabeledContent("Keychain fields") { Text("\(secretReplacements.count)") }
                LabeledContent("Required listener") { Text("\(listener.protocolKind.rawValue) :\(expectedPort)") }
                Toggle("I reviewed every reconstructed field and its exact argument boundaries", isOn: $reviewed)
            }
        default:
            Section("Explicit stop approval") {
                Text("Port \(listener.port) is currently occupied by PID \(listener.process.fingerprint.pid). DevBerth must re-resolve its controlling owner and stop it before testing the managed definition on the same port.")
                    .font(.callout)
                Toggle("Stop the revalidated observed owner before the test", isOn: $stopConfirmed)
                Label("No profile or secret reference is saved unless the candidate starts, becomes ready, and stops cleanly.", systemImage: "checkmark.shield")
                    .font(.caption).foregroundStyle(.secondary)
                Text("If candidate startup fails after the approved stop, the original process remains stopped and DevBerth reports the failure; it will not guess how to recreate it.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var canContinue: Bool {
        switch step {
        case 0:
            return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case 1:
            return !workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && (!usesLoginShell || !shellPath.isEmpty)
        case 2:
            return parsedEnvironment.isValid
        case 4:
            return UInt16(expectedPort) != nil && validHealthURL
        case 5:
            return reviewed
        default:
            return true
        }
    }

    private var argumentCount: Int {
        argumentsText.split(whereSeparator: \.isNewline).count
    }

    private var parsedEnvironment: ManagedEnvironmentParseResult {
        ManagedEnvironmentParser.parse(environmentText)
    }

    private var validHealthURL: Bool {
        let trimmed = healthURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        guard let url = URL(string: trimmed) else { return false }
        return ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }

    private func addSecret() {
        let normalized = secretName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ManagedEnvironmentParser.isValidVariableName(normalized) else {
            errorMessage = "Enter a valid environment variable name."
            return
        }
        secretReplacements[normalized] = secretValue
        secretName = ""
        secretValue = ""
        errorMessage = nil
    }

    @MainActor
    private func validateAndSave() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        let staged: StagedSecretMutation
        do {
            staged = try await secretLifecycle.stage(
                existingReferences: [:],
                retainedNames: Set(secretReplacements.keys),
                replacements: secretReplacements
            )
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        let candidate: ManagedServiceConfiguration
        do {
            candidate = try makeConfiguration(references: staged.references)
            let issues = ManagedServiceValidator.validate(candidate).filter { $0.severity == .error }
            guard issues.isEmpty else {
                throw DevBerthError.launchValidation(issues.map(\.message).joined(separator: " "))
            }
        } catch {
            await secretLifecycle.rollback(staged)
            errorMessage = error.localizedDescription
            return
        }

        do {
            try await model.stopObservedProcessForValidation(listener)
        } catch {
            await secretLifecycle.rollback(staged)
            errorMessage = "The observed owner was not stopped, so validation did not run: \(error.localizedDescription)"
            return
        }

        let validation = await model.validateManagedService(candidate)
        guard validation.succeeded else {
            await secretLifecycle.rollback(staged)
            errorMessage = "The observed process was stopped, but the managed candidate failed validation: \(validation.summary)"
            return
        }

        do {
            try persist(candidate)
        } catch {
            context.rollback()
            await secretLifecycle.rollback(staged)
            errorMessage = "The candidate validated and stopped, but its definition was not saved: \(error.localizedDescription)"
            return
        }
        do {
            try await model.recordRestartTrust(for: candidate, validation: validation)
            dismiss()
        } catch {
            errorMessage = "The profile and Keychain references were saved, but validation metadata could not be recorded: \(error.localizedDescription)"
        }
    }

    private func makeConfiguration(references: [String: UUID]) throws -> ManagedServiceConfiguration {
        let environment = parsedEnvironment
        if !environment.sensitiveNames.isEmpty {
            throw DevBerthError.launchValidation(
                "Move secret-like fields to Keychain: \(environment.sensitiveNames.joined(separator: ", "))."
            )
        }
        if !environment.duplicateNames.isEmpty {
            throw DevBerthError.launchValidation(
                "Environment fields must be unique: \(environment.duplicateNames.joined(separator: ", "))."
            )
        }
        guard environment.invalidLines.isEmpty else {
            throw DevBerthError.launchValidation(
                "\(environment.invalidLines.count) environment line(s) do not use a valid KEY=value form."
            )
        }
        guard let port = UInt16(expectedPort) else {
            throw DevBerthError.launchValidation("Enter a valid expected port.")
        }
        let trimmedHealthURL = healthURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let healthCheck: HealthCheckConfiguration?
        if trimmedHealthURL.isEmpty {
            healthCheck = nil
        } else {
            guard validHealthURL, let url = URL(string: trimmedHealthURL) else {
                throw DevBerthError.launchValidation("The health-check URL must be an HTTP or HTTPS URL.")
            }
            healthCheck = .init(url: url, expectedStatus: expectedStatus, intervalSeconds: 0.5)
        }
        return ManagedServiceConfiguration(
            id: profileID,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            launchMechanism: .executable,
            command: command.trimmingCharacters(in: .whitespacesAndNewlines),
            arguments: argumentsText.split(whereSeparator: \.isNewline).map(String.init),
            workingDirectory: workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines),
            shell: usesLoginShell ? .loginShell(path: shellPath) : .direct,
            environment: environment.values,
            secretReferences: references,
            expectedPorts: [.init(
                id: expectedPortID,
                port: port,
                protocolKind: listener.protocolKind,
                required: true
            )],
            processPolicy: .controlledProcessGroup,
            healthCheck: healthCheck,
            isReviewed: reviewed
        )
    }

    @MainActor
    private func persist(_ candidate: ManagedServiceConfiguration) throws {
        let encoder = JSONEncoder()
        let profile = LaunchProfileRecord(
            id: candidate.id,
            name: candidate.name,
            command: candidate.command,
            workingDirectory: candidate.workingDirectory
        )
        profile.projectID = candidate.projectID
        profile.kindRawValue = candidate.launchMechanism.rawValue
        profile.argumentsData = try encoder.encode(candidate.arguments)
        profile.shellData = try encoder.encode(candidate.shell)
        profile.environmentData = try encoder.encode(candidate.environment)
        profile.secretReferencesData = try encoder.encode(candidate.secretReferences)
        profile.healthCheckData = try candidate.healthCheck.map(encoder.encode)
        profile.isReviewed = candidate.isReviewed
        profile.launchesAutomatically = false
        context.insert(profile)
        for expected in candidate.expectedPorts {
            context.insert(ExpectedPortRecord(
                id: expected.id,
                profileID: profile.id,
                port: expected.port,
                protocolKind: expected.protocolKind,
                required: expected.required
            ))
        }
        context.insert(ManagedServiceProcessPolicyRecord(
            managedServiceID: profile.id,
            policy: candidate.processPolicy
        ))
        try context.save()
    }
}
