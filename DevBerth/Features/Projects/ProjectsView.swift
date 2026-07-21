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
    @Query private var serviceChecks: [ManagedServiceCheckRecord]
    @State private var showsNewProject = false
    @State private var discoveryProject: ProjectRecord?
    @State private var pendingObservedStop: ProjectObservedStopRequest?

    var body: some View {
        Group {
            if projects.isEmpty {
                EmptyStateView(
                    symbol: "folder.badge.plus",
                    title: "No projects yet",
                    message: "Group managed services into a project to start, stop, and inspect related runtime together.",
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
        .sheet(item: $discoveryProject) { project in
            ProjectDiscoveryReviewView(project: project)
                .environmentObject(model)
        }
        .sheet(item: $pendingObservedStop) { request in
            ActionConfirmationSheet(
                title: request.isProject ? Text("Stop observed project services?") : Text("Stop observed service?"),
                message: Text(request.message),
                actionTitle: request.isProject ? Text("Stop All Active Services") : Text("Stop Service"),
                actionRole: .destructive
            ) {
                Task {
                    if request.isProject {
                        await model.stopProject(
                            request.configurations,
                            confirmsObservedProcesses: true
                        )
                    } else if let service = request.configurations.first {
                        await model.stopProfile(service, confirmsObservedProcess: true)
                    }
                }
            }
        }
        .onChange(of: model.requestedProjectImport) { _, requested in
            guard requested else { return }
            model.requestedProjectImport = false
            showsNewProject = true
        }
        .onAppear {
            if model.requestedProjectImport {
                model.requestedProjectImport = false
                showsNewProject = true
            }
        }
    }

    private func projectSection(_ project: ProjectRecord) -> some View {
        let projectProfiles = profiles.filter { $0.projectID == project.id }
        let configurations = projectProfiles.compactMap {
            $0.configuration(
                dependencies: dependencies,
                expectedPorts: expectedPorts,
                processPolicies: processPolicies,
                serviceChecks: serviceChecks
            )
        }
        let activities = configurations.reduce(into: [UUID: ManagedServiceActivityEvidence]()) { values, configuration in
            values[configuration.id] = model.managedServiceActivity(for: configuration)
        }
        let startableCount = activities.values.filter { $0.state == .stopped }.count
        let stoppableCount = activities.values.filter { $0.state != .stopped }.count
        let operation = model.projectOperations[project.id]
        let projectIsBusy = operation?.isRunning == true
        return Section {
            if projectProfiles.isEmpty {
                Text("Add an existing managed service to orchestrate this project.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ForEach(projectProfiles) { profile in
                    let configuration = configurations.first { $0.id == profile.id }
                    let activity = activities[profile.id]
                    let serviceOperation = model.serviceOperations[profile.id]
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            StatusDot(status: visualStatus(for: profile.id, activity: activity))
                            Image(systemName: "play.square")
                            Text(profile.name).font(.headline)
                            Spacer()
                            ForEach(expectedPorts.filter { $0.profileID == profile.id }) { port in
                                Text(":\(port.port)")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            if let serviceOperation, serviceOperation.isRunning {
                                ProgressView()
                                    .controlSize(.small)
                                Text(serviceOperation.kind == .stop ? "Stopping…" : "Starting…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else if let configuration, let activity {
                                switch activity.state {
                                case .controlled:
                                    Button("Stop") { Task { await model.stopProfile(configuration) } }
                                        .disabled(projectIsBusy)
                                case .observed:
                                    Button("Stop") {
                                        pendingObservedStop = ProjectObservedStopRequest(
                                            configurations: [configuration],
                                            isProject: false,
                                            observedServiceCount: 1
                                        )
                                    }
                                    .disabled(projectIsBusy)
                                    .help("Stop the exact observed owner after confirmation and fresh identity validation.")
                                    Button("Inspect") { model.inspectObservedRuntime(for: configuration) }
                                case .stopped:
                                    Button("Start") { Task { await model.launchProfile(configuration) } }
                                        .disabled(projectIsBusy)
                                }
                            }
                            Button("Remove from Project") {
                                profile.projectID = nil
                                try? context.save()
                            }
                        }
                        .buttonStyle(.borderless)
                        HStack(spacing: DevBerthSpacing.medium) {
                            if let configuration, !configuration.dependencyServiceIDs.isEmpty {
                                Label(
                                    "Depends on \(configuration.dependencyServiceIDs.map { serviceName($0, in: projectProfiles) }.joined(separator: ", "))",
                                    systemImage: "arrow.triangle.branch"
                                )
                            } else {
                                Label("No dependencies", systemImage: "circle")
                            }
                            if let status = model.runtimeStatuses[profile.id] {
                                Label(
                                    "\(humanized(status.lifecycleState.rawValue)) · \(humanized(status.healthState.rawValue))",
                                    systemImage: "waveform.path.ecg"
                                )
                            } else if let activity, activity.state == .observed {
                                Label(observedStatusText(activity), systemImage: "eye")
                            }
                            if let docker = model.listeners.first(where: { listener in
                                (listener.process.managedServiceID == profile.id
                                    || activity?.matchingListenerIDs.contains(listener.id) == true)
                                    && listener.process.docker != nil
                            })?.process.docker {
                                Label(docker.composeService ?? docker.containerName, systemImage: "shippingbox.fill")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        if let failure = model.profileFailures[profile.id] ?? model.runtimeIncidents[profile.id]?.cause {
                            Label(failure, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                        } else if let serviceOperation, !serviceOperation.isRunning {
                            Label(
                                serviceOperation.message,
                                systemImage: serviceOperation.phase == .succeeded
                                    ? "checkmark.circle.fill"
                                    : "xmark.octagon.fill"
                            )
                            .font(.caption)
                            .foregroundStyle(serviceOperation.phase == .succeeded ? .green : .red)
                        }
                    }
                    .padding(.vertical, 4)
                }
                if !configurations.isEmpty {
                    projectTopology(configurations)
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
                    Button {
                        Task { await model.startProject(configurations) }
                    } label: {
                        Label(
                            operation?.isRunning == true && operation?.kind == .start
                                ? "Starting…"
                                : "Start All",
                            systemImage: "play.fill"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(configurations.isEmpty || projectIsBusy)
                    .help(startableCount == 0
                        ? "Every service is already active or externally observed."
                        : "Start \(startableCount) stopped service(s) in dependency order.")

                    Button {
                        let observedCount = activities.values.filter { $0.state == .observed }.count
                        if observedCount > 0 {
                            pendingObservedStop = ProjectObservedStopRequest(
                                configurations: configurations,
                                isProject: true,
                                observedServiceCount: observedCount
                            )
                        } else {
                            Task { await model.stopProject(configurations) }
                        }
                    } label: {
                        Label(
                            operation?.isRunning == true && operation?.kind == .stop
                                ? "Stopping…"
                                : "Stop All",
                            systemImage: "stop.fill"
                        )
                    }
                    .disabled(configurations.isEmpty || projectIsBusy)
                    .help(stoppableCount == 0
                        ? "All project services are already stopped."
                        : "Stop \(stoppableCount) active service(s) in reverse dependency order.")
                    Button("Discover Services", systemImage: "sparkle.magnifyingglass") {
                        discoveryProject = project
                    }
                    .disabled(project.folderPath == nil)
                    Button("Export Manifest", systemImage: "square.and.arrow.up") {
                        exportManifest(for: project, configurations: configurations)
                    }
                    .disabled(project.folderPath == nil || configurations.isEmpty)
                    Menu("Add Service", systemImage: "plus") {
                        let available = profiles.filter { $0.projectID == nil }
                        if available.isEmpty { Text("No unassigned managed services") }
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
                    let active = activities.values.filter(\.isActive).count
                    ProgressView(value: Double(active), total: Double(configurations.count)) {
                        Text("\(active) of \(configurations.count) services active").font(.caption)
                    }
                }
                if let operation {
                    projectOperationBanner(operation)
                }
            }
            .textCase(nil)
            .padding(.top, DevBerthSpacing.small)
        }
    }

    private func projectOperationBanner(_ operation: ProjectOperationStatus) -> some View {
        let color = projectOperationColor(operation.phase)
        return HStack(spacing: DevBerthSpacing.medium) {
            if operation.isRunning {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: operation.phase == .succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: DevBerthSpacing.xSmall) {
                Text(operation.message)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(operation.phase == .failed ? color : .primary)
                if operation.isRunning {
                    ProgressView(
                        value: operation.fractionCompleted,
                        total: 1
                    )
                    .tint(color)
                }
            }
            Spacer(minLength: DevBerthSpacing.small)
            if operation.isRunning {
                Text("\(operation.completedServiceCount) / \(operation.totalServiceCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Button("Dismiss Status", systemImage: "xmark.circle.fill") {
                    model.dismissProjectOperation(operation.projectID)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(DevBerthSpacing.medium)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(color.opacity(0.28))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(operation.message)
    }

    private func projectOperationColor(_ phase: ProjectOperationPhase) -> Color {
        switch phase {
        case .running: .accentColor
        case .succeeded: .green
        case .failed: .red
        }
    }

    @ViewBuilder
    private func projectTopology(_ configurations: [ManagedServiceConfiguration]) -> some View {
        DisclosureGroup {
            if let layers = try? DependencyPlanner.orderedLayers(for: configurations) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(layers.enumerated()), id: \.offset) { index, layer in
                        LabeledContent("Startup layer \(index + 1)") {
                            Text(layer.map(\.name).joined(separator: ", "))
                        }
                    }
                    Text("Services in the same layer can start in parallel. Stop All uses the reverse order.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            } else {
                Label(
                    "The dependency graph is incomplete or cyclic. Project start and session restore will remain blocked.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.red)
                .padding(.vertical, 6)
            }
        } label: {
            Label("Startup topology", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.headline)
        }
    }

    private func serviceName(_ id: UUID, in projectProfiles: [LaunchProfileRecord]) -> String {
        projectProfiles.first { $0.id == id }?.name ?? "Missing service"
    }

    private func humanized(_ value: String) -> String {
        value.replacingOccurrences(
            of: "([a-z])([A-Z])",
            with: "$1 $2",
            options: .regularExpression
        ).capitalized
    }

    private func openInTerminal(_ path: String) {
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: terminal, configuration: configuration)
    }

    private func exportManifest(
        for project: ProjectRecord,
        configurations: [ManagedServiceConfiguration]
    ) {
        guard let rootPath = project.folderPath else { return }
        let panel = NSSavePanel()
        panel.title = "Export DevBerth Project Manifest"
        panel.nameFieldStringValue = DevBerthManifestCodec.fileName
        panel.directoryURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task {
            await model.exportProjectManifest(
                projectName: project.name,
                rootPath: rootPath,
                services: configurations,
                destination: destination
            )
        }
    }

    private func visualStatus(
        for profileID: UUID,
        activity: ManagedServiceActivityEvidence?
    ) -> StatusDot.Status {
        guard let status = model.runtimeStatuses[profileID] else {
            switch activity?.state {
            case .controlled: return .healthy
            case .observed: return .warning
            case .stopped, nil: return .stopped
            }
        }
        if status.lifecycleState == .failed || status.healthState == .unhealthy { return .failed }
        if status.healthState == .degraded { return .warning }
        if status.lifecycleState == .starting
            || status.lifecycleState == .waitingForDependency
            || status.lifecycleState == .waitingForPort
            || status.lifecycleState == .waitingForReadiness { return .warning }
        return status.processRunning ? .healthy : .stopped
    }

    private func observedStatusText(_ activity: ManagedServiceActivityEvidence) -> String {
        if activity.expectedPortCount <= 1 {
            return String(localized: "Observed on expected port")
        }
        return String(
            localized: "Observed on \(activity.openExpectedPortCount) of \(activity.expectedPortCount) expected ports"
        )
    }
}

private struct ProjectObservedStopRequest: Identifiable {
    let id = UUID()
    let configurations: [ManagedServiceConfiguration]
    let isProject: Bool
    let observedServiceCount: Int

    var message: String {
        let scope = isProject
            ? "This includes \(observedServiceCount) service(s) running outside DevBerth."
            : "This service is running outside DevBerth."
        return "\(scope) DevBerth will revalidate each exact process, container, or Compose owner immediately before stopping it. A user-owned process that ignores graceful shutdown will be revalidated again before force stop. Protected or unverifiable owners will remain running."
    }
}

private struct ProjectDiscoveryReviewView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var existingProfiles: [LaunchProfileRecord]
    let project: ProjectRecord
    @State private var report: ProjectDiscoveryReport?
    @State private var selectedCandidateIDs = Set<UUID>()
    @State private var isDiscovering = true
    @State private var isImporting = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Discover Services").font(.title2.bold())
                    Text(project.folderPath ?? "No project folder selected")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("Close", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isImporting)
            }
            .padding()

            Divider()

            if isDiscovering {
                ProgressView("Inspecting only the selected project root…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let report {
                discoveryContent(report)
            } else {
                ContentUnavailableView(
                    "Discovery unavailable",
                    systemImage: "exclamationmark.magnifyingglass",
                    description: Text(message ?? "DevBerth could not inspect this project.")
                )
            }
        }
        .frame(minWidth: 760, minHeight: 600)
        .task { await discover() }
        .onExitCommand {
            if !isImporting { dismiss() }
        }
    }

    @ViewBuilder
    private func discoveryContent(_ report: ProjectDiscoveryReport) -> some View {
        if report.findings.isEmpty {
            ContentUnavailableView(
                "No supported project definitions found",
                systemImage: "doc.text.magnifyingglass",
                description: Text("DevBerth checked the selected folder only. It did not recurse into nested projects or execute project files.")
            )
        } else {
            VStack(spacing: 0) {
                HStack {
                    Label(report.recognizedProjectTypes.joined(separator: ", "), systemImage: "checkmark.seal")
                    Spacer()
                    Text("\(report.candidates.count) candidate\(report.candidates.count == 1 ? "" : "s")")
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(.quaternary.opacity(0.35))

                List {
                    Section {
                        Label(
                            "Detection never runs commands or changes project files. Imported services remain unreviewed and cannot launch until you review and validate them.",
                            systemImage: "hand.raised.fill"
                        )
                        .foregroundStyle(.orange)
                    }
                    ForEach(report.findings) { finding in
                        Section(finding.projectType) {
                            ForEach(finding.candidates) { candidate in
                                candidateRow(candidate)
                            }
                            if finding.candidates.isEmpty {
                                ForEach(finding.evidence) { evidence in
                                    Label(evidence.detail, systemImage: "doc.text.magnifyingglass")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Divider()
                HStack {
                    if let message {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Select All") {
                        selectedCandidateIDs = Set(importableCandidates(in: report).map(\.id))
                    }
                    Button("Import Selected") { importSelected(from: report) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(selectedCandidateIDs.isEmpty || isImporting)
                }
                .padding()
                .background(.bar)
            }
        }
    }

    private func candidateRow(_ candidate: DiscoveredServiceCandidate) -> some View {
        let alreadyImported = existingProfiles.contains { $0.id == candidate.id }
        return HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: Binding(
                get: { selectedCandidateIDs.contains(candidate.id) },
                set: { selected in
                    if selected { selectedCandidateIDs.insert(candidate.id) }
                    else { selectedCandidateIDs.remove(candidate.id) }
                }
            ))
            .labelsHidden()
            .disabled(alreadyImported)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(candidate.name).font(.headline)
                    Text(candidate.launchMechanism.title)
                        .font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                    if candidate.requiresShellReview {
                        Label("Shell review", systemImage: "exclamationmark.shield")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if alreadyImported { Text("Already imported").font(.caption).foregroundStyle(.secondary) }
                }
                Text(([candidate.command] + candidate.arguments).joined(separator: " "))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                HStack(spacing: 14) {
                    Text(candidate.confidence.title)
                    if !candidate.expectedPorts.isEmpty {
                        Text("Ports \(candidate.expectedPorts.map(String.init).joined(separator: ", "))")
                    }
                    if !candidate.dependencyCandidateNames.isEmpty {
                        Text("Depends on \(candidate.dependencyCandidateNames.joined(separator: ", "))")
                    }
                    if !candidate.requiredSecretNames.isEmpty {
                        Text("Needs Keychain values for \(candidate.requiredSecretNames.joined(separator: ", "))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(candidate.evidence.map(\.detail).joined(separator: " "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
    }

    private func discover() async {
        guard let folderPath = project.folderPath else {
            message = "Choose a project folder before discovery."
            isDiscovering = false
            return
        }
        do {
            let discovered = try await model.discoverProject(at: folderPath)
            report = discovered
            selectedCandidateIDs = Set(importableCandidates(in: discovered).map(\.id))
        } catch {
            message = error.localizedDescription
        }
        isDiscovering = false
    }

    @MainActor
    private func importSelected(from report: ProjectDiscoveryReport) {
        isImporting = true
        defer { isImporting = false }
        let candidates = importableCandidates(in: report).filter { selectedCandidateIDs.contains($0.id) }
        do {
            let result = try ProjectDiscoveryImporter.importCandidates(
                candidates,
                report: report,
                projectID: project.id,
                into: context
            )
            selectedCandidateIDs.subtract(result.importedServiceIDs)
            if result.unresolvedDependencies.isEmpty {
                message = "Imported \(result.importedServiceIDs.count) unreviewed service candidate(s). Review them in Managed Services."
            } else {
                message = "Imported \(result.importedServiceIDs.count) candidate(s). Reconnect unresolved dependencies: \(result.unresolvedDependencies.joined(separator: ", "))."
            }
        } catch {
            message = "Nothing was imported: \(error.localizedDescription)"
        }
    }

    private func importableCandidates(in report: ProjectDiscoveryReport) -> [DiscoveredServiceCandidate] {
        let existingIDs = Set(existingProfiles.map(\.id))
        return report.candidates.filter { !existingIDs.contains($0.id) }
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
                    .keyboardShortcut(.cancelAction)
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
        .onExitCommand { dismiss() }
    }
}
