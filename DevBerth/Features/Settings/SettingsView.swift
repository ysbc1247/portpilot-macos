import AppKit
import DevBerthControlContracts
import ServiceManagement
import SwiftUI

@MainActor
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var controlHost: ControlHostStatusModel
    @AppStorage("refreshInterval") private var refreshInterval = 2.0
    @AppStorage("historyRetentionDays") private var historyRetentionDays = 30
    @AppStorage("notifyConfiguredPorts") private var notifyConfiguredPorts = false
    @AppStorage("devberth.onboarding.completed") private var hasCompletedOnboarding = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?
    @State private var systemSettingsError: String?
    @State private var diagnosticsDocument: LogTextDocument?
    @State private var copiedCodexConfiguration = false
    @State private var integrationSnapshot: MCPIntegrationSnapshot?
    @State private var integrationPreview: CodexConfigurationPreview?
    @State private var integrationMessage: String?
    @State private var projectConfigurationRoot = ""
    @State private var pendingIntegrationAction: PendingIntegrationAction?
    private let integrationManager: any MCPIntegrationManaging

    init() {
        integrationManager = MCPIntegrationManager()
    }

    init(integrationManager: any MCPIntegrationManaging) {
        self.integrationManager = integrationManager
    }

    var body: some View {
        Form {
            Section("Monitoring") {
                Picker("Refresh interval", selection: $refreshInterval) {
                    Text("1 second").tag(1.0)
                    Text("2 seconds").tag(2.0)
                    Text("5 seconds").tag(5.0)
                    Text("10 seconds").tag(10.0)
                }
                Toggle("Notify when configured ports change", isOn: $notifyConfiguredPorts)
                    .onChange(of: notifyConfiguredPorts) { _, enabled in
                        guard enabled else { return }
                        Task {
                            do {
                                let allowed = try await LocalNotificationService().requestAuthorization()
                                if !allowed { notifyConfiguredPorts = false }
                            } catch {
                                notifyConfiguredPorts = false
                                loginItemError = "Notification permission could not be requested: \(error.localizedDescription)"
                            }
                        }
                    }
                Toggle("Launch DevBerth at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in updateLoginItem(enabled) }
            }
            Section("History") {
                Stepper("Retain history for \(historyRetentionDays) days", value: $historyRetentionDays, in: 1...365)
                Text("History, settings, project metadata, and logs remain on this Mac.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Safety") {
                Label("System and root-owned processes receive additional protection.", systemImage: "lock.shield")
                Text("DevBerth never silently requests administrator privileges and never uploads process information.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Open Full Disk Access Settings", systemImage: "externaldrive.badge.checkmark") {
                    openFullDiskAccessSettings()
                }
                Text("macOS requires you to add or enable DevBerth in System Settings. DevBerth can open the correct pane, but it cannot grant this permission to itself.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Integrations · Codex & MCP") {
                LabeledContent("MCP status", value: controlHost.state)
                LabeledContent("Control host", value: controlHost.developmentMode ? "Isolated development store" : "Production application store")
                LabeledContent("Protocol", value: "v\(ControlProtocolConstants.version) · schema v\(ControlProtocolConstants.toolSchemaVersion)")
                LabeledContent("Helper", value: integrationSnapshot?.installedHelperURL?.path ?? "Not installed")
                LabeledContent("Helper version", value: integrationSnapshot?.installedVersion ?? "Unavailable")
                LabeledContent("Global Codex configuration", value: integrationSnapshot?.globalConfigurationMessage ?? "Checking")
                LabeledContent("Production tools", value: String(ControlCapabilityRegistry.productionTools.count))
                LabeledContent("Development tools", value: String(ControlCapabilityRegistry.developmentTools.count))
                HStack {
                    Button("Test Connection", systemImage: "network") {
                        Task { await controlHost.testConnection() }
                    }
                    Button(copiedCodexConfiguration ? "Copied" : "Copy Codex Configuration", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(codexConfiguration, forType: .string)
                        copiedCodexConfiguration = true
                    }
                }
                HStack {
                    Button("Set Up / Repair Codex MCP", systemImage: "wand.and.stars") {
                        pendingIntegrationAction = .setupGlobal
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(integrationSnapshot?.canInstall != true)
                    Button(helperActionTitle, systemImage: "shippingbox") {
                        pendingIntegrationAction = .install
                    }
                    .disabled(integrationSnapshot?.canInstall != true)
                    Button("Uninstall", systemImage: "trash") {
                        pendingIntegrationAction = .uninstall
                    }
                    .disabled(integrationSnapshot?.installedHelperURL == nil)
                    Button("Run MCP Validation", systemImage: "checkmark.shield") {
                        Task { await validateMCPIntegration() }
                    }
                }
                HStack {
                    Button("Preview Global Configuration", systemImage: "doc.text.magnifyingglass") {
                        previewConfiguration(scope: .global)
                    }
                    Button("Configure Codex Globally", systemImage: "gearshape.2") {
                        pendingIntegrationAction = .configureGlobal
                    }
                    Button("Open Configuration", systemImage: "folder") {
                        do { try integrationManager.openCodexConfiguration(scope: .global) }
                        catch { integrationMessage = error.localizedDescription }
                    }
                }
                TextField("Project root for .codex/config.toml", text: $projectConfigurationRoot)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Preview Project Configuration", systemImage: "doc.badge.gearshape") {
                        guard let scope = projectScope else {
                            integrationMessage = "Enter an existing absolute project directory."
                            return
                        }
                        previewConfiguration(scope: scope)
                    }
                    Button("Configure Current Project", systemImage: "folder.badge.gearshape") {
                        guard projectScope != nil else {
                            integrationMessage = "Enter an existing absolute project directory."
                            return
                        }
                        pendingIntegrationAction = .configureProject
                    }
                }
                if let test = controlHost.lastConnectionTest {
                    Text(test).font(.callout).foregroundStyle(test.hasPrefix("Connected") ? .green : .secondary)
                }
                if let error = controlHost.lastError {
                    Text(error).font(.callout).foregroundStyle(.secondary)
                }
                if let integrationMessage {
                    Text(integrationMessage).font(.callout).foregroundStyle(.secondary)
                }
                Text("The helper speaks MCP over stdio and forwards typed requests to this same-user local control host. Destructive actions always use preview → approval → execute.")
                    .font(.callout).foregroundStyle(.secondary)
                if let integrationPreview {
                    DisclosureGroup("Configuration Diff Preview") {
                        Text(integrationPreview.summary)
                        Text(integrationPreview.proposedText)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                DisclosureGroup("Codex config.toml") {
                    Text(codexConfiguration)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            Section("Getting Started") {
                Button("Show Welcome Guide Again", systemImage: "sparkles") {
                    hasCompletedOnboarding = false
                }
                Text("The guide explains local visibility limits, ownership, restart trust, and DevBerth’s safety model.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Diagnostics") {
                Button("Export Diagnostics…", systemImage: "square.and.arrow.up") {
                    diagnosticsDocument = LogTextDocument(text: DiagnosticsReportBuilder.build(
                        listeners: model.listeners,
                        refreshInterval: refreshInterval,
                        historyRetentionDays: historyRetentionDays,
                        notificationsEnabled: notifyConfiguredPorts,
                        recentError: model.presentedError
                    ))
                }
                Text("Exports non-secret settings and listener diagnostics. Commands, environment values, and Keychain secrets are excluded.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .frame(minWidth: 560, minHeight: 400)
        .onChange(of: refreshInterval) { _, value in
            model.refreshInterval = value
            if model.isMonitoring { model.startMonitoring() }
        }
        .task { integrationSnapshot = await integrationManager.inspect() }
        .alert("Login item could not be changed", isPresented: .constant(loginItemError != nil)) {
            Button("OK") { loginItemError = nil }
        } message: { Text(loginItemError ?? "") }
        .alert("System Settings could not be opened", isPresented: .constant(systemSettingsError != nil)) {
            Button("OK") { systemSettingsError = nil }
        } message: { Text(systemSettingsError ?? "") }
        .alert(item: $pendingIntegrationAction) { action in
            Alert(
                title: Text(action.title),
                message: Text(action.message),
                primaryButton: .default(Text(action.confirmTitle)) { performIntegrationAction(action) },
                secondaryButton: .cancel()
            )
        }
        .fileExporter(
            isPresented: Binding(get: { diagnosticsDocument != nil }, set: { if !$0 { diagnosticsDocument = nil } }),
            document: diagnosticsDocument,
            contentType: .plainText,
            defaultFilename: "DevBerth-Diagnostics.txt"
        ) { _ in diagnosticsDocument = nil }
    }

    private func updateLoginItem(_ enabled: Bool) {
        do {
            enabled ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister()
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            loginItemError = error.localizedDescription
        }
    }

    private func openFullDiskAccessSettings() {
        guard
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"),
            NSWorkspace.shared.open(url)
        else {
            systemSettingsError = "Open System Settings → Privacy & Security → Full Disk Access, then add or enable DevBerth."
            return
        }
    }

    private func validateMCPIntegration() async {
        integrationSnapshot = await integrationManager.inspect()
        await controlHost.testConnection()
        guard let snapshot = integrationSnapshot else {
            integrationMessage = "Validation failed: integration state is unavailable."
            return
        }
        guard snapshot.installedVersion != nil else {
            integrationMessage = "Validation failed: install the stable helper."
            return
        }
        guard !snapshot.needsUpdate else {
            integrationMessage = "Validation failed: update the stable helper to match this app build."
            return
        }
        guard snapshot.globalConfigurationReady else {
            integrationMessage = "Validation failed: " + snapshot.globalConfigurationMessage.lowercased() + "."
            return
        }
        guard controlHost.lastConnectionTest?.hasPrefix("Connected") == true else {
            let failure = controlHost.lastConnectionTest ?? "the local control host did not respond"
            integrationMessage = "Validation failed: " + failure + "."
            return
        }
        integrationMessage = "MCP is ready: helper, global Codex configuration, and local control host all passed."
    }

    private var helperActionTitle: String {
        guard integrationSnapshot?.installedHelperURL != nil else { return "Install" }
        return integrationSnapshot?.needsUpdate == true ? "Update" : "Repair"
    }

    private var codexConfiguration: String {
        let command = MCPIntegrationManager.stableHelperURL.path
        return """
        [mcp_servers.devberth]
        command = "\(command)"
        args = ["serve", "--stdio"]
        startup_timeout_sec = 10
        tool_timeout_sec = 120
        """
    }

    private var projectScope: CodexConfigurationScope? {
        let url = URL(fileURLWithPath: projectConfigurationRoot, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard projectConfigurationRoot.hasPrefix("/"),
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return .project(url)
    }

    private func previewConfiguration(scope: CodexConfigurationScope) {
        do {
            integrationPreview = try integrationManager.previewCodexConfiguration(scope: scope)
            integrationMessage = integrationPreview?.summary
        } catch {
            integrationMessage = error.localizedDescription
        }
    }

    private func performIntegrationAction(_ action: PendingIntegrationAction) {
        Task {
            do {
                switch action {
                case .setupGlobal:
                    let result = try await integrationManager.setUpGlobalCodex()
                    integrationSnapshot = result.snapshot
                    integrationPreview = result.configurationPreview
                    await validateMCPIntegration()
                    if integrationMessage?.hasPrefix("MCP is ready") == true {
                        integrationMessage = "MCP is ready. Reload MCP servers or restart Codex to use it in an existing session."
                    }
                case .install:
                    integrationSnapshot = try await integrationManager.installOrRepair()
                    integrationMessage = "The stable helper was installed and version-validated."
                case .uninstall:
                    integrationSnapshot = try await integrationManager.uninstall()
                    integrationMessage = "The helper was moved to Trash. Codex configuration was left unchanged."
                case .configureGlobal:
                    let preview = try integrationManager.previewCodexConfiguration(scope: .global)
                    try integrationManager.applyCodexConfiguration(preview)
                    integrationPreview = preview
                    integrationMessage = "Global Codex configuration was backed up, updated atomically, and validated."
                case .configureProject:
                    guard let projectScope else { throw DevBerthError.unexpected("Enter an existing absolute project directory.") }
                    let preview = try integrationManager.previewCodexConfiguration(scope: projectScope)
                    try integrationManager.applyCodexConfiguration(preview)
                    integrationPreview = preview
                    integrationMessage = "Project Codex configuration was backed up, updated atomically, and validated."
                }
            } catch {
                integrationMessage = error.localizedDescription
            }
        }
    }
}

private enum PendingIntegrationAction: String, Identifiable {
    case setupGlobal
    case install
    case uninstall
    case configureGlobal
    case configureProject

    var id: String { rawValue }
    var title: String {
        switch self {
        case .setupGlobal: "Set up DevBerth MCP for Codex?"
        case .install: "Install or repair helper?"
        case .uninstall: "Uninstall helper?"
        case .configureGlobal: "Update global Codex configuration?"
        case .configureProject: "Update project Codex configuration?"
        }
    }
    var message: String {
        switch self {
        case .setupGlobal: "DevBerth will install or repair its user-scoped helper, preserve unrelated global Codex TOML, create a backup, write the MCP configuration atomically, and validate the local control host."
        case .install: "DevBerth will atomically replace only its user-scoped helper and validate the installed version."
        case .uninstall: "DevBerth will move only its stable helper to Trash. Existing Codex configuration will be preserved."
        case .configureGlobal, .configureProject: "DevBerth will preserve unrelated TOML, create a backup, write atomically, and roll back if validation fails."
        }
    }
    var confirmTitle: String {
        switch self {
        case .setupGlobal: "Set Up"
        case .install: "Install"
        case .uninstall: "Move to Trash"
        case .configureGlobal, .configureProject: "Apply"
        }
    }
}
