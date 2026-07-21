import AppKit
import SwiftUI

struct ActivePortsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection = Set<String>()
    @State private var protocolFilter: ListenerProtocol?
    @State private var sort = SortChoice.port
    @SceneStorage("activePorts.columnCustomization") private var columnCustomization: TableColumnCustomization<NetworkListener>

    private enum SortChoice: String, CaseIterable { case port = "Port", process = "Process", project = "Project", runtime = "Runtime", uptime = "Uptime" }

    private var displayedListeners: [NetworkListener] {
        model.filteredListeners
            .filter { protocolFilter == nil || $0.protocolKind == protocolFilter }
            .sorted { lhs, rhs in
                switch sort {
                case .port: lhs.port < rhs.port
                case .process: lhs.process.name.localizedCaseInsensitiveCompare(rhs.process.name) == .orderedAscending
                case .project: (lhs.process.project?.name ?? "~").localizedCaseInsensitiveCompare(rhs.process.project?.name ?? "~") == .orderedAscending
                case .runtime: lhs.process.runtime.rawValue < rhs.process.runtime.rawValue
                case .uptime: (lhs.process.identity.startTime ?? .distantFuture) < (rhs.process.identity.startTime ?? .distantFuture)
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
                            Button("Copy PID") { copy(String(listener.process.identity.pid)) }
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

    @TableColumnBuilder<NetworkListener, Never>
    private var activePortColumns: some TableColumnContent<NetworkListener, Never> {
        TableColumn("Status") { (listener: NetworkListener) in
            HStack(spacing: 6) {
                StatusDot(status: listener.process.isSystemProcess ? .warning : .healthy)
                Text(listener.protocolKind.rawValue).font(.caption).foregroundStyle(.secondary)
            }
        }
        .width(min: 70, ideal: 82, max: 95)
        .customizationID("status")
        TableColumn("Port") { (listener: NetworkListener) in PortBadge(port: listener.port) }
            .width(min: 72, ideal: 82, max: 100)
            .customizationID("port")
        TableColumn("Process") { (listener: NetworkListener) in
            Label(listener.process.name, systemImage: listener.process.runtime.symbolName).lineLimit(1)
        }
        .width(min: 130, ideal: 180)
        .customizationID("process")
        TableColumn("Project") { (listener: NetworkListener) in
            Text(listener.process.project?.name ?? "—")
                .foregroundStyle(listener.process.project == nil ? .secondary : .primary)
        }
        .width(min: 100, ideal: 150)
        .customizationID("project")
        TableColumn("PID") { (listener: NetworkListener) in
            Text(listener.process.identity.pid, format: .number.grouping(.never)).monospacedDigit()
        }
        .width(min: 55, ideal: 65, max: 90)
        .customizationID("pid")
        TableColumn("Address") { (listener: NetworkListener) in
            Text(listener.address).font(.system(.body, design: .monospaced)).lineLimit(1)
        }
        .width(min: 95, ideal: 130)
        .customizationID("address")
        TableColumn("Runtime") { (listener: NetworkListener) in Text(listener.process.runtime.rawValue) }
            .width(min: 90, ideal: 120)
            .customizationID("runtime")
        TableColumn("Uptime") { (listener: NetworkListener) in
            Text(listener.process.identity.startTime.map { $0.formatted(.relative(presentation: .numeric)) } ?? "Unknown")
                .foregroundStyle(.secondary)
        }
        .width(min: 90, ideal: 105)
        .customizationID("uptime")
    }
}

private struct ProcessInspectorView: View {
    @EnvironmentObject private var model: AppModel
    let listener: NetworkListener
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
                GroupBox("Process identity") {
                    VStack(spacing: 10) {
                        InspectorRow(title: "PID", value: String(listener.process.identity.pid))
                        InspectorRow(title: "Owner", value: listener.process.owner)
                        InspectorRow(title: "Executable", value: listener.process.executablePath ?? "Unavailable")
                        InspectorRow(title: "Started", value: listener.process.identity.startTime?.formatted() ?? "Unavailable")
                    }
                }
                GroupBox("Verified command") {
                    Text(listener.process.commandLine)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
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
                        Label("Graceful Stop", systemImage: "stop.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(listener.process.isSystemProcess || model.processesBeingControlled.contains(listener.process.identity.pid))

                    HStack {
                        Button("Save as Launch Profile") { showsProfileReview = true }
                        Spacer()
                        Button("Force Stop", role: .destructive) { showsForceConfirmation = true }
                            .disabled(listener.process.isSystemProcess || model.processesBeingControlled.contains(listener.process.identity.pid))
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
            Text("DevBerth will send SIGKILL to PID \(listener.process.identity.pid). Unsaved process state may be lost. The process identity will be verified again immediately before signaling.")
        }
        .sheet(isPresented: $showsProfileReview) {
            DiscoveredProfileReviewView(listener: listener)
        }
    }
}

private struct DiscoveredProfileReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let listener: NetworkListener
    @State private var name: String
    @State private var command: String
    @State private var argumentsText: String
    @State private var workingDirectory: String
    @State private var reviewed = false

    init(listener: NetworkListener) {
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
        profile.kindRawValue = LaunchProfileKind.executable.rawValue
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
