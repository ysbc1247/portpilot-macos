import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PortPilotSpacing.xLarge) {
                VStack(alignment: .leading, spacing: PortPilotSpacing.small) {
                    Text("Overview").font(.largeTitle.bold())
                    Text("A live view of local development services.")
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: PortPilotSpacing.large) {
                    metric(title: "Active listeners", value: model.listeners.count, symbol: "antenna.radiowaves.left.and.right")
                    metric(title: "Processes", value: Set(model.listeners.map { $0.process.identity }).count, symbol: "terminal")
                    metric(title: "Projects", value: Set(model.listeners.compactMap { $0.process.project?.rootPath }).count, symbol: "folder")
                    metric(title: "Protected", value: model.listeners.filter { $0.process.isSystemProcess }.count, symbol: "lock.shield")
                }

                GroupBox("Recently changed listeners") {
                    if model.recentChanges.isEmpty {
                        Text("Port changes will appear here while monitoring is active.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(model.recentChanges) { listener in
                                HStack {
                                    Image(systemName: listener.process.runtime.symbolName)
                                        .frame(width: 24)
                                    PortBadge(port: listener.port)
                                    Text(listener.process.name)
                                    Spacer()
                                    Text(listener.address)
                                        .foregroundStyle(.secondary)
                                        .font(.system(.caption, design: .monospaced))
                                }
                                .padding(.vertical, PortPilotSpacing.small)
                                if listener.id != model.recentChanges.last?.id { Divider() }
                            }
                        }
                    }
                }
            }
            .padding(PortPilotSpacing.xLarge)
        }
        .navigationTitle("Overview")
    }

    private func metric(title: LocalizedStringKey, value: Int, symbol: String) -> some View {
        GroupBox {
            HStack(spacing: PortPilotSpacing.medium) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading) {
                    Text(value, format: .number).font(.title2.bold()).monospacedDigit()
                    Text(title).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

