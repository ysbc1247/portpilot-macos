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
    @Query(sort: \ProjectRecord.name) private var projects: [ProjectRecord]

    private var visible: [NetworkListener] {
        let trimmed = portSearch.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return Array(model.listeners.prefix(8)) }
        return model.listeners.filter { String($0.port).contains(trimmed) || $0.process.name.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PortPilotSpacing.medium) {
            HStack {
                VStack(alignment: .leading) {
                    Text("PortPilot").font(.headline)
                    Text("\(model.listeners.count) active listeners").font(.caption).foregroundStyle(.secondary)
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
                Text("Favorite profiles").font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(Array(favorites)) { record in
                    if let profile = record.configuration(dependencies: dependencies, expectedPorts: expectedPorts) {
                        HStack {
                            Image(systemName: "star.fill").foregroundStyle(.yellow)
                            Text(profile.name).lineLimit(1)
                            Spacer()
                            Button(model.runningProfileIDs.contains(profile.id) ? "Stop" : "Start") {
                                Task {
                                    if model.runningProfileIDs.contains(profile.id) { await model.stopProfile(profile) }
                                    else { await model.launchProfile(profile) }
                                }
                            }
                        }
                    }
                }
            }
            let runningProjects = projects.filter { project in
                profiles.contains { $0.projectID == project.id && model.runningProfileIDs.contains($0.id) }
            }
            if !runningProjects.isEmpty {
                Divider()
                Text("Running projects").font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(runningProjects.prefix(3)) { project in
                    let values = profiles.filter { $0.projectID == project.id }.compactMap {
                        $0.configuration(dependencies: dependencies, expectedPorts: expectedPorts)
                    }
                    HStack {
                        Label(project.name, systemImage: "folder.fill")
                        Spacer()
                        Button("Stop All") { Task { await model.stopProject(values) } }
                    }
                }
            }
            Divider()
            HStack {
                Button(model.isMonitoring ? "Pause" : "Resume") {
                    model.isMonitoring ? model.pauseMonitoring() : model.startMonitoring()
                }
                Button("Open PortPilot") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "main")
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding()
        .frame(width: 390)
    }
}
