import SwiftData
import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case activePorts = "Active Ports"
    case projects = "Projects"
    case launchProfiles = "Launch Profiles"
    case history = "History"
    case docker = "Docker"
    case settings = "Settings"
    var id: Self { self }

    var symbol: String {
        switch self {
        case .overview: "rectangle.3.group"
        case .activePorts: "point.3.connected.trianglepath.dotted"
        case .projects: "folder"
        case .launchProfiles: "play.square.stack"
        case .history: "clock.arrow.circlepath"
        case .docker: "shippingbox"
        case .settings: "gearshape"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: AppSection? = .activePorts
    @State private var showsCommandPalette = false
    @State private var didLaunchAutomaticProfiles = false
    @Query private var profiles: [LaunchProfileRecord]
    @Query private var dependencies: [ProfileDependencyRecord]
    @Query private var expectedPorts: [ExpectedPortRecord]

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.symbol)
                    .tag(section)
            }
            .navigationTitle("PortPilot")
            .safeAreaInset(edge: .bottom) {
                HStack {
                    StatusDot(status: model.isMonitoring ? .healthy : .stopped)
                    Text(model.isMonitoring ? "Monitoring" : "Paused")
                    Spacer()
                    Text("\(model.listeners.count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .padding()
                .background(.bar)
            }
        } detail: {
            detail
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Ports, processes, projects")
        .toolbar {
            ToolbarItemGroup {
                Button { showsCommandPalette = true } label: {
                    Label("Command Palette", systemImage: "command.square")
                }
                .keyboardShortcut("k", modifiers: .command)
                Button { model.isMonitoring ? model.pauseMonitoring() : model.startMonitoring() } label: {
                    Label(model.isMonitoring ? "Pause" : "Resume", systemImage: model.isMonitoring ? "pause" : "play")
                }
                Button { model.refreshNow() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.isRefreshing)
            }
        }
        .sheet(isPresented: $showsCommandPalette) { CommandPaletteView(isPresented: $showsCommandPalette) }
        .sheet(item: $model.pendingLaunchConflict) { pending in
            PortConflictResolutionView(pending: pending)
                .environmentObject(model)
        }
        .onChange(of: model.requestedSection) { _, requested in
            guard let requested else { return }
            selection = requested
            model.requestedSection = nil
        }
        .alert(item: $model.presentedError) { error in
            Alert(
                title: Text("PortPilot couldn’t complete the action"),
                message: Text([error.errorDescription, error.recoverySuggestion].compactMap { $0 }.joined(separator: "\n\n")),
                dismissButton: .default(Text("OK"))
            )
        }
        .task {
            guard !didLaunchAutomaticProfiles else { return }
            didLaunchAutomaticProfiles = true
            for profile in profiles where profile.launchesAutomatically {
                if let configuration = profile.configuration(dependencies: dependencies, expectedPorts: expectedPorts) {
                    await model.launchProfile(configuration)
                }
            }
            model.setNotificationPorts(expectedPorts.map(\.port))
        }
        .onChange(of: expectedPorts.map(\.port)) { _, ports in model.setNotificationPorts(ports) }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .overview {
        case .overview: OverviewView()
        case .activePorts: ActivePortsView()
        case .projects: ProjectsView()
        case .launchProfiles: LaunchProfilesView()
        case .history: HistoryView()
        case .docker: DockerView()
        case .settings: SettingsView()
        }
    }
}

private struct PortConflictResolutionView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let pending: PendingLaunchConflict

    var body: some View {
        VStack(alignment: .leading, spacing: PortPilotSpacing.large) {
            Label("Port \(pending.conflict.expectedPort.port) is already occupied", systemImage: "exclamationmark.triangle.fill")
                .font(.title2.bold()).foregroundStyle(.orange)
            Text("\(pending.profile.name) has not been started. PortPilot will never stop the occupying process without your approval.")
                .foregroundStyle(.secondary)
            GroupBox("Occupying process") {
                VStack(spacing: 10) {
                    InspectorRow(title: "Process", value: pending.conflict.listener.process.name)
                    InspectorRow(title: "PID", value: String(pending.conflict.listener.process.identity.pid))
                    InspectorRow(title: "Executable", value: pending.conflict.listener.process.executablePath ?? "Unavailable")
                    InspectorRow(title: "Project", value: pending.conflict.listener.process.project?.name ?? "Not associated")
                    InspectorRow(title: "PortPilot managed", value: pending.conflict.listener.process.launchedByPortPilot ? "Yes" : "No")
                }
            }
            if pending.conflict.listener.process.isSystemProcess {
                Label("This is a protected system process and cannot be stopped by PortPilot.", systemImage: "lock.shield")
                    .foregroundStyle(.red)
            }
            HStack {
                Button("Cancel", role: .cancel) { model.pendingLaunchConflict = nil; dismiss() }
                Button("Inspect Process") { model.inspectPendingConflict(); dismiss() }
                Button("Edit Expected Port") { model.editProfileForPendingConflict(); dismiss() }
                Spacer()
                Button("Stop Process") { Task { await model.resolvePendingConflict(startAfterStopping: false); dismiss() } }
                    .disabled(pending.conflict.listener.process.isSystemProcess)
                Button("Stop and Start Profile") { Task { await model.resolvePendingConflict(startAfterStopping: true); dismiss() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(pending.conflict.listener.process.isSystemProcess)
            }
        }
        .padding(PortPilotSpacing.xLarge)
        .frame(width: 680)
    }
}
