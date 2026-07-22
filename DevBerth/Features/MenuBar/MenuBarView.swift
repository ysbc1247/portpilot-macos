import AppKit
import SwiftData
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var portSearch = ""
    @Query(sort: \LaunchProfileRecord.name) private var profiles: [LaunchProfileRecord]
    @Query private var dependencies: [ProfileDependencyRecord]
    @Query private var expectedPorts: [ExpectedPortRecord]
    @Query private var processPolicies: [ManagedServiceProcessPolicyRecord]
    @Query private var serviceChecks: [ManagedServiceCheckRecord]
    @Query(sort: \ProjectRecord.name) private var projects: [ProjectRecord]
    @Query(sort: \LifecycleEventRecord.timestamp, order: .reverse) private var lifecycleEvents: [LifecycleEventRecord]

    private var visible: [ObservedListener] {
        let trimmed = portSearch.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return Array(model.listeners.prefix(8)) }
        return model.listeners.filter { String($0.port).contains(trimmed) || $0.process.name.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DevBerthSpacing.medium) {
            HStack {
                VStack(alignment: .leading) {
                    Text("DevBerth").font(.headline)
                    Text("\(activeManagedCount) managed · \(unexpectedListenerCount) unexpected · \(unhealthyCount) unhealthy")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                StatusDot(status: model.isMonitoring ? .healthy : .stopped)
            }
            TextField("Find a port or process", text: $portSearch)
                .textFieldStyle(.roundedBorder)
            Divider()
            if visible.isEmpty {
                Text("No matching listeners").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 70)
            } else {
                ForEach(visible) { listener in
                    HStack {
                        PortBadge(port: listener.port)
                        Image(systemName: listener.process.runtime.symbolName)
                        Text(listener.process.name).lineLimit(1)
                        Spacer()
                        Text(listener.protocolKind.rawValue).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            let favorites = profiles.filter(\.isFavorite).prefix(4)
            if !favorites.isEmpty {
                Divider()
                Text("Favorite managed services").font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(Array(favorites)) { record in
                    if let profile = record.configuration(
                        dependencies: dependencies,
                        expectedPorts: expectedPorts,
                        processPolicies: processPolicies,
                        serviceChecks: serviceChecks
                    ) {
                        HStack {
                            Image(systemName: "star.fill").foregroundStyle(.yellow)
                            Text(profile.name).lineLimit(1)
                            Spacer()
                            Button(model.isManagedServiceRunning(profile.id) ? "Stop" : "Start") {
                                Task {
                                    if model.isManagedServiceRunning(profile.id) { await model.stopProfile(profile) }
                                    else { await model.launchProfile(profile) }
                                }
                            }
                        }
                    }
                }
            }
            if !recentProjects.isEmpty {
                Divider()
                Text(hasRecentProjectEvidence ? "Recent projects" : "Projects")
                    .font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(recentProjects) { project in
                    let values = profiles.filter { $0.projectID == project.id }.compactMap {
                        $0.configuration(
                            dependencies: dependencies,
                            expectedPorts: expectedPorts,
                            processPolicies: processPolicies,
                            serviceChecks: serviceChecks
                        )
                    }
                    HStack {
                        Label(project.name, systemImage: "folder.fill")
                        Spacer()
                        let isRunning = values.contains { model.isManagedServiceRunning($0.id) }
                        Button(isRunning ? "Stop" : "Start") {
                            Task {
                                if isRunning { await model.stopProject(values) }
                                else { await model.startProject(values) }
                            }
                        }
                        .disabled(values.isEmpty)
                    }
                }
            }
            Divider()
            Button("Capture Workspace Session", systemImage: "camera") {
                model.requestSessionCapture()
                openMainWindow()
            }
            HStack {
                Button(model.isMonitoring ? "Pause" : "Resume") {
                    model.isMonitoring ? model.pauseMonitoring() : model.startMonitoring()
                }
                Button("Open DevBerth") {
                    openMainWindow()
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding()
        .frame(width: 390)
        .background {
            WindowVisibilityReporter(requiresKeyWindow: true) { visible in
                model.setMonitoringSurface(.menuBar, visible: visible)
            }
        }
    }

    private var activeManagedCount: Int {
        model.runtimeStatuses.values.filter(\.processRunning).count
    }

    private var unexpectedListenerCount: Int {
        model.listeners.filter { $0.process.managedServiceID == nil }.count
    }

    private var unhealthyCount: Int {
        model.runtimeStatuses.values.filter {
            $0.lifecycleState == .failed || $0.healthState == .degraded || $0.healthState == .unhealthy
        }.count
    }

    private var recentProjects: [ProjectRecord] {
        var seen = Set<UUID>()
        var values: [ProjectRecord] = []
        for event in lifecycleEvents {
            guard let projectID = event.projectID,
                  seen.insert(projectID).inserted,
                  let project = projects.first(where: { $0.id == projectID }) else { continue }
            values.append(project)
            if values.count == 3 { break }
        }
        for project in projects where values.count < 3 && seen.insert(project.id).inserted {
            values.append(project)
        }
        return values
    }

    private var hasRecentProjectEvidence: Bool {
        lifecycleEvents.contains { event in
            event.projectID.map { projectID in projects.contains { $0.id == projectID } } ?? false
        }
    }

    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "main")
    }
}
