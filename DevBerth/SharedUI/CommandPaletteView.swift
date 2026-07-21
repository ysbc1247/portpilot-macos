import AppKit
import SwiftData
import SwiftUI

struct CommandPaletteView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var isPresented: Bool
    @State private var query = ""
    @State private var selectionID: String?
    @FocusState private var searchFocused: Bool
    @Query(sort: \LaunchProfileRecord.name) private var profiles: [LaunchProfileRecord]
    @Query private var dependencies: [ProfileDependencyRecord]
    @Query private var expectedPorts: [ExpectedPortRecord]
    @Query private var processPolicies: [ManagedServiceProcessPolicyRecord]
    @Query private var serviceChecks: [ManagedServiceCheckRecord]
    @Query private var validationRecords: [ManagedServiceValidationRecord]
    @Query(sort: \ProjectRecord.name) private var projects: [ProjectRecord]
    @Query(sort: \WorkspaceSessionRecord.capturedAt, order: .reverse) private var sessions: [WorkspaceSessionRecord]

    private struct Action: Identifiable {
        let id: String
        let title: String
        let subtitle: String?
        let symbol: String
        let keywords: String
        let perform: () -> Void
    }

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

    private var actions: [Action] {
        navigationActions + globalActions + listenerActions + projectActions + serviceActions + sessionActions
    }

    private var navigationActions: [Action] {
        [
            action("open-runtime", "Open Runtime", "Listeners, processes, and ownership", "point.3.connected.trianglepath.dotted", "ports pid command") { model.navigate(to: .runtime) },
            action("open-projects", "Open Projects", "Service topology and project actions", "folder", "dependencies groups") { model.navigate(to: .projects) },
            action("open-sessions", "Open Sessions", "Saved state, drift, and restore previews", "square.stack.3d.up", "capture restore workspace") { model.navigate(to: .sessions) },
            action("open-managed", "Open Managed Services", "Reviewed restart definitions", "play.square.stack", "profiles start run restart") { model.navigate(to: .managedServices) },
            action("open-history", "Open History", "Local lifecycle audit", "clock.arrow.circlepath", "events audit") { model.navigate(to: .history) },
            action("open-docker", "Open Docker", "Containers and verified Compose scopes", "shippingbox", "containers compose") { model.navigate(to: .docker) },
            action("open-settings", "Open Settings", nil, "gearshape", "preferences onboarding") { model.navigate(to: .settings) }
        ]
    }

    private var globalActions: [Action] {
        [
            action("refresh", "Refresh Runtime", nil, "arrow.clockwise", "ports reload") { model.refreshNow() },
            action("monitoring", model.isMonitoring ? "Pause Monitoring" : "Resume Monitoring", nil, model.isMonitoring ? "pause" : "play", "toggle") {
                model.isMonitoring ? model.pauseMonitoring() : model.startMonitoring()
            },
            action("capture-session", "Capture Workspace Session", "Choose projects and expected service state", "camera", "save snapshot") {
                model.requestSessionCapture()
            }
        ]
    }

    private var listenerActions: [Action] {
        model.listeners.map { listener in
            action(
                "listener-\(listener.id)",
                "Inspect :\(listener.port) — \(listener.process.name)",
                "PID \(listener.process.fingerprint.pid) · \(listener.protocolKind.rawValue) · \(listener.address)",
                listener.process.runtime.symbolName,
                "\(listener.port) \(listener.process.fingerprint.pid) \(listener.process.commandLine) \(listener.process.project?.name ?? "")"
            ) {
                model.selectedListenerID = listener.id
                model.navigate(to: .runtime)
            }
        }
    }

    private var projectActions: [Action] {
        projects.flatMap { project -> [Action] in
            let services = configurations.filter { $0.projectID == project.id }
            let isRunning = services.contains { model.runningProfileIDs.contains($0.id) }
            var values = [
                action("project-open-\(project.id)", "Open Project — \(project.name)", project.folderPath, "folder.fill", "project") {
                    model.navigate(to: .projects)
                }
            ]
            guard !services.isEmpty else { return values }
            values.append(action(
                "project-toggle-\(project.id)",
                isRunning ? "Stop Project — \(project.name)" : "Start Project — \(project.name)",
                "\(services.count) managed service(s)",
                isRunning ? "stop.fill" : "play.fill",
                "project all services"
            ) {
                Task {
                    if isRunning { await model.stopProject(services) }
                    else { await model.startProject(services) }
                }
            })
            return values
        }
    }

    private var serviceActions: [Action] {
        configurations.flatMap { service -> [Action] in
            let running = model.runningProfileIDs.contains(service.id)
                || model.runtimeStatuses[service.id]?.processRunning == true
            let validation = validationRecords.first { $0.managedServiceID == service.id }?.result
            let trust = RestartTrustEvaluator.summary(for: service, validation: validation)
            var values = [
                action("service-open-\(service.id)", "Open Managed Service — \(service.name)", trust.state.title, "play.square.stack", service.tags.joined(separator: " ")) {
                    model.requestManagedService(service.id)
                },
                action("service-copy-\(service.id)", "Copy Command — \(service.name)", service.command, "doc.on.doc", "managed service") {
                    copy(service.command)
                }
            ]
            if !service.workingDirectory.isEmpty {
                let directory = service.workingDirectory
                values.append(action("service-directory-\(service.id)", "Open Working Directory — \(service.name)", directory, "folder", "cwd finder") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: directory, isDirectory: true))
                })
            }
            values.append(action("service-logs-\(service.id)", "Open Logs — \(service.name)", nil, "text.alignleft", "output stderr stdout") {
                model.requestManagedServiceLogs(service.id)
            })
            if running {
                values.append(action("service-stop-\(service.id)", "Stop Managed Service — \(service.name)", "Owner will be revalidated before control", "stop.fill", "terminate") {
                    Task { await model.stopProfile(service) }
                })
                if trust.state == .verifiedRestartable {
                    values.append(action("service-restart-\(service.id)", "Restart Managed Service — \(service.name)", "Verified restart definition", "arrow.clockwise", "stop start") {
                        Task {
                            await model.stopProfile(service)
                            await model.launchProfile(service)
                        }
                    })
                }
            } else if trust.state == .verifiedRestartable {
                values.append(action("service-start-\(service.id)", "Start Managed Service — \(service.name)", "Verified restart definition", "play.fill", "launch") {
                    Task { await model.launchProfile(service) }
                })
            }
            return values
        }
    }

    private var sessionActions: [Action] {
        sessions.flatMap { session in
            [action(
                "session-\(session.id)",
                "Open Session — \(session.name)",
                "Captured \(session.capturedAt.formatted(date: .abbreviated, time: .shortened))",
                "square.stack.3d.up",
                "restore preview drift"
            ) {
                model.requestSession(session.id)
            }, action(
                "session-restore-\(session.id)",
                "Preview Restore — \(session.name)",
                "Revalidate drift and blockers before changing runtime",
                "arrow.counterclockwise.circle",
                "session restore dry run rollback"
            ) {
                model.requestSessionRestore(session.id)
            }]
        }
    }

    private var filtered: [Action] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Array(actions.prefix(28)) }
        return actions.filter {
            "\($0.title) \($0.subtitle ?? "") \($0.keywords)".localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DevBerthSpacing.medium) {
                Image(systemName: "command").foregroundStyle(.secondary)
                TextField("Open, search, or run a safe action", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($searchFocused)
                Text("⌘K").font(.caption.monospaced()).foregroundStyle(.tertiary)
            }
            .padding()
            Divider()
            if filtered.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List(selection: $selectionID) {
                    ForEach(filtered) { action in
                        Button { run(action) } label: {
                            HStack(spacing: DevBerthSpacing.medium) {
                                Image(systemName: action.symbol).frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(action.title)
                                    if let subtitle = action.subtitle {
                                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .tag(action.id)
                        .padding(.vertical, 4)
                    }
                }
                .onMoveCommand(perform: moveSelection)
            }
        }
        .frame(width: 650, height: 450)
        .onAppear {
            searchFocused = true
            selectionID = filtered.first?.id
        }
        .onChange(of: query) { _, _ in selectionID = filtered.first?.id }
        .onSubmit {
            if let action = filtered.first(where: { $0.id == selectionID }) ?? (filtered.count == 1 ? filtered.first : nil) {
                run(action)
            }
        }
    }

    private func action(
        _ id: String,
        _ title: String,
        _ subtitle: String?,
        _ symbol: String,
        _ keywords: String,
        perform: @escaping () -> Void
    ) -> Action {
        Action(id: id, title: title, subtitle: subtitle, symbol: symbol, keywords: keywords, perform: perform)
    }

    private func run(_ action: Action) {
        action.perform()
        isPresented = false
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        guard !filtered.isEmpty else { return }
        let current = selectionID.flatMap { id in filtered.firstIndex { $0.id == id } } ?? 0
        switch direction {
        case .up: selectionID = filtered[max(0, current - 1)].id
        case .down: selectionID = filtered[min(filtered.count - 1, current + 1)].id
        default: break
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
