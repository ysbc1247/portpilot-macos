import AppKit
import SwiftData
import SwiftUI

struct ProjectsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.modelContext) private var context
    @Query(sort: \ProjectRecord.name) private var projects: [ProjectRecord]
    @Query(sort: \LaunchProfileRecord.name) private var profiles: [LaunchProfileRecord]
    @Query private var dependencies: [ProfileDependencyRecord]
    @Query private var expectedPorts: [ExpectedPortRecord]
    @Query private var processPolicies: [ManagedServiceProcessPolicyRecord]
    @State private var showsNewProject = false

    var body: some View {
        Group {
            if projects.isEmpty {
                EmptyStateView(
                    symbol: "folder.badge.plus",
                    title: "No projects yet",
                    message: "Group launch profiles into a project to start, stop, and inspect related services together.",
                    actionTitle: "New Project",
                    action: { showsNewProject = true }
                )
            } else {
                List {
                    ForEach(projects) { project in
                        projectSection(project)
                    }
                    .onDelete { offsets in
                        for project in offsets.map({ projects[$0] }) {
                            profiles.filter { $0.projectID == project.id }.forEach { $0.projectID = nil }
                            context.delete(project)
                        }
                        try? context.save()
                    }
                }
            }
        }
        .navigationTitle("Projects")
        .toolbar { Button("New Project", systemImage: "plus") { showsNewProject = true } }
        .sheet(isPresented: $showsNewProject) { NewProjectView() }
    }

    private func projectSection(_ project: ProjectRecord) -> some View {
        let projectProfiles = profiles.filter { $0.projectID == project.id }
        let configurations = projectProfiles.compactMap {
            $0.configuration(
                dependencies: dependencies,
                expectedPorts: expectedPorts,
                processPolicies: processPolicies
            )
        }
        return Section {
            if projectProfiles.isEmpty {
                Text("Add an existing launch profile to orchestrate this project.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ForEach(projectProfiles) { profile in
                    HStack {
                        StatusDot(status: model.runningProfileIDs.contains(profile.id) ? .healthy : .stopped)
                        Image(systemName: "play.square")
                        Text(profile.name)
                        Spacer()
                        if let port = expectedPorts.first(where: { $0.profileID == profile.id }) {
                            Text(":\(port.port)").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        Button("Remove from Project") {
                            profile.projectID = nil
                            try? context.save()
                        }
                    }
                }
            }
        } header: {
            VStack(alignment: .leading, spacing: DevBerthSpacing.small) {
                HStack {
                    Image(systemName: "folder.fill")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(project.name).font(.headline)
                        if let path = project.folderPath { Text(path).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Button("Start All") { Task { await model.startProject(configurations) } }
                        .disabled(configurations.isEmpty)
                    Button("Stop All") { Task { await model.stopProject(configurations) } }
                        .disabled(configurations.isEmpty)
                    Menu("Add Service", systemImage: "plus") {
                        let available = profiles.filter { $0.projectID == nil }
                        if available.isEmpty { Text("No unassigned profiles") }
                        ForEach(available) { profile in
                            Button(profile.name) {
                                profile.projectID = project.id
                                try? context.save()
                            }
                        }
                    }
                    Menu("Open", systemImage: "arrow.up.forward.app") {
                        if let path = project.folderPath {
                            Button("Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                            Button("Terminal") { openInTerminal(path) }
                        }
                        if let remote = project.gitRemoteURL, let url = URL(string: remote) {
                            Button("Git Repository") { NSWorkspace.shared.open(url) }
                        }
                    }
                }
                if !configurations.isEmpty {
                    let active = configurations.filter { model.runningProfileIDs.contains($0.id) }.count
                    ProgressView(value: Double(active), total: Double(configurations.count)) {
                        Text("\(active) of \(configurations.count) services running").font(.caption)
                    }
                }
            }
            .textCase(nil)
            .padding(.top, DevBerthSpacing.small)
        }
    }

    private func openInTerminal(_ path: String) {
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: terminal, configuration: configuration)
    }
}

private struct NewProjectView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var name = ""
    @State private var folderPath = ""
    @State private var gitRemoteURL = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $name)
                TextField("Project folder", text: $folderPath)
                TextField("Git repository URL", text: $gitRemoteURL)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Create") {
                    context.insert(ProjectRecord(
                        name: name,
                        folderPath: folderPath.isEmpty ? nil : folderPath,
                        gitRemoteURL: gitRemoteURL.isEmpty ? nil : gitRemoteURL
                    ))
                    try? context.save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding().background(.bar)
        }
        .frame(width: 520, height: 300)
    }
}
