import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var portSearch = ""

    private var visible: [NetworkListener] {
        let trimmed = portSearch.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return Array(model.listeners.prefix(8)) }
        return model.listeners.filter { String($0.port).contains(trimmed) || $0.process.name.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PortPilotSpacing.medium) {
            HStack {
                VStack(alignment: .leading) {
                    Text("PortPilot").font(.headline)
                    Text("\(model.listeners.count) active listeners").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                StatusDot(status: model.isMonitoring ? .healthy : .stopped)
            }
            TextField("Find a port or process", text: $portSearch)
                .textFieldStyle(.roundedBorder)
            Divider()
            if visible.isEmpty {
                Text("No matching listeners").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 70)
            } else {
                ForEach(visible) { listener in
                    HStack {
                        PortBadge(port: listener.port)
                        Image(systemName: listener.process.runtime.symbolName)
                        Text(listener.process.name).lineLimit(1)
                        Spacer()
                        Text(listener.protocolKind.rawValue).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            HStack {
                Button(model.isMonitoring ? "Pause" : "Resume") {
                    model.isMonitoring ? model.pauseMonitoring() : model.startMonitoring()
                }
                Button("Open PortPilot") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "main")
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding()
        .frame(width: 390)
    }
}

