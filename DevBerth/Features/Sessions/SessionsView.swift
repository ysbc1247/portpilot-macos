import SwiftData
import SwiftUI

struct SessionsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.modelContext) private var context
    @Query(sort: \WorkspaceSessionRecord.capturedAt, order: .reverse)
    private var sessionRecords: [WorkspaceSessionRecord]
    @Query private var snapshotRecords: [WorkspaceSessionServiceRecord]
    @Query(sort: \SessionRestoreRecord.finishedAt, order: .reverse)
    private var restoreRecords: [SessionRestoreRecord]
    @Query(sort: \ProjectRecord.name) private var projects: [ProjectRecord]
    @Query(sort: \LaunchProfileRecord.name) private var profiles: [LaunchProfileRecord]
    @Query private var dependencies: [ProfileDependencyRecord]
    @Query private var expectedPorts: [ExpectedPortRecord]
    @Query private var processPolicies: [ManagedServiceProcessPolicyRecord]
    @Query private var serviceChecks: [ManagedServiceCheckRecord]

    @State private var selectedSessionID: UUID?
    @State private var comparison: WorkspaceSessionComparison?
    @State private var isComparing = false
    @State private var showsCapture = false
    @State private var restoreSession: WorkspaceSession?
    @State private var deletionRecord: WorkspaceSessionRecord?

    private var configurations: [ManagedServiceConfiguration] {
        profiles.compactMap {
            $0.configuration(
                dependencies: dependencies,
                expectedPorts: expectedPorts,
                processPolicies: processPolicies,
                serviceChecks: serviceChecks
            )
        }
    }

    private var selectedRecord: WorkspaceSessionRecord? {
        sessionRecords.first { $0.id == selectedSessionID }
    }

    private var selectedSession: WorkspaceSession? {
        selectedRecord?.session(serviceRecords: snapshotRecords)
    }

    var body: some View {
        Group {
            if sessionRecords.isEmpty {
                EmptyStateView(
                    symbol: "square.stack.3d.up.badge.plus",
                    title: "No workspace sessions",
                    message: "Capture selected projects and their managed-service state so you can review drift and restore safely.",
                    actionTitle: "Capture Session",
                    action: { showsCapture = true }
                )
            } else {
                HSplitView {
                    sessionList
                        .frame(minWidth: 250, idealWidth: 290, maxWidth: 340)
                    Group {
                        if let session = selectedSession {
                            sessionDetail(session)
                        } else if selectedRecord != nil {
                            ContentUnavailableView(
                                "Session data unavailable",
                                systemImage: "exclamationmark.triangle",
                                description: Text("One or more saved service snapshots could not be decoded. DevBerth will not restore a partial session.")
                            )
                        } else {
                            ContentUnavailableView(
                                "Select a session",
                                systemImage: "square.stack.3d.up",
                                description: Text("Review its saved state, current drift, and restore history.")
                            )
                        }
                    }
                    .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle("Sessions")
        .toolbar {
            Button("Capture Session", systemImage: "camera") { showsCapture = true }
        }
        .sheet(isPresented: $showsCapture) {
            SessionCaptureView(projects: projects, services: configurations)
                .environmentObject(model)
        }
        .sheet(item: $restoreSession) { session in
            SessionRestorePreviewView(session: session, services: configurations)
                .environmentObject(model)
        }
        .alert(
            "Delete workspace session?",
            isPresented: Binding(
                get: { deletionRecord != nil },
                set: { if !$0 { deletionRecord = nil } }
            ),
            presenting: deletionRecord
        ) { record in
            Button("Cancel", role: .cancel) { deletionRecord = nil }
            Button("Delete", role: .destructive) {
                deleteSession(record)
                deletionRecord = nil
            }
        } message: { record in
            Text("\(record.name) and its restore results will be removed. Lifecycle audit events remain in bounded history.")
        }
        .onAppear { selectFirstSessionIfNeeded() }
        .onChange(of: sessionRecords.map(\.id)) { _, _ in selectFirstSessionIfNeeded() }
        .onChange(of: selectedSessionID) { _, _ in refreshComparison() }
    }

    private var sessionList: some View {
        List(selection: $selectedSessionID) {
            ForEach(sessionRecords) { record in
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.name).font(.headline)
                    Text(record.capturedAt, format: .dateTime.year().month().day().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    let snapshotCount = snapshotRecords.filter { $0.sessionID == record.id }.count
                    Text("\(snapshotCount) managed service\(snapshotCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .tag(record.id)
                .contextMenu {
                    Button("Delete Session", role: .destructive) { deletionRecord = record }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func sessionDetail(_ session: WorkspaceSession) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DevBerthSpacing.large) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(session.name).font(.largeTitle.bold())
                        Text("Captured \(session.capturedAt.formatted(date: .abbreviated, time: .shortened))")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Refresh Comparison", systemImage: "arrow.clockwise") { refreshComparison() }
                        .disabled(isComparing)
                    Button("Preview Restore", systemImage: "play.circle.fill") { restoreSession = session }
                        .buttonStyle(.borderedProminent)
                }

                if let notes = session.notes {
                    GroupBox("Notes") { Text(notes).frame(maxWidth: .infinity, alignment: .leading) }
                }

                GroupBox("Captured scope") {
                    VStack(spacing: 9) {
                        InspectorRow(title: "Projects", value: projectNames(for: session).joined(separator: ", "))
                        InspectorRow(title: "Expected running", value: String(session.serviceSnapshots.filter { $0.expectedState == .running }.count))
                        InspectorRow(title: "Expected stopped", value: String(session.serviceSnapshots.filter { $0.expectedState == .stopped }.count))
                    }
                    .padding(.vertical, 4)
                }

                savedServices(session)
                comparisonSection
                restoreHistory(session)

                HStack {
                    Spacer()
                    Button("Delete Session", role: .destructive) {
                        guard let record = selectedRecord else { return }
                        deletionRecord = record
                    }
                }
            }
            .padding(DevBerthSpacing.xLarge)
        }
        .task(id: session.id) { await loadComparison(for: session) }
    }

    private func savedServices(_ session: WorkspaceSession) -> some View {
        GroupBox("Expected managed services") {
            VStack(spacing: 0) {
                ForEach(session.serviceSnapshots) { snapshot in
                    HStack(spacing: DevBerthSpacing.medium) {
                        StatusDot(status: snapshot.expectedState == .running ? .healthy : .stopped)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(serviceName(snapshot.managedServiceID)).font(.headline)
                            HStack(spacing: 6) {
                                Text(snapshot.expectedState == .running ? "Expected running" : "Expected stopped")
                                if !snapshot.dependencyServiceIDs.isEmpty {
                                    Text("Depends on \(snapshot.dependencyServiceIDs.map(serviceName).joined(separator: ", "))")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        ForEach(snapshot.expectedListeners) { listener in PortBadge(port: listener.port) }
                        Text(snapshot.previousHealthState.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 9)
                    if snapshot.id != session.serviceSnapshots.last?.id { Divider() }
                }
            }
            .padding(.horizontal, 4)
        }
    }

    @ViewBuilder
    private var comparisonSection: some View {
        GroupBox("Current drift") {
            if isComparing {
                ProgressView("Comparing with the current runtime…")
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let comparison, comparison.changeCount > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    comparisonRows(comparison)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if comparison != nil {
                Label("No saved-state drift detected.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Comparison unavailable.").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func comparisonRows(_ comparison: WorkspaceSessionComparison) -> some View {
        if !comparison.addedServiceIDs.isEmpty {
            driftRow("Added services", values: comparison.addedServiceIDs.map(serviceName), symbol: "plus.circle")
        }
        if !comparison.missingServiceIDs.isEmpty {
            driftRow("Missing services", values: comparison.missingServiceIDs.map(serviceName), symbol: "minus.circle")
        }
        if !comparison.configurationDriftServiceIDs.isEmpty {
            driftRow("Changed definitions", values: comparison.configurationDriftServiceIDs.map(serviceName), symbol: "slider.horizontal.3")
        }
        ForEach(comparison.portChanges) { change in
            driftRow(
                "Changed ports — \(change.serviceName)",
                values: ["\(ports(change.savedPorts)) → \(ports(change.currentPorts))"],
                symbol: "arrow.left.arrow.right"
            )
        }
        ForEach(comparison.healthChanges) { change in
            driftRow(
                "Changed health — \(change.serviceName)",
                values: ["\(change.saved.title) → \(change.current.title)"],
                symbol: "waveform.path.ecg"
            )
        }
        if !comparison.unexpectedListeners.isEmpty {
            driftRow(
                "Unexpected project listeners",
                values: comparison.unexpectedListeners.map { "\($0.process.name) :\($0.port)" },
                symbol: "exclamationmark.triangle"
            )
        }
    }

    private func driftRow(_ title: String, values: [String], symbol: String) -> some View {
        HStack(alignment: .top) {
            Label(title, systemImage: symbol).font(.headline)
            Spacer()
            Text(values.joined(separator: ", "))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func restoreHistory(_ session: WorkspaceSession) -> some View {
        let results = restoreRecords.filter { $0.sessionID == session.id }.compactMap(\.result)
        return GroupBox("Restore history") {
            if results.isEmpty {
                Text("This session has not been restored yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 0) {
                    ForEach(results) { result in
                        HStack {
                            Label(result.outcome.title, systemImage: result.outcome.symbol)
                            Spacer()
                            Text(result.finishedAt, format: .dateTime.month().day().hour().minute())
                                .foregroundStyle(.secondary)
                            Text("\(result.startedServiceIDs.count) started")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 7)
                    }
                }
            }
        }
    }

    private func selectFirstSessionIfNeeded() {
        if let selectedSessionID, sessionRecords.contains(where: { $0.id == selectedSessionID }) { return }
        selectedSessionID = sessionRecords.first?.id
    }

    private func refreshComparison() {
        guard let session = selectedSession else { comparison = nil; return }
        Task { await loadComparison(for: session) }
    }

    @MainActor
    private func loadComparison(for session: WorkspaceSession) async {
        isComparing = true
        comparison = await model.compareWorkspaceSession(
            session,
            services: configurations,
            projectRootPaths: Set(projects.filter { session.projectIDs.contains($0.id) }.compactMap(\.folderPath))
        )
        isComparing = false
    }

    private func deleteSession(_ record: WorkspaceSessionRecord) {
        snapshotRecords.filter { $0.sessionID == record.id }.forEach(context.delete)
        restoreRecords.filter { $0.sessionID == record.id }.forEach(context.delete)
        context.delete(record)
        do {
            try context.save()
            if selectedSessionID == record.id { selectedSessionID = nil }
        } catch {
            model.presentedError = .unexpected("The workspace session could not be deleted: \(error.localizedDescription)")
        }
    }

    private func projectNames(for session: WorkspaceSession) -> [String] {
        let names = session.projectIDs.map { id in projects.first { $0.id == id }?.name ?? "Missing project" }
        return names.isEmpty ? ["No projects"] : names
    }

    private func serviceName(_ id: UUID) -> String {
        profiles.first { $0.id == id }?.name ?? "Missing service"
    }

    private func ports(_ values: Set<UInt16>) -> String {
        values.isEmpty ? "none" : values.sorted().map(String.init).joined(separator: ", ")
    }
}

private struct SessionCaptureView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let projects: [ProjectRecord]
    let services: [ManagedServiceConfiguration]

    @State private var name = ""
    @State private var notes = ""
    @State private var selectedProjectIDs = Set<UUID>()
    @State private var isCapturing = false

    var body: some View {
        VStack(alignment: .leading, spacing: DevBerthSpacing.large) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Capture Workspace Session").font(.title2.bold())
                Text("Only managed services are saved. Unmanaged processes remain visible as comparison evidence, never as restorable definitions.")
                    .foregroundStyle(.secondary)
            }

            Form {
                TextField("Session name", text: $name)
                Section("Projects") {
                    if projects.isEmpty {
                        Text("Create a project and assign managed services before capturing a session.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(projects) { project in
                        Toggle(isOn: selectionBinding(for: project.id)) {
                            VStack(alignment: .leading) {
                                Text(project.name)
                                let count = services.filter { $0.projectID == project.id }.count
                                Text("\(count) managed service\(count == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Optional notes") {
                    TextEditor(text: $notes).frame(minHeight: 90)
                }
            }
            .formStyle(.grouped)

            HStack {
                Text("\(selectedServices.count) services will be captured")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Capture") { capture() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isCapturing || trimmedName.isEmpty || selectedProjectIDs.isEmpty || selectedServices.isEmpty)
            }
        }
        .padding(DevBerthSpacing.xLarge)
        .frame(width: 620, height: 590)
        .onAppear {
            selectedProjectIDs = Set(projects.filter { project in
                services.contains { $0.projectID == project.id }
            }.map(\.id))
            if name.isEmpty { name = "Workspace \(Date().formatted(date: .abbreviated, time: .omitted))" }
        }
    }

    private var selectedServices: [ManagedServiceConfiguration] {
        services.filter { $0.projectID.map(selectedProjectIDs.contains) ?? false }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func selectionBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedProjectIDs.contains(id) },
            set: { selected in
                if selected { selectedProjectIDs.insert(id) } else { selectedProjectIDs.remove(id) }
            }
        )
    }

    private func capture() {
        isCapturing = true
        Task {
            let chosenProjects = projects.filter { selectedProjectIDs.contains($0.id) }
            let captured = await model.captureWorkspaceSession(
                name: trimmedName,
                projectIDs: chosenProjects.map(\.id),
                services: services,
                projectRootPaths: Set(chosenProjects.compactMap(\.folderPath)),
                notes: notes
            )
            isCapturing = false
            if captured != nil { dismiss() }
        }
    }
}

private struct SessionRestorePreviewView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let session: WorkspaceSession
    let services: [ManagedServiceConfiguration]

    @State private var plan: SessionRestorePlan?
    @State private var result: SessionRestoreResult?
    @State private var isLoading = true
    @State private var isExecuting = false
    @State private var dryRun = false
    @State private var rollbackOnFailure = true
    @State private var applyExpectedStoppedState = false
    @State private var confirmedIssueIDs = Set<String>()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Restore Preview").font(.title2.bold())
                    Text(session.name).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }
            }
            .padding()
            Divider()

            if isLoading {
                ProgressView("Revalidating runtime, ports, definitions, and dependencies…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let plan {
                previewContent(plan)
            } else {
                ContentUnavailableView(
                    "Restore preview unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text("No changes were made. Review the reported error and try again.")
                )
            }
        }
        .frame(minWidth: 820, minHeight: 680)
        .task { await loadPlan() }
    }

    private func previewContent(_ plan: SessionRestorePlan) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: DevBerthSpacing.large) {
                    HStack(spacing: DevBerthSpacing.large) {
                        metric("Estimated actions", value: plan.estimatedMutationCount, symbol: "bolt")
                        metric("Starts", value: plan.actions.filter { $0.kind == .start }.count, symbol: "play.fill")
                        metric("Already running", value: plan.actions.filter { $0.kind == .alreadyRunning }.count, symbol: "checkmark.circle")
                        metric("Issues", value: plan.issues.count, symbol: "exclamationmark.triangle")
                    }

                    if let result {
                        GroupBox("Latest result") {
                            VStack(alignment: .leading, spacing: 6) {
                                Label(result.outcome.title, systemImage: result.outcome.symbol).font(.headline)
                                Text("\(result.startedServiceIDs.count) started · \(result.rolledBackServiceIDs.count) rolled back")
                                ForEach(result.errors, id: \.self) { Text($0).foregroundStyle(.secondary) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    GroupBox("Actions") {
                        VStack(spacing: 0) {
                            ForEach(plan.actions) { action in
                                HStack(alignment: .top) {
                                    Label(action.kind.title, systemImage: action.kind.symbol)
                                        .frame(width: 220, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(action.serviceName).font(.headline)
                                        Text(action.reason).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if !action.expectedPorts.isEmpty {
                                        Text(action.expectedPorts.map(String.init).joined(separator: ", "))
                                            .font(.system(.caption, design: .monospaced))
                                    }
                                }
                                .padding(.vertical, 8)
                                Divider()
                            }
                        }
                    }

                    GroupBox("Dependency startup order") {
                        if plan.orderedStartLayers.isEmpty {
                            Text("No managed services need to start.").foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(plan.orderedStartLayers.enumerated()), id: \.offset) { index, layer in
                                    LabeledContent("Layer \(index + 1)") {
                                        Text(layer.map(serviceName).joined(separator: ", "))
                                    }
                                }
                                Text("Services in one layer start in parallel. A later layer begins only after the prior layer is ready.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if !plan.issues.isEmpty {
                        GroupBox("Preflight issues") {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(plan.issues) { issue in
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack(alignment: .top) {
                                            Label(issue.summary, systemImage: issue.severity.symbol)
                                                .foregroundStyle(issue.severity.color)
                                            Spacer()
                                            Text(issue.severity.title).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Text(issue.recoverySuggestion).font(.caption).foregroundStyle(.secondary)
                                        if issue.severity == .confirmationRequired {
                                            Toggle("I reviewed and accept this change", isOn: confirmationBinding(issue.id))
                                                .toggleStyle(.checkbox)
                                        }
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    GroupBox("Execution options") {
                        VStack(alignment: .leading, spacing: 9) {
                            Toggle("Dry run — record the preview without starting or stopping anything", isOn: $dryRun)
                            Toggle("Roll back services started by this restore if a later action fails", isOn: $rollbackOnFailure)
                                .disabled(dryRun)
                            Toggle("Stop currently running services that the saved session expects stopped", isOn: $applyExpectedStoppedState)
                                .disabled(dryRun || !plan.actions.contains { $0.kind == .stop })
                            Text("DevBerth never stops unmanaged processes as part of session restoration.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(DevBerthSpacing.xLarge)
            }
            Divider()
            HStack {
                if !dryRun, !plan.blockingIssues.isEmpty {
                    Label("Resolve \(plan.blockingIssues.count) blocking issue(s) before restoring.", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Spacer()
                Button("Re-run Preview") { Task { await loadPlan() } }.disabled(isExecuting)
                Button(dryRun ? "Run Dry Preview" : "Restore Session") { execute() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isExecuting || (!dryRun && (!plan.blockingIssues.isEmpty || hasUnconfirmedIssues(plan))))
            }
            .padding()
        }
    }

    private func metric(_ title: String, value: Int, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value, format: .number).font(.title2.bold()).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func serviceName(_ id: UUID) -> String {
        services.first { $0.id == id }?.name ?? "Missing service"
    }

    private func confirmationBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { confirmedIssueIDs.contains(id) },
            set: { confirmed in
                if confirmed { confirmedIssueIDs.insert(id) } else { confirmedIssueIDs.remove(id) }
            }
        )
    }

    private func hasUnconfirmedIssues(_ plan: SessionRestorePlan) -> Bool {
        plan.confirmationIssues.contains { !confirmedIssueIDs.contains($0.id) }
    }

    @MainActor
    private func loadPlan() async {
        isLoading = true
        do {
            plan = try await model.previewWorkspaceSession(session, services: services)
            if let plan {
                confirmedIssueIDs.formIntersection(Set(plan.confirmationIssues.map(\.id)))
            }
        } catch {
            model.presentedError = .unexpected("The restore preview could not be prepared: \(error.localizedDescription)")
            plan = nil
        }
        isLoading = false
    }

    private func execute() {
        isExecuting = true
        Task {
            let execution = await model.restoreWorkspaceSession(
                session,
                services: services,
                options: SessionRestoreOptions(
                    dryRun: dryRun,
                    rollbackStartedServicesOnFailure: rollbackOnFailure,
                    applyExpectedStoppedState: applyExpectedStoppedState,
                    confirmedIssueIDs: confirmedIssueIDs
                )
            )
            result = execution?.result
            isExecuting = false
            if execution != nil, !dryRun { await loadPlan() }
        }
    }
}

private extension RuntimeHealthState {
    var title: String {
        rawValue.replacingOccurrences(
            of: "([a-z])([A-Z])",
            with: "$1 $2",
            options: .regularExpression
        ).capitalized
    }
}

private extension SessionRestoreOutcome {
    var title: String {
        switch self {
        case .succeeded: "Succeeded"
        case .partiallySucceeded: "Partially succeeded"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .dryRun: "Dry run"
        }
    }

    var symbol: String {
        switch self {
        case .succeeded: "checkmark.circle.fill"
        case .partiallySucceeded: "exclamationmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .cancelled: "stop.circle.fill"
        case .dryRun: "eye.circle.fill"
        }
    }
}

private extension SessionRestoreActionKind {
    var symbol: String {
        switch self {
        case .start: "play.fill"
        case .alreadyRunning: "checkmark.circle.fill"
        case .stop: "stop.fill"
        case .alreadyStopped: "pause.circle"
        case .missing: "questionmark.diamond.fill"
        }
    }
}

private extension SessionRestoreIssueSeverity {
    var title: String {
        switch self {
        case .warning: "Warning"
        case .confirmationRequired: "Confirmation required"
        case .blocking: "Blocking"
        }
    }

    var symbol: String {
        switch self {
        case .warning: "exclamationmark.triangle"
        case .confirmationRequired: "checkmark.shield"
        case .blocking: "lock.fill"
        }
    }

    var color: Color {
        switch self {
        case .warning: .orange
        case .confirmationRequired: .blue
        case .blocking: .red
        }
    }
}
