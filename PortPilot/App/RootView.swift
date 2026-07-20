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
