import AppKit
import SwiftUI

struct ActivePortsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection = Set<String>()

    var body: some View {
        HSplitView {
            Group {
                if model.filteredListeners.isEmpty && !model.isRefreshing {
                    EmptyStateView(
                        symbol: model.searchText.isEmpty ? "network.slash" : "magnifyingglass",
                        title: model.searchText.isEmpty ? "No active listeners" : "No matching listeners",
                        message: model.searchText.isEmpty
                            ? "PortPilot did not find any TCP or UDP listeners."
                            : "Try a different port, process, command, or project name.",
                        actionTitle: "Refresh",
                        action: model.refreshNow
                    )
                } else {
                    Table(model.filteredListeners, selection: $selection) {
                        TableColumn("Status") { listener in
                            HStack(spacing: 6) {
                                StatusDot(status: listener.process.isSystemProcess ? .warning : .healthy)
                                Text(listener.protocolKind.rawValue)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .width(min: 70, ideal: 82, max: 95)
                        TableColumn("Port") { PortBadge(port: $0.port) }
                            .width(min: 72, ideal: 82, max: 100)
                        TableColumn("Process") { listener in
                            Label(listener.process.name, systemImage: listener.process.runtime.symbolName)
                                .lineLimit(1)
                        }
                        .width(min: 130, ideal: 180)
                        TableColumn("Project") { listener in
                            Text(listener.process.project?.name ?? "—")
                                .foregroundStyle(listener.process.project == nil ? .secondary : .primary)
                        }
                        .width(min: 100, ideal: 150)
                        TableColumn("PID") { listener in
                            Text(listener.process.identity.pid, format: .number.grouping(.never)).monospacedDigit()
                        }
                        .width(min: 55, ideal: 65, max: 90)
                        TableColumn("Address") { listener in
                            Text(listener.address)
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                        }
                        .width(min: 95, ideal: 130)
                        TableColumn("Runtime") { listener in Text(listener.process.runtime.rawValue) }
                            .width(min: 90, ideal: 120)
                        TableColumn("Uptime") { listener in
                            Text(listener.process.identity.startTime.map { $0.formatted(.relative(presentation: .numeric)) } ?? "Unknown")
                                .foregroundStyle(.secondary)
                        }
                        .width(min: 90, ideal: 105)
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
        .onChange(of: selection) { _, newValue in model.selectedListenerID = newValue.first }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

private struct ProcessInspectorView: View {
    @EnvironmentObject private var model: AppModel
    let listener: NetworkListener
    @State private var showsForceConfirmation = false
    @State private var showsProfileReview = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PortPilotSpacing.large) {
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
                if listener.process.isSystemProcess {
                    Label("This process receives additional termination protection.", systemImage: "lock.shield")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
                VStack(spacing: PortPilotSpacing.small) {
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
            .padding(PortPilotSpacing.large)
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
            Text("PortPilot will send SIGKILL to PID \(listener.process.identity.pid). Unsaved process state may be lost. The process identity will be verified again immediately before signaling.")
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
