import SwiftData
import SwiftUI

struct LaunchProfilesView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.modelContext) private var context
    @Query(sort: \LaunchProfileRecord.name) private var profiles: [LaunchProfileRecord]
    @Query private var dependencies: [ProfileDependencyRecord]
    @Query private var expectedPorts: [ExpectedPortRecord]
    @Query private var processPolicies: [ManagedServiceProcessPolicyRecord]
    @Query private var trustRecords: [ManagedServiceTrustRecord]
    @Query private var validationRecords: [ManagedServiceValidationRecord]
    @State private var selection = Set<UUID>()
    @State private var showsNewProfile = false
    @State private var editingProfile: LaunchProfileRecord?
    @State private var logsProfile: LaunchProfileRecord?
    @State private var operationError: String?
    private let secretLifecycle = SecretLifecycleCoordinator()

    var body: some View {
        Group {
            if profiles.isEmpty {
                EmptyStateView(
                    symbol: "play.square.stack",
                    title: "No launch profiles",
                    message: "Create and validate a launch profile before relying on restart.",
                    actionTitle: "New Profile",
                    action: { showsNewProfile = true }
                )
            } else {
                Table(profiles, selection: $selection) {
                    TableColumn("Name", value: \.name)
                    TableColumn("Type") {
                        Text(LaunchMechanism(rawValue: $0.kindRawValue)?.title ?? "Command")
                    }
                    TableColumn("Command") {
                        Text($0.command).font(.system(.body, design: .monospaced)).lineLimit(1)
                    }
                    TableColumn("Ports") { profile in
                        Text(expectedPortsFor(profile).map { String($0.port) }.joined(separator: ", ").nilIfEmpty ?? "—")
                            .monospacedDigit()
                    }
                    .width(min: 60, ideal: 80)
                    TableColumn("Restart trust") { profile in
                        if let summary = trustSummary(for: profile) {
                            RestartTrustLabel(summary: summary)
                        } else {
                            Label("Invalid definition", systemImage: "nosign").foregroundStyle(.red)
                        }
                    }
                    .width(min: 155, ideal: 185)
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
                        if let configuration = configuration(for: profile) {
                            HStack {
                                Button("Logs") { logsProfile = profile }
                                if model.runningProfileIDs.contains(profile.id) {
                                    Button("Stop") { Task { await model.stopProfile(configuration) } }
                                } else if trustSummary(for: profile)?.state == .verifiedRestartable {
                                    Button("Start") { Task { await model.launchProfile(configuration) } }
                                } else {
                                    Button("Review & Validate") { editingProfile = profile }
                                }
                            }
                        } else {
                            Button("Repair") { editingProfile = profile }
                        }
                    }
                    .width(min: 145, ideal: 190)
                }
                .contextMenu(forSelectionType: UUID.self) { ids in
                    Button("Edit") { editingProfile = profiles.first { ids.contains($0.id) } }
                    Button("Duplicate") {
                        if let source = profiles.first(where: { ids.contains($0.id) }) {
                            Task { await duplicate(source) }
                        }
                    }
                    Divider()
                    Button("Delete", role: .destructive) { Task { await delete(ids) } }
                } primaryAction: { ids in
                    editingProfile = profiles.first { ids.contains($0.id) }
                }
            }
        }
        .navigationTitle("Launch Profiles")
        .toolbar {
            Button("New Profile", systemImage: "plus") { showsNewProfile = true }
            Button("Edit", systemImage: "pencil") {
                editingProfile = profiles.first { selection.contains($0.id) }
            }
            .disabled(selection.count != 1)
            Button("Duplicate", systemImage: "plus.square.on.square") {
                if let source = profiles.first(where: { selection.contains($0.id) }) {
                    Task { await duplicate(source) }
                }
            }
            .disabled(selection.count != 1)
        }
        .sheet(isPresented: $showsNewProfile) {
            LaunchProfileEditor(
                record: nil,
                profiles: profiles,
                dependencies: dependencies,
                expectedPorts: expectedPorts,
                processPolicies: processPolicies
            )
        }
        .sheet(item: $editingProfile) { profile in
            LaunchProfileEditor(
                record: profile,
                profiles: profiles,
                dependencies: dependencies,
                expectedPorts: expectedPorts,
                processPolicies: processPolicies
            )
        }
        .sheet(item: $logsProfile) { profile in
            ProfileLogsView(profileID: profile.id, profileName: profile.name).environmentObject(model)
        }
        .alert(
            "Profile operation failed",
            isPresented: Binding(
                get: { operationError != nil },
                set: { if !$0 { operationError = nil } }
            )
        ) {
            Button("OK") { operationError = nil }
        } message: {
            Text(operationError ?? "Unknown error")
        }
    }

    private func expectedPortsFor(_ profile: LaunchProfileRecord) -> [ExpectedPortRecord] {
        expectedPorts.filter { $0.profileID == profile.id }
    }

    private func configuration(for profile: LaunchProfileRecord) -> ManagedServiceConfiguration? {
        profile.configuration(
            dependencies: dependencies,
            expectedPorts: expectedPorts,
            processPolicies: processPolicies
        )
    }

    private func trustSummary(for profile: LaunchProfileRecord) -> RestartTrustSummary? {
        guard let configuration = configuration(for: profile) else { return nil }
        let validation = validationRecords.first { $0.managedServiceID == profile.id }?.result
        return RestartTrustEvaluator.summary(for: configuration, validation: validation)
    }

    @MainActor
    private func duplicate(_ source: LaunchProfileRecord) async {
        let decoder = JSONDecoder()
        let sourceReferences = (try? decoder.decode([String: UUID].self, from: source.secretReferencesData)) ?? [:]
        let staged: StagedSecretMutation
        do {
            staged = try await secretLifecycle.clone(sourceReferences)
        } catch {
            operationError = error.localizedDescription
            return
        }

        let encoder = JSONEncoder()
        let copy = LaunchProfileRecord(
            name: "\(source.name) Copy",
            command: source.command,
            workingDirectory: source.workingDirectory
        )
        copy.projectID = source.projectID
        copy.kindRawValue = source.kindRawValue
        copy.argumentsData = source.argumentsData
        copy.shellData = source.shellData
        copy.environmentData = source.environmentData
        copy.secretReferencesData = (try? encoder.encode(staged.references)) ?? Data("{}".utf8)
        copy.startupTimeoutSeconds = source.startupTimeoutSeconds
        copy.shutdownTimeoutSeconds = source.shutdownTimeoutSeconds
        copy.restartPolicyRawValue = source.restartPolicyRawValue
        copy.healthCheckData = source.healthCheckData
        copy.logFile = source.logFile
        copy.tagsData = source.tagsData
        copy.icon = source.icon
        copy.isReviewed = source.isReviewed
        copy.isFavorite = false
        copy.launchesAutomatically = false
        context.insert(copy)
        for port in expectedPortsFor(source) {
            if let value = UInt16(exactly: port.port),
               let kind = ListenerProtocol(rawValue: port.protocolRawValue) {
                context.insert(ExpectedPortRecord(
                    profileID: copy.id,
                    port: value,
                    protocolKind: kind,
                    required: port.required
                ))
            }
        }
        for dependency in dependencies where dependency.profileID == source.id {
            context.insert(ProfileDependencyRecord(
                profileID: copy.id,
                dependencyProfileID: dependency.dependencyProfileID
            ))
        }
        let sourcePolicy = processPolicies.first { $0.managedServiceID == source.id }?.policy
            ?? .controlledProcessGroup
        context.insert(ManagedServiceProcessPolicyRecord(
            managedServiceID: copy.id,
            policy: sourcePolicy
        ))
        do {
            try context.save()
        } catch {
            context.rollback()
            await secretLifecycle.rollback(staged)
            operationError = error.localizedDescription
        }
    }

    @MainActor
    private func delete(_ ids: Set<UUID>) async {
        let decoder = JSONDecoder()
        let candidateReferences = Set(
            profiles
                .filter { ids.contains($0.id) }
                .flatMap { profile in
                    ((try? decoder.decode([String: UUID].self, from: profile.secretReferencesData)) ?? [:]).values
                }
        )
        profiles.filter { ids.contains($0.id) }.forEach(context.delete)
        dependencies.filter { ids.contains($0.profileID) || ids.contains($0.dependencyProfileID) }
            .forEach(context.delete)
        expectedPorts.filter { ids.contains($0.profileID) }.forEach(context.delete)
        processPolicies.filter { ids.contains($0.managedServiceID) }.forEach(context.delete)
        trustRecords.filter { ids.contains($0.managedServiceID) }.forEach(context.delete)
        validationRecords.filter { ids.contains($0.managedServiceID) }.forEach(context.delete)
        do {
            try context.save()
        } catch {
            context.rollback()
            operationError = error.localizedDescription
            return
        }

        let referencesStillInUse = Set(
            profiles
                .filter { !ids.contains($0.id) }
                .flatMap { profile in
                    ((try? decoder.decode([String: UUID].self, from: profile.secretReferencesData)) ?? [:]).values
                }
        )
        do {
            try await secretLifecycle.deleteUnused(
                candidateReferences,
                referencesStillInUse: referencesStillInUse
            )
        } catch {
            operationError = "The profile was deleted, but an unused Keychain item could not be removed: \(error.localizedDescription)"
        }
        selection.subtract(ids)
    }
}

private struct RestartTrustLabel: View {
    let summary: RestartTrustSummary

    var body: some View {
        Label(summary.state.title, systemImage: summary.state.symbol)
            .foregroundStyle(color)
            .help(summary.reasons.joined(separator: " "))
            .accessibilityLabel("Restart trust: \(summary.state.title)")
            .accessibilityHint(summary.reasons.joined(separator: " "))
    }

    private var color: Color {
        switch summary.state {
        case .verifiedRestartable: .green
        case .conditionallyRestartable: .orange
        case .inferredRestartCandidate: .blue
        case .notRestartable: .red
        }
    }
}

private struct LaunchProfileEditor: View {
    private enum SaveMode { case draft, validate }

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var validationRecords: [ManagedServiceValidationRecord]
    let record: LaunchProfileRecord?
    let profiles: [LaunchProfileRecord]
    let dependencies: [ProfileDependencyRecord]
    let expectedPorts: [ExpectedPortRecord]
    let processPolicies: [ManagedServiceProcessPolicyRecord]
    private let secretLifecycle = SecretLifecycleCoordinator()
    private let draftID: UUID
    private let existingSecretReferences: [String: UUID]

    @State private var name: String
    @State private var kind: LaunchMechanism
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
    @State private var terminationScope: ManagedProcessTerminationScope
    @State private var healthURL: String
    @State private var expectedStatus: Int
    @State private var dependencyID: UUID?
    @State private var tagsText: String
    @State private var launchesAutomatically: Bool
    @State private var isFavorite: Bool
    @State private var reviewed: Bool
    @State private var removedSecretNames = Set<String>()
    @State private var secretReplacements: [String: String] = [:]
    @State private var secretName = ""
    @State private var secretValue = ""
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(
        record: LaunchProfileRecord?,
        profiles: [LaunchProfileRecord],
        dependencies: [ProfileDependencyRecord],
        expectedPorts: [ExpectedPortRecord],
        processPolicies: [ManagedServiceProcessPolicyRecord]
    ) {
        self.record = record
        self.profiles = profiles
        self.dependencies = dependencies
        self.expectedPorts = expectedPorts
        self.processPolicies = processPolicies
        draftID = record?.id ?? UUID()
        let decoder = JSONDecoder()
        let arguments = record.flatMap { try? decoder.decode([String].self, from: $0.argumentsData) } ?? []
        let shell = record.flatMap { try? decoder.decode(ShellSelection.self, from: $0.shellData) } ?? .direct
        let environment = record.flatMap { try? decoder.decode([String: String].self, from: $0.environmentData) } ?? [:]
        let secretReferences = record.flatMap { try? decoder.decode([String: UUID].self, from: $0.secretReferencesData) } ?? [:]
        existingSecretReferences = secretReferences
        let tags = record.flatMap { try? decoder.decode([String].self, from: $0.tagsData) } ?? []
        let health = record?.healthCheckData.flatMap { try? decoder.decode(HealthCheckConfiguration.self, from: $0) }
        let matchingPorts = expectedPorts.filter { $0.profileID == record?.id }
        _name = State(initialValue: record?.name ?? "")
        _kind = State(initialValue: record.flatMap { LaunchMechanism(rawValue: $0.kindRawValue) } ?? .genericCommand)
        _command = State(initialValue: record?.command ?? "")
        _argumentsText = State(initialValue: arguments.joined(separator: "\n"))
        _workingDirectory = State(initialValue: record?.workingDirectory ?? NSHomeDirectory())
        switch shell {
        case .direct:
            _usesLoginShell = State(initialValue: false)
            _shellPath = State(initialValue: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        case let .loginShell(path), let .custom(path):
            _usesLoginShell = State(initialValue: true)
            _shellPath = State(initialValue: path)
        }
        _environmentText = State(initialValue: environment.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: "\n"))
        _portsText = State(initialValue: matchingPorts.map { "\($0.protocolRawValue.lowercased()):\($0.port)" }
            .joined(separator: ", "))
        _startupTimeout = State(initialValue: record?.startupTimeoutSeconds ?? 30)
        _shutdownTimeout = State(initialValue: record?.shutdownTimeoutSeconds ?? 5)
        _restartPolicy = State(initialValue: record.flatMap { RestartPolicy(rawValue: $0.restartPolicyRawValue) } ?? .never)
        _terminationScope = State(initialValue: record.flatMap { record in
            processPolicies.first { $0.managedServiceID == record.id }?.policy?.terminationScope
        } ?? .controlledProcessGroup)
        _healthURL = State(initialValue: health?.url.absoluteString ?? "")
        _expectedStatus = State(initialValue: health?.expectedStatus ?? 200)
        _dependencyID = State(initialValue: dependencies.first { $0.profileID == record?.id }?.dependencyProfileID)
        _tagsText = State(initialValue: tags.joined(separator: ", "))
        _launchesAutomatically = State(initialValue: record?.launchesAutomatically ?? false)
        _isFavorite = State(initialValue: record?.isFavorite ?? false)
        _reviewed = State(initialValue: record?.isReviewed ?? false)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Restart trust") {
                    RestartTrustLabel(summary: currentTrustSummary)
                    ForEach(currentTrustSummary.reasons, id: \.self) { reason in
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    }
                    if let date = currentTrustSummary.lastValidatedAt {
                        LabeledContent("Last validated") { Text(date.formatted()) }
                    }
                }
                Section("Identity") {
                    TextField("Name", text: $name)
                    Picker("Profile type", selection: $kind) {
                        ForEach(LaunchMechanism.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    TextField("Command or executable", text: $command)
                    TextField("Arguments (one exact argument per line)", text: $argumentsText, axis: .vertical)
                        .lineLimit(2...6)
                    TextField("Working directory", text: $workingDirectory)
                    Toggle("I reviewed the command, argument boundaries, and working directory", isOn: $reviewed)
                }
                Section("Execution") {
                    Toggle("Run through a login shell", isOn: $usesLoginShell)
                    if usesLoginShell { TextField("Shell", text: $shellPath) }
                    TextField("Non-secret environment (KEY=value, one per line)", text: $environmentText, axis: .vertical)
                        .lineLimit(2...5)
                    Text("Secret-like names are rejected here. Add them to Keychain below.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("Expected ports (tcp:3000, udp:5353)", text: $portsText)
                    Picker("Depends on", selection: $dependencyID) {
                        Text("No dependency").tag(nil as UUID?)
                        ForEach(profiles.filter { $0.id != record?.id }) { Text($0.name).tag($0.id as UUID?) }
                    }
                    Picker("Restart policy", selection: $restartPolicy) {
                        ForEach(RestartPolicy.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    Picker("Graceful stop scope", selection: $terminationScope) {
                        Text("Entire controlled process group").tag(ManagedProcessTerminationScope.controlledProcessGroup)
                        Text("Root process only").tag(ManagedProcessTerminationScope.rootProcessOnly)
                    }
                    Text("Group scope prevents child servers from becoming orphans. Root-only scope is for reviewed supervisors that own descendant shutdown.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Readiness") {
                    TextField("HTTP health-check URL (optional)", text: $healthURL)
                    Stepper("Expected HTTP status: \(expectedStatus)", value: $expectedStatus, in: 100...599)
                    Stepper("Startup timeout: \(Int(startupTimeout)) seconds", value: $startupTimeout, in: 1...300)
                    Stepper("Shutdown timeout: \(Int(shutdownTimeout)) seconds", value: $shutdownTimeout, in: 1...60)
                }
                Section("Keychain environment") {
                    ForEach(secretNames, id: \.self) { secret in
                        HStack {
                            Label(secret, systemImage: "key.fill")
                            Spacer()
                            if secretReplacements[secret] != nil {
                                Text(existingSecretReferences[secret] == nil ? "New" : "Replacement")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Button("Remove", role: .destructive) { removeSecret(named: secret) }
                                .buttonStyle(.borderless)
                        }
                    }
                    HStack {
                        TextField("Variable name", text: $secretName)
                        SecureField("New value", text: $secretValue)
                        Button(existingSecretReferences[secretName] == nil ? "Add" : "Replace") {
                            stageSecretInput()
                        }
                        .disabled(secretName.isEmpty || secretValue.isEmpty)
                    }
                    Text("Values remain transient in this form, are written only to Keychain, and are never loaded for display.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Organization") {
                    TextField("Tags (comma separated)", text: $tagsText)
                    Toggle("Favorite", isOn: $isFavorite)
                    Toggle("Launch when DevBerth opens after verification", isOn: $launchesAutomatically)
                }
                if let errorMessage {
                    Section("Action required") { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            HStack {
                if isSaving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save Draft") { Task { await save(.draft) } }
                    .disabled(!canSave || isSaving)
                Button("Test & Save Verified") { Task { await save(.validate) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave || !reviewed || isSaving)
            }
            .padding().background(.bar)
        }
        .frame(width: 720, height: 780)
        .interactiveDismissDisabled(isSaving)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var secretNames: [String] {
        let retainedExisting = Set(existingSecretReferences.keys).subtracting(removedSecretNames)
        return retainedExisting.union(secretReplacements.keys).sorted()
    }

    private var currentTrustSummary: RestartTrustSummary {
        guard let candidate = try? makeConfiguration(references: prospectiveReferences()) else {
            return RestartTrustSummary(
                state: .notRestartable,
                reasons: ["Complete the required launch definition fields."],
                assessedAt: Date(),
                lastValidatedAt: latestValidation?.completedAt
            )
        }
        return RestartTrustEvaluator.summary(for: candidate, validation: latestValidation)
    }

    private var latestValidation: ManagedServiceValidationResult? {
        validationRecords.first { $0.managedServiceID == draftID }?.result
    }

    private func prospectiveReferences() -> [String: UUID] {
        var references = existingSecretReferences.filter { !removedSecretNames.contains($0.key) }
        for name in secretReplacements.keys where references[name] == nil {
            references[name] = UUID()
        }
        return references
    }

    private func stageSecretInput() {
        let normalized = secretName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ManagedEnvironmentParser.isValidVariableName(normalized) else {
            errorMessage = "Enter a valid environment variable name."
            return
        }
        guard !secretValue.isEmpty else { return }
        secretReplacements[normalized] = secretValue
        removedSecretNames.remove(normalized)
        secretName = ""
        secretValue = ""
        errorMessage = nil
    }

    private func removeSecret(named name: String) {
        secretReplacements.removeValue(forKey: name)
        if existingSecretReferences[name] != nil { removedSecretNames.insert(name) }
    }

    @MainActor
    private func save(_ mode: SaveMode) async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        let staged: StagedSecretMutation
        do {
            staged = try await secretLifecycle.stage(
                existingReferences: existingSecretReferences,
                retainedNames: Set(secretNames),
                replacements: secretReplacements
            )
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        var candidate: ManagedServiceConfiguration
        do {
            candidate = try makeConfiguration(references: staged.references)
            let issues = ManagedServiceValidator.validate(candidate).filter { $0.severity == .error }
            guard issues.isEmpty else {
                throw DevBerthError.launchValidation(issues.map(\.message).joined(separator: " "))
            }
        } catch {
            await secretLifecycle.rollback(staged)
            errorMessage = error.localizedDescription
            return
        }

        var validation: ManagedServiceValidationResult?
        if mode == .validate {
            let result = await model.validateManagedService(candidate)
            guard result.succeeded else {
                await secretLifecycle.rollback(staged)
                errorMessage = result.summary
                return
            }
            validation = result
        } else {
            let summary = RestartTrustEvaluator.summary(for: candidate, validation: latestValidation)
            if summary.state != .verifiedRestartable {
                candidate.launchesAutomatically = false
            }
        }

        do {
            try persist(candidate)
        } catch {
            context.rollback()
            await secretLifecycle.rollback(staged)
            errorMessage = error.localizedDescription
            return
        }

        var postSaveError: Error?
        do {
            try await model.recordRestartTrust(for: candidate, validation: validation)
        } catch {
            postSaveError = error
        }
        do {
            try await secretLifecycle.finalize(
                staged,
                referencesStillInUse: referencesStillInUse(including: candidate.secretReferences)
            )
        } catch {
            postSaveError = postSaveError ?? error
        }
        if let postSaveError {
            errorMessage = "The profile was saved safely, but cleanup metadata needs attention: \(postSaveError.localizedDescription)"
        } else {
            dismiss()
        }
    }

    private func makeConfiguration(references: [String: UUID]) throws -> ManagedServiceConfiguration {
        let parsedEnvironment = ManagedEnvironmentParser.parse(environmentText)
        if !parsedEnvironment.sensitiveNames.isEmpty {
            throw DevBerthError.launchValidation(
                "Move secret-like fields to Keychain: \(parsedEnvironment.sensitiveNames.joined(separator: ", "))."
            )
        }
        if !parsedEnvironment.duplicateNames.isEmpty {
            throw DevBerthError.launchValidation(
                "Environment fields must be unique: \(parsedEnvironment.duplicateNames.joined(separator: ", "))."
            )
        }
        if !parsedEnvironment.invalidLines.isEmpty {
            throw DevBerthError.launchValidation(
                "\(parsedEnvironment.invalidLines.count) environment line(s) do not use a valid KEY=value form."
            )
        }
        let ports = try parsedExpectedPorts()
        let trimmedHealthURL = healthURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let healthCheck: HealthCheckConfiguration?
        if trimmedHealthURL.isEmpty {
            healthCheck = nil
        } else {
            guard let url = URL(string: trimmedHealthURL), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                throw DevBerthError.launchValidation("The health-check URL must be an HTTP or HTTPS URL.")
            }
            healthCheck = HealthCheckConfiguration(url: url, expectedStatus: expectedStatus, intervalSeconds: 0.5)
        }
        let shell: ShellSelection = usesLoginShell ? .loginShell(path: shellPath) : .direct
        return ManagedServiceConfiguration(
            id: draftID,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            projectID: record?.projectID,
            launchMechanism: kind,
            command: command.trimmingCharacters(in: .whitespacesAndNewlines),
            arguments: argumentsText.split(whereSeparator: \.isNewline).map(String.init),
            workingDirectory: workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines),
            shell: shell,
            environment: parsedEnvironment.values,
            secretReferences: references,
            expectedPorts: ports,
            startupTimeoutSeconds: startupTimeout,
            shutdownTimeoutSeconds: shutdownTimeout,
            restartPolicy: restartPolicy,
            processPolicy: ManagedServiceProcessPolicy(
                createsDedicatedProcessGroup: true,
                terminationScope: terminationScope
            ),
            healthCheck: healthCheck,
            dependencyServiceIDs: dependencyID.map { [$0] } ?? [],
            logFile: record?.logFile,
            tags: tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) },
            icon: record?.icon,
            launchesAutomatically: launchesAutomatically,
            isFavorite: isFavorite,
            isReviewed: reviewed
        )
    }

    private func parsedExpectedPorts() throws -> [ExpectedListenerConfiguration] {
        let existingByKey = Dictionary(uniqueKeysWithValues: expectedPorts
            .filter { $0.profileID == draftID }
            .map { ("\($0.protocolRawValue):\($0.port)", $0.id) })
        var parsed: [ExpectedListenerConfiguration] = []
        var keys = Set<String>()
        for component in portsText.split(separator: ",", omittingEmptySubsequences: true) {
            let parts = component.trimmingCharacters(in: .whitespaces).split(separator: ":")
            guard parts.count == 2,
                  let port = UInt16(parts[1]),
                  let protocolKind = ListenerProtocol(rawValue: parts[0].uppercased()) else {
                throw DevBerthError.launchValidation("Expected ports must use forms such as tcp:3000 or udp:5353.")
            }
            let key = "\(protocolKind.rawValue):\(port)"
            guard keys.insert(key).inserted else {
                throw DevBerthError.launchValidation("Expected ports must be unique.")
            }
            parsed.append(ExpectedListenerConfiguration(
                id: existingByKey[key] ?? UUID(),
                port: port,
                protocolKind: protocolKind,
                required: true
            ))
        }
        return parsed
    }

    @MainActor
    private func persist(_ candidate: ManagedServiceConfiguration) throws {
        let encoder = JSONEncoder()
        let target = record ?? LaunchProfileRecord(
            id: candidate.id,
            name: candidate.name,
            command: candidate.command,
            workingDirectory: candidate.workingDirectory
        )
        target.projectID = candidate.projectID
        target.name = candidate.name
        target.kindRawValue = candidate.launchMechanism.rawValue
        target.command = candidate.command
        target.argumentsData = try encoder.encode(candidate.arguments)
        target.workingDirectory = candidate.workingDirectory
        target.shellData = try encoder.encode(candidate.shell)
        target.environmentData = try encoder.encode(candidate.environment)
        target.secretReferencesData = try encoder.encode(candidate.secretReferences)
        target.startupTimeoutSeconds = candidate.startupTimeoutSeconds
        target.shutdownTimeoutSeconds = candidate.shutdownTimeoutSeconds
        target.restartPolicyRawValue = candidate.restartPolicy.rawValue
        target.healthCheckData = try candidate.healthCheck.map(encoder.encode)
        target.logFile = candidate.logFile
        target.tagsData = try encoder.encode(candidate.tags)
        target.icon = candidate.icon
        target.isFavorite = candidate.isFavorite
        target.launchesAutomatically = candidate.launchesAutomatically
        target.isReviewed = candidate.isReviewed
        target.updatedAt = Date()
        if record == nil { context.insert(target) }

        expectedPorts.filter { $0.profileID == candidate.id }.forEach(context.delete)
        for port in candidate.expectedPorts {
            context.insert(ExpectedPortRecord(
                id: port.id,
                profileID: candidate.id,
                port: port.port,
                protocolKind: port.protocolKind,
                required: port.required
            ))
        }
        dependencies.filter { $0.profileID == candidate.id }.forEach(context.delete)
        for dependencyID in candidate.dependencyServiceIDs {
            context.insert(ProfileDependencyRecord(
                profileID: candidate.id,
                dependencyProfileID: dependencyID
            ))
        }
        if let storedPolicy = processPolicies.first(where: { $0.managedServiceID == candidate.id }) {
            storedPolicy.createsDedicatedProcessGroup = candidate.processPolicy.createsDedicatedProcessGroup
            storedPolicy.terminationScopeRawValue = candidate.processPolicy.terminationScope.rawValue
            storedPolicy.updatedAt = Date()
        } else {
            context.insert(ManagedServiceProcessPolicyRecord(
                managedServiceID: candidate.id,
                policy: candidate.processPolicy
            ))
        }
        try context.save()
    }

    private func referencesStillInUse(including candidateReferences: [String: UUID]) -> Set<UUID> {
        let decoder = JSONDecoder()
        var references = Set(candidateReferences.values)
        for profile in profiles where profile.id != draftID {
            let stored = (try? decoder.decode([String: UUID].self, from: profile.secretReferencesData)) ?? [:]
            references.formUnion(stored.values)
        }
        return references
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
