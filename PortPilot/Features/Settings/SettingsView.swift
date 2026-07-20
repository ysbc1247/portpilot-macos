import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("refreshInterval") private var refreshInterval = 2.0
    @AppStorage("historyRetentionDays") private var historyRetentionDays = 30
    @AppStorage("notifyConfiguredPorts") private var notifyConfiguredPorts = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?

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
                Toggle("Launch PortPilot at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in updateLoginItem(enabled) }
            }
            Section("History") {
                Stepper("Retain history for \(historyRetentionDays) days", value: $historyRetentionDays, in: 1...365)
                Text("History, settings, project metadata, and logs remain on this Mac.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Safety") {
                Label("System and root-owned processes receive additional protection.", systemImage: "lock.shield")
                Text("PortPilot never silently requests administrator privileges and never uploads process information.")
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
        .alert("Login item could not be changed", isPresented: .constant(loginItemError != nil)) {
            Button("OK") { loginItemError = nil }
        } message: { Text(loginItemError ?? "") }
    }

    private func updateLoginItem(_ enabled: Bool) {
        do {
            enabled ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister()
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            loginItemError = error.localizedDescription
        }
    }
}

