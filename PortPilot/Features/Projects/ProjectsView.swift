import AppKit
import SwiftData
import SwiftUI

struct ProjectsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \ProjectRecord.name) private var projects: [ProjectRecord]
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
                        HStack(spacing: PortPilotSpacing.medium) {
                            Image(systemName: "folder.fill").foregroundStyle(.secondary)
                            VStack(alignment: .leading) {
                                Text(project.name).font(.headline)
                                Text(project.folderPath ?? "No project folder")
                                    .foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if let path = project.folderPath {
                                Button("Open in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                            }
                        }
                        .padding(.vertical, 5)
                    }
                    .onDelete { offsets in offsets.map { projects[$0] }.forEach(context.delete) }
                }
            }
        }
        .navigationTitle("Projects")
        .toolbar { Button("New Project", systemImage: "plus") { showsNewProject = true } }
        .sheet(isPresented: $showsNewProject) { NewProjectView() }
    }
}

private struct NewProjectView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var name = ""
    @State private var folderPath = ""

    var body: some View {
        Form {
            TextField("Name", text: $name)
            TextField("Project folder", text: $folderPath)
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 220)
        .navigationTitle("New Project")
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Create") {
                    context.insert(ProjectRecord(name: name, folderPath: folderPath.isEmpty ? nil : folderPath))
                    try? context.save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
            .background(.bar)
        }
    }
}

