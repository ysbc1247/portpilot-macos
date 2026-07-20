import SwiftData
import SwiftUI

struct LaunchProfilesView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \LaunchProfileRecord.name) private var profiles: [LaunchProfileRecord]
    @State private var showsNewProfile = false

    var body: some View {
        Group {
            if profiles.isEmpty {
                EmptyStateView(
                    symbol: "play.square.stack",
                    title: "No launch profiles",
                    message: "A reviewed launch profile is the reliable way to restart a service.",
                    actionTitle: "New Profile",
                    action: { showsNewProfile = true }
                )
            } else {
                Table(profiles) {
                    TableColumn("Name", value: \.name)
                    TableColumn("Type") { Text(LaunchProfileKind(rawValue: $0.kindRawValue)?.title ?? "Command") }
                    TableColumn("Command") { Text("\($0.command) …").font(.system(.body, design: .monospaced)).lineLimit(1) }
                    TableColumn("Working Directory", value: \.workingDirectory)
                    TableColumn("Auto") { Image(systemName: $0.launchesAutomatically ? "checkmark.circle.fill" : "circle") }
                        .width(45)
                }
            }
        }
        .navigationTitle("Launch Profiles")
        .toolbar { Button("New Profile", systemImage: "plus") { showsNewProfile = true } }
        .sheet(isPresented: $showsNewProfile) { NewLaunchProfileView() }
    }
}

private struct NewLaunchProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var name = ""
    @State private var command = ""
    @State private var workingDirectory = NSHomeDirectory()
    @State private var kind = LaunchProfileKind.genericCommand

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $name)
                Picker("Profile type", selection: $kind) {
                    ForEach(LaunchProfileKind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                TextField("Command or executable", text: $command)
                TextField("Working directory", text: $workingDirectory)
                Text("Discovered commands are untrusted suggestions. Review command, arguments, directory, environment, and expected ports before launch.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save Profile") {
                    let record = LaunchProfileRecord(name: name, command: command, workingDirectory: workingDirectory)
                    record.kindRawValue = kind.rawValue
                    context.insert(record)
                    try? context.save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || command.isEmpty || workingDirectory.isEmpty)
            }
            .padding().background(.bar)
        }
        .frame(width: 580, height: 430)
    }
}

