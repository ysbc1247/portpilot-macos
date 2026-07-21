import SwiftData
import SwiftUI

struct LaunchProfilesView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.modelContext) private var context
    @Query(sort: \LaunchProfileRecord.name) private var profiles: [LaunchProfileRecord]
    @Query private var dependencies: [ProfileDependencyRecord]
    @Query private var expectedPorts: [ExpectedPortRecord]
    @State private var selection = Set<UUID>()
    @State private var showsNewProfile = false
    @State private var editingProfile: LaunchProfileRecord?
    @State private var logsProfile: LaunchProfileRecord?

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
                Table(profiles, selection: $selection) {
                    TableColumn("Name", value: \.name)
                    TableColumn("Type") { Text(LaunchProfileKind(rawValue: $0.kindRawValue)?.title ?? "Command") }
                    TableColumn("Command") { Text($0.command).font(.system(.body, design: .monospaced)).lineLimit(1) }
                    TableColumn("Working Directory", value: \.workingDirectory)
                    TableColumn("Ports") { profile in
                        Text(expectedPorts.filter { $0.profileID == profile.id }.map { String($0.port) }.joined(separator: ", ").nilIfEmpty ?? "—")
                            .monospacedDigit()
                    }
                    .width(min: 60, ideal: 90)
                    TableColumn("Status") { profile in
                        if model.runningProfileIDs.contains(profile.id) {
                            Label("Running", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else if model.profileFailures[profile.id] != nil {
                            Label("Failed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        } else {
                            Text("Stopped").foregroundStyle(.secondary)
                        }
                    }
                    .width(min: 85, ideal: 100)
                    TableColumn("Actions") { profile in
                        if let configuration = profile.configuration(dependencies: dependencies, expectedPorts: expectedPorts) {
                            HStack {
                                Button("Logs") { logsProfile = profile }
                                if model.runningProfileIDs.contains(profile.id) {
                                    Button("Stop") { Task { await model.stopProfile(configuration) } }
                                } else {
                                    Button("Start") { Task { await model.launchProfile(configuration) } }
                                }
                            }
                        } else {
                            Text("Invalid").foregroundStyle(.red)
                        }
                    }
                    .width(min: 110, ideal: 140)
                }
                .contextMenu(forSelectionType: UUID.self) { ids in
                    Button("Edit") { editingProfile = profiles.first { ids.contains($0.id) } }
                    Button("Duplicate") { if let source = profiles.first(where: { ids.contains($0.id) }) { duplicate(source) } }
                    Divider()
                    Button("Delete", role: .destructive) { delete(ids) }
                } primaryAction: { ids in editingProfile = profiles.first { ids.contains($0.id) } }
            }
        }
        .navigationTitle("Launch Profiles")
        .toolbar {
            Button("New Profile", systemImage: "plus") { showsNewProfile = true }
            Button("Edit", systemImage: "pencil") { editingProfile = profiles.first { selection.contains($0.id) } }
                .disabled(selection.count != 1)
            Button("Duplicate", systemImage: "plus.square.on.square") {
                if let source = profiles.first(where: { selection.contains($0.id) }) { duplicate(source) }
            }
            .disabled(selection.count != 1)
        }
        .sheet(isPresented: $showsNewProfile) {
            LaunchProfileEditor(record: nil, profiles: profiles, dependencies: dependencies, expectedPorts: expectedPorts)
        }
        .sheet(item: $editingProfile) { profile in
            LaunchProfileEditor(record: profile, profiles: profiles, dependencies: dependencies, expectedPorts: expectedPorts)
        }
        .sheet(item: $logsProfile) { profile in
            ProfileLogsView(profileID: profile.id, profileName: profile.name).environmentObject(model)
        }
    }

    private func duplicate(_ source: LaunchProfileRecord) {
        let copy = LaunchProfileRecord(name: "\(source.name) Copy", command: source.command, workingDirectory: source.workingDirectory)
        copy.kindRawValue = source.kindRawValue
        copy.argumentsData = source.argumentsData
        copy.shellData = source.shellData
        copy.environmentData = source.environmentData
        copy.secretReferencesData = source.secretReferencesData
        copy.startupTimeoutSeconds = source.startupTimeoutSeconds
        copy.shutdownTimeoutSeconds = source.shutdownTimeoutSeconds
        copy.restartPolicyRawValue = source.restartPolicyRawValue
        copy.healthCheckData = source.healthCheckData
        copy.tagsData = source.tagsData
        copy.icon = source.icon
        copy.isReviewed = source.isReviewed
        context.insert(copy)
        for port in expectedPorts where port.profileID == source.id {
            if let value = UInt16(exactly: port.port), let kind = ListenerProtocol(rawValue: port.protocolRawValue) {
                context.insert(ExpectedPortRecord(profileID: copy.id, port: value, protocolKind: kind, required: port.required))
            }
        }
        try? context.save()
    }

    private func delete(_ ids: Set<UUID>) {
        profiles.filter { ids.contains($0.id) }.forEach(context.delete)
        dependencies.filter { ids.contains($0.profileID) || ids.contains($0.dependencyProfileID) }.forEach(context.delete)
        expectedPorts.filter { ids.contains($0.profileID) }.forEach(context.delete)
        try? context.save()
        selection.subtract(ids)
    }
}

private struct LaunchProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let record: LaunchProfileRecord?
    let profiles: [LaunchProfileRecord]
    let dependencies: [ProfileDependencyRecord]
    let expectedPorts: [ExpectedPortRecord]
    private let secretStore: any SecretStoring = KeychainSecretStore()

    @State private var name: String
    @State private var kind: LaunchProfileKind
    @State private var command: String
    @State private var argumentsText: String
    @State private var workingDirectory: String
    @State private var usesLoginShell: Bool
    @State private var shellPath: String
    @State private var environmentText: String
    @State private var portsText: String
    @State private var startupTimeout: Double
    @State private var shutdownTimeout: Double
    @State private var restartPolicy: RestartPolicy
    @State private var healthURL: String
    @State private var expectedStatus: Int
    @State private var dependencyID: UUID?
    @State private var tagsText: String
    @State private var launchesAutomatically: Bool
    @State private var isFavorite: Bool
    @State private var secretName = ""
    @State private var secretValue = ""
    @State private var errorMessage: String?

    init(
        record: LaunchProfileRecord?,
        profiles: [LaunchProfileRecord],
        dependencies: [ProfileDependencyRecord],
        expectedPorts: [ExpectedPortRecord]
    ) {
        self.record = record
        self.profiles = profiles
        self.dependencies = dependencies
        self.expectedPorts = expectedPorts
        let decoder = JSONDecoder()
        let arguments = record.flatMap { try? decoder.decode([String].self, from: $0.argumentsData) } ?? []
        let shell = record.flatMap { try? decoder.decode(ShellSelection.self, from: $0.shellData) } ?? .direct
        let environment = record.flatMap { try? decoder.decode([String: String].self, from: $0.environmentData) } ?? [:]
        let tags = record.flatMap { try? decoder.decode([String].self, from: $0.tagsData) } ?? []
        let health = record?.healthCheckData.flatMap { try? decoder.decode(HealthCheckConfiguration.self, from: $0) }
        let matchingPorts = expectedPorts.filter { $0.profileID == record?.id }
        _name = State(initialValue: record?.name ?? "")
        _kind = State(initialValue: record.flatMap { LaunchProfileKind(rawValue: $0.kindRawValue) } ?? .genericCommand)
        _command = State(initialValue: record?.command ?? "")
        _argumentsText = State(initialValue: arguments.joined(separator: "\n"))
        _workingDirectory = State(initialValue: record?.workingDirectory ?? NSHomeDirectory())
        switch shell {
        case .direct:
            _usesLoginShell = State(initialValue: false); _shellPath = State(initialValue: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        case let .loginShell(path), let .custom(path):
            _usesLoginShell = State(initialValue: true); _shellPath = State(initialValue: path)
        }
        _environmentText = State(initialValue: environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n"))
        _portsText = State(initialValue: matchingPorts.map { "\($0.protocolRawValue.lowercased()):\($0.port)" }.joined(separator: ", "))
        _startupTimeout = State(initialValue: record?.startupTimeoutSeconds ?? 30)
        _shutdownTimeout = State(initialValue: record?.shutdownTimeoutSeconds ?? 5)
        _restartPolicy = State(initialValue: record.flatMap { RestartPolicy(rawValue: $0.restartPolicyRawValue) } ?? .never)
        _healthURL = State(initialValue: health?.url.absoluteString ?? "")
        _expectedStatus = State(initialValue: health?.expectedStatus ?? 200)
        _dependencyID = State(initialValue: dependencies.first { $0.profileID == record?.id }?.dependencyProfileID)
        _tagsText = State(initialValue: tags.joined(separator: ", "))
        _launchesAutomatically = State(initialValue: record?.launchesAutomatically ?? false)
        _isFavorite = State(initialValue: record?.isFavorite ?? false)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Identity") {
                    TextField("Name", text: $name)
                    Picker("Profile type", selection: $kind) {
                        ForEach(LaunchProfileKind.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    TextField("Command or executable", text: $command)
                    TextField("Arguments (one per line)", text: $argumentsText, axis: .vertical).lineLimit(2...6)
                    TextField("Working directory", text: $workingDirectory)
                }
                Section("Execution") {
                    Toggle("Run through a login shell", isOn: $usesLoginShell)
                    if usesLoginShell { TextField("Shell", text: $shellPath) }
                    TextField("Environment (KEY=value, one per line)", text: $environmentText, axis: .vertical).lineLimit(2...5)
                    TextField("Expected ports (tcp:3000, udp:5353)", text: $portsText)
                    Picker("Depends on", selection: $dependencyID) {
                        Text("No dependency").tag(nil as UUID?)
                        ForEach(profiles.filter { $0.id != record?.id }) { Text($0.name).tag($0.id as UUID?) }
                    }
                    Picker("Restart policy", selection: $restartPolicy) {
                        ForEach(RestartPolicy.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                }
                Section("Readiness") {
                    TextField("HTTP health-check URL (optional)", text: $healthURL)
                    Stepper("Expected HTTP status: \(expectedStatus)", value: $expectedStatus, in: 100...599)
                    Stepper("Startup timeout: \(Int(startupTimeout)) seconds", value: $startupTimeout, in: 1...300)
                    Stepper("Shutdown timeout: \(Int(shutdownTimeout)) seconds", value: $shutdownTimeout, in: 1...60)
                }
                Section("Secret environment value") {
                    TextField("Variable name", text: $secretName)
                    SecureField("Value (saved to Keychain)", text: $secretValue)
                    Text("Existing secret values are never read into this form or stored in SwiftData.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Organization") {
                    TextField("Tags (comma separated)", text: $tagsText)
                    Toggle("Favorite", isOn: $isFavorite)
                    Toggle("Launch when DevBerth opens", isOn: $launchesAutomatically)
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save Profile") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty || command.isEmpty || workingDirectory.isEmpty)
            }
            .padding().background(.bar)
        }
        .frame(width: 680, height: 720)
    }

    @MainActor
    private func save() async {
        let target = record ?? LaunchProfileRecord(name: name, command: command, workingDirectory: workingDirectory)
        let arguments = argumentsText.split(whereSeparator: \.isNewline).map(String.init)
        let environment: [String: String] = Dictionary(uniqueKeysWithValues: environmentText.split(whereSeparator: \.isNewline).compactMap { line -> (String, String)? in
            guard let equal = line.firstIndex(of: "=") else { return nil }
            return (String(line[..<equal]), String(line[line.index(after: equal)...]))
        })
        let shell: ShellSelection = usesLoginShell ? .loginShell(path: shellPath) : .direct
        let encoder = JSONEncoder()
        var secretReferences = (try? JSONDecoder().decode([String: UUID].self, from: target.secretReferencesData)) ?? [:]
        if !secretName.isEmpty && !secretValue.isEmpty {
            let reference = secretReferences[secretName] ?? UUID()
            do { try await secretStore.save(value: secretValue, reference: reference); secretReferences[secretName] = reference }
            catch { errorMessage = error.localizedDescription; return }
        }
        target.name = name
        target.kindRawValue = kind.rawValue
        target.command = command
        target.argumentsData = (try? encoder.encode(arguments)) ?? Data("[]".utf8)
        target.workingDirectory = workingDirectory
        target.shellData = (try? encoder.encode(shell)) ?? Data()
        target.environmentData = (try? encoder.encode(environment)) ?? Data("{}".utf8)
        target.secretReferencesData = (try? encoder.encode(secretReferences)) ?? Data("{}".utf8)
        target.startupTimeoutSeconds = startupTimeout
        target.shutdownTimeoutSeconds = shutdownTimeout
        target.restartPolicyRawValue = restartPolicy.rawValue
        target.healthCheckData = URL(string: healthURL).map {
            try? encoder.encode(HealthCheckConfiguration(url: $0, expectedStatus: expectedStatus, intervalSeconds: 0.5))
        } ?? nil
        target.tagsData = (try? encoder.encode(tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })) ?? Data("[]".utf8)
        target.isFavorite = isFavorite
        target.launchesAutomatically = launchesAutomatically
        target.isReviewed = true
        target.updatedAt = Date()
        if record == nil { context.insert(target) }

        expectedPorts.filter { $0.profileID == target.id }.forEach(context.delete)
        for component in portsText.split(separator: ",") {
            let parts = component.trimmingCharacters(in: .whitespaces).split(separator: ":")
            guard parts.count == 2, let port = UInt16(parts[1]), let protocolKind = ListenerProtocol(rawValue: parts[0].uppercased()) else { continue }
            context.insert(ExpectedPortRecord(profileID: target.id, port: port, protocolKind: protocolKind))
        }
        dependencies.filter { $0.profileID == target.id }.forEach(context.delete)
        if let dependencyID { context.insert(ProfileDependencyRecord(profileID: target.id, dependencyProfileID: dependencyID)) }
        do { try context.save(); dismiss() }
        catch { errorMessage = error.localizedDescription }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
