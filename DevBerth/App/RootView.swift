import SwiftData
import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case runtime = "Runtime"
    case projects = "Projects"
    case sessions = "Sessions"
    case managedServices = "Managed Services"
    case history = "History"
    case docker = "Docker"
    case settings = "Settings"
    var id: Self { self }

    var symbol: String {
        switch self {
        case .runtime: "point.3.connected.trianglepath.dotted"
        case .projects: "folder"
        case .sessions: "square.stack.3d.up"
        case .managedServices: "play.square.stack"
        case .history: "clock.arrow.circlepath"
        case .docker: "shippingbox"
        case .settings: "gearshape"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: AppSection? = .runtime
    @State private var showsCommandPalette = false
    @State private var didLaunchAutomaticProfiles = false
    @AppStorage("devberth.onboarding.completed") private var hasCompletedOnboarding = false
    @Query private var profiles: [LaunchProfileRecord]
    @Query private var dependencies: [ProfileDependencyRecord]
    @Query private var expectedPorts: [ExpectedPortRecord]
    @Query private var processPolicies: [ManagedServiceProcessPolicyRecord]
    @Query private var serviceChecks: [ManagedServiceCheckRecord]

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.symbol)
                    .tag(section)
            }
            .navigationTitle("DevBerth")
            .safeAreaInset(edge: .bottom) {
                HStack {
                    StatusDot(status: model.isMonitoring ? .healthy : .stopped)
                    Text(model.isMonitoring ? "Monitoring" : "Paused")
                    Spacer()
                    Text("\(model.listeners.count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .padding()
                .background(.bar)
            }
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItemGroup {
                Button { showsCommandPalette = true } label: {
                    Label("Command Palette", systemImage: "command.square")
                }
                .keyboardShortcut("k", modifiers: .command)
                Button { model.isMonitoring ? model.pauseMonitoring() : model.startMonitoring() } label: {
                    Label(model.isMonitoring ? "Pause" : "Resume", systemImage: model.isMonitoring ? "pause" : "play")
                }
                Button { model.refreshNow() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.isRefreshing)
            }
        }
        .sheet(isPresented: $showsCommandPalette) { CommandPaletteView(isPresented: $showsCommandPalette) }
        .sheet(
            isPresented: Binding(
                get: { !hasCompletedOnboarding },
                set: { _ in }
            )
        ) {
            OnboardingView { destination in
                hasCompletedOnboarding = true
                switch destination {
                case .runtime:
                    model.refreshNow()
                    selection = .runtime
                case .importProject:
                    model.requestProjectImport()
                case .managedService:
                    model.requestManagedServiceCreation()
                case .session:
                    model.requestSessionCapture()
                }
            }
            .interactiveDismissDisabled()
        }
        .sheet(item: $model.pendingLaunchConflict) { pending in
            PortConflictResolutionView(pending: pending)
                .environmentObject(model)
        }
        .onChange(of: model.requestedSection) { _, requested in
            guard let requested else { return }
            selection = requested
            model.requestedSection = nil
        }
        .alert(item: $model.presentedError) { error in
            Alert(
                title: Text("DevBerth couldn’t complete the action"),
                message: Text([error.errorDescription, error.recoverySuggestion].compactMap { $0 }.joined(separator: "\n\n")),
                dismissButton: .default(Text("OK"))
            )
        }
        .task {
            guard !didLaunchAutomaticProfiles else { return }
            didLaunchAutomaticProfiles = true
            for profile in profiles where profile.launchesAutomatically {
                if let configuration = profile.configuration(
                    dependencies: dependencies,
                    expectedPorts: expectedPorts,
                    processPolicies: processPolicies,
                    serviceChecks: serviceChecks
                ) {
                    await model.launchProfile(configuration)
                }
            }
            model.setNotificationPorts(expectedPorts.map(\.port))
        }
        .onChange(of: expectedPorts.map(\.port)) { _, ports in model.setNotificationPorts(ports) }
        .background {
            WindowVisibilityReporter { visible in
                model.setMonitoringSurface(.mainWindow, visible: visible)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .runtime {
        case .runtime: ActivePortsView()
        case .projects: ProjectsView()
        case .sessions: SessionsView()
        case .managedServices: LaunchProfilesView()
        case .history: HistoryView()
        case .docker: DockerView(
            client: model.dockerService,
            lifecycleRecorder: model.lifecycleEventRecorder,
            didMutate: model.dockerMutationDidComplete
        )
        case .settings: SettingsView()
        }
    }
}

struct WindowVisibilityReporter: NSViewRepresentable {
    let visibilityChanged: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> WindowVisibilityView {
        WindowVisibilityView(visibilityChanged: visibilityChanged)
    }

    func updateNSView(_ view: WindowVisibilityView, context: Context) {
        view.visibilityChanged = visibilityChanged
        view.publishCurrentVisibility()
    }
}

@MainActor
final class WindowVisibilityView: NSView {
    var visibilityChanged: @MainActor (Bool) -> Void
    private weak var observedWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var lastPublishedVisibility: Bool?

    init(visibilityChanged: @escaping @MainActor (Bool) -> Void) {
        self.visibilityChanged = visibilityChanged
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observe(window)
        Task { @MainActor [weak self] in self?.publishCurrentVisibility() }
    }

    func publishCurrentVisibility() {
        let visible = observedWindow?.isVisible == true
            && observedWindow?.isMiniaturized == false
            && observedWindow?.occlusionState.contains(.visible) == true
            && !NSApplication.shared.isHidden
        publish(visible)
    }

    private func observe(_ window: NSWindow?) {
        guard observedWindow !== window else { return }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll(keepingCapacity: true)
        observedWindow = window
        guard let window else {
            publish(false)
            return
        }
        let center = NotificationCenter.default
        let visibilityNotifications: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didMiniaturizeNotification
        ]
        observers = visibilityNotifications.map { name in
            center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    _ = Task<Void, Never> { @MainActor [weak self] in
                        self?.publishCurrentVisibility()
                    }
                }
            }
        }
        observers.append(center.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.publish(false) }
        })
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.publishCurrentVisibility() }
            })
        }
    }

    private func publish(_ visible: Bool) {
        guard lastPublishedVisibility != visible else { return }
        lastPublishedVisibility = visible
        visibilityChanged(visible)
    }
}

private struct PortConflictResolutionView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let pending: PendingLaunchConflict

    var body: some View {
        VStack(alignment: .leading, spacing: DevBerthSpacing.large) {
            Label("Port \(pending.conflict.expectedPort.port) is already occupied", systemImage: "exclamationmark.triangle.fill")
                .font(.title2.bold()).foregroundStyle(.orange)
            Text("\(pending.profile.name) has not been started. DevBerth will never stop the occupying process without your approval.")
                .foregroundStyle(.secondary)
            GroupBox("Occupying process") {
                VStack(spacing: 10) {
                    InspectorRow(title: "Process", value: pending.conflict.listener.process.name)
                    InspectorRow(title: "PID", value: String(pending.conflict.listener.process.fingerprint.pid))
                    InspectorRow(title: "Executable", value: pending.conflict.listener.process.executablePath ?? "Unavailable")
                    InspectorRow(title: "Project", value: pending.conflict.listener.process.project?.name ?? "Not associated")
                    InspectorRow(title: "DevBerth managed", value: pending.conflict.listener.process.launchedByDevBerth ? "Yes" : "No")
                }
            }
            if pending.conflict.listener.process.isSystemProcess {
                Label("This is a protected system process and cannot be stopped by DevBerth.", systemImage: "lock.shield")
                    .foregroundStyle(.red)
            }
            HStack {
                Button("Cancel", role: .cancel) { cancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Inspect Process") { model.inspectPendingConflict(); dismiss() }
                Button("Edit Expected Port") { model.editProfileForPendingConflict(); dismiss() }
                Spacer()
                Button("Stop Process") { Task { await model.resolvePendingConflict(startAfterStopping: false); dismiss() } }
                    .disabled(pending.conflict.listener.process.isSystemProcess)
                Button("Stop and Start Managed Service") { Task { await model.resolvePendingConflict(startAfterStopping: true); dismiss() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(pending.conflict.listener.process.isSystemProcess)
            }
        }
        .padding(DevBerthSpacing.xLarge)
        .frame(width: 680)
        .onExitCommand { cancel() }
    }

    private func cancel() {
        model.pendingLaunchConflict = nil
        dismiss()
    }
}
