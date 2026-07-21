import SwiftData
import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var model: AppModel
    @Query(sort: \ProjectRecord.name) private var projects: [ProjectRecord]
    @Query(sort: \LaunchProfileRecord.name) private var profiles: [LaunchProfileRecord]
    @Query private var dependencies: [ProfileDependencyRecord]
    @Query private var expectedPorts: [ExpectedPortRecord]
    @Query private var processPolicies: [ManagedServiceProcessPolicyRecord]
    @Query(sort: \ProcessHistoryEventRecord.timestamp, order: .reverse) private var history: [ProcessHistoryEventRecord]

    private var conflicts: [(LaunchProfileRecord, ExpectedPortRecord, ObservedListener)] {
        expectedPorts.compactMap { expected in
            guard
                let profile = profiles.first(where: { $0.id == expected.profileID }),
                let listener = model.listeners.first(where: { Int($0.port) == expected.port && $0.protocolKind.rawValue == expected.protocolRawValue }),
                !model.runningProfileIDs.contains(profile.id)
            else { return nil }
            return (profile, expected, listener)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DevBerthSpacing.xLarge) {
                VStack(alignment: .leading, spacing: DevBerthSpacing.small) {
                    Text("Overview").font(.largeTitle.bold())
                    Text("A live view of local development services.").foregroundStyle(.secondary)
                }

                HStack(spacing: DevBerthSpacing.large) {
                    metric(title: "Active listeners", value: model.listeners.count, symbol: "antenna.radiowaves.left.and.right")
                    metric(title: "Running projects", value: activeProjectCount, symbol: "folder")
                    metric(title: "Port conflicts", value: conflicts.count, symbol: "exclamationmark.triangle")
                    metric(title: "Failed services", value: model.profileFailures.count, symbol: "xmark.octagon")
                }

                HStack(alignment: .top, spacing: DevBerthSpacing.large) {
                    GroupBox("Favorite launch profiles") {
                        let favorites = profiles.filter(\.isFavorite)
                        if favorites.isEmpty {
                            Text("Mark profiles as favorites for one-click access here and in the menu bar.")
                                .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 90)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(favorites.prefix(6)) { record in
                                    if let profile = record.configuration(
                                        dependencies: dependencies,
                                        expectedPorts: expectedPorts,
                                        processPolicies: processPolicies
                                    ) {
                                        HStack {
                                            Image(systemName: "star.fill").foregroundStyle(.yellow)
                                            Text(profile.name)
                                            Spacer()
                                            Button(model.runningProfileIDs.contains(profile.id) ? "Stop" : "Start") {
                                                Task {
                                                    if model.runningProfileIDs.contains(profile.id) { await model.stopProfile(profile) }
                                                    else { await model.launchProfile(profile) }
                                                }
                                            }
                                        }
                                        .padding(.vertical, 6)
                                        if record.id != favorites.prefix(6).last?.id { Divider() }
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)

                    GroupBox("Conflicts and failures") {
                        if conflicts.isEmpty && model.profileFailures.isEmpty {
                            Label("No launch conflicts or failed services", systemImage: "checkmark.circle")
                                .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 90)
                        } else {
                            VStack(alignment: .leading, spacing: DevBerthSpacing.small) {
                                ForEach(conflicts.prefix(5), id: \.1.id) { conflict in
                                    HStack {
                                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                        Text("\(conflict.0.name) expects :\(conflict.1.port)")
                                        Spacer()
                                        Text(conflict.2.process.name).foregroundStyle(.secondary)
                                    }
                                }
                                ForEach(model.profileFailures.keys.sorted(by: { $0.uuidString < $1.uuidString }), id: \.self) { id in
                                    if let record = profiles.first(where: { $0.id == id }) {
                                        Label(record.name, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }

                GroupBox("Recently changed listeners") {
                    if model.recentChanges.isEmpty {
                        Text("Port changes will appear here while monitoring is active.")
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(model.recentChanges) { listener in
                                HStack {
                                    Image(systemName: listener.process.runtime.symbolName).frame(width: 24)
                                    PortBadge(port: listener.port)
                                    Text(listener.process.name)
                                    Spacer()
                                    Text(listener.address).foregroundStyle(.secondary).font(.system(.caption, design: .monospaced))
                                }
                                .padding(.vertical, DevBerthSpacing.small)
                                if listener.id != model.recentChanges.last?.id { Divider() }
                            }
                        }
                    }
                }

                let recentlyStopped = history.filter { $0.typeRawValue == HistoryEventType.portReleased.rawValue || $0.typeRawValue == HistoryEventType.processStopped.rawValue }
                if !recentlyStopped.isEmpty {
                    GroupBox("Recently stopped services") {
                        VStack(spacing: 0) {
                            ForEach(recentlyStopped.prefix(5)) { event in
                                HStack {
                                    Image(systemName: "stop.circle")
                                    Text(event.processName ?? "Unknown process")
                                    Spacer()
                                    Text(event.port.map { ":\($0)" } ?? "").monospacedDigit()
                                    Text(event.timestamp, format: .relative(presentation: .named)).foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 6)
                            }
                        }
                    }
                }
            }
            .padding(DevBerthSpacing.xLarge)
        }
        .navigationTitle("Overview")
    }

    private var activeProjectCount: Int {
        projects.filter { project in profiles.contains { $0.projectID == project.id && model.runningProfileIDs.contains($0.id) } }.count
    }

    private func metric(title: LocalizedStringKey, value: Int, symbol: String) -> some View {
        GroupBox {
            HStack(spacing: DevBerthSpacing.medium) {
                Image(systemName: symbol).font(.title2).foregroundStyle(.secondary)
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
